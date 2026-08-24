package http

import (
	"encoding/csv"
	"fmt"
	"net/http"
	"rakutenfx/internal/domain"
	"rakutenfx/internal/infrastructure/ai"
	"rakutenfx/internal/infrastructure/backtest"
	"rakutenfx/internal/infrastructure/ipc"
	"rakutenfx/internal/infrastructure/persistence"
	"rakutenfx/internal/usecase"
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	repo            *persistence.SQLiteRepository
	analyzer        *usecase.TradeAnalyzer
	geminiClient    *ai.GeminiClient
	adaptiveService *usecase.AdaptiveStrategyService
	ipcServer       *ipc.IpcServer
	wsHub           *WebSocketHub
	dataLoader      *backtest.DataLoader
	backtestEngine  *backtest.BacktestEngine
	optimizer       *backtest.Optimizer

	// Cache for 1-year historical bars to avoid regenerating on each run
	cachedBars []backtest.Bar
	barsOnce   sync.Once

	// Last backtest result cache
	lastBacktestResult *backtest.BacktestResult
	lastAiReport       *domain.AiEvaluationReport
	resultMutex        sync.RWMutex
}

func NewHandler(
	repo *persistence.SQLiteRepository,
	analyzer *usecase.TradeAnalyzer,
	geminiClient *ai.GeminiClient,
	ipcServer *ipc.IpcServer,
	wsHub *WebSocketHub,
) *Handler {
	engine := backtest.NewBacktestEngine()
	return &Handler{
		repo:            repo,
		analyzer:        analyzer,
		geminiClient:    geminiClient,
		adaptiveService: usecase.NewAdaptiveStrategyService(geminiClient),
		ipcServer:       ipcServer,
		wsHub:           wsHub,
		dataLoader:      backtest.NewDataLoader(),
		backtestEngine:  engine,
		optimizer:       backtest.NewOptimizer(engine),
	}
}

func (h *Handler) getHistoricalBars() []backtest.Bar {
	h.barsOnce.Do(func() {
		h.cachedBars = h.dataLoader.Generate1YearUsdJpyM1Bars()
	})
	return h.cachedBars
}

func (h *Handler) GetMetrics(c *gin.Context) {
	trades, err := h.repo.GetAllTrades()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	metrics := h.analyzer.CalculateMetrics(trades)
	c.JSON(http.StatusOK, metrics)
}

func (h *Handler) GetTrades(c *gin.Context) {
	trades, err := h.repo.GetAllTrades()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, trades)
}

func (h *Handler) GetSignals(c *gin.Context) {
	limitStr := c.DefaultQuery("limit", "20")
	limit, _ := strconv.Atoi(limitStr)
	if limit <= 0 {
		limit = 20
	}

	signals, err := h.repo.GetRecentSignals(limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, signals)
}

func (h *Handler) GetMarketRegime(c *gin.Context) {
	symbol := c.DefaultQuery("symbol", "USDJPY")

	regime := domain.MarketRegimeInfo{
		Symbol:       symbol,
		Regime:       domain.RegimeClear,
		StateName:    "CLEAR (レンジ・エントリー許可)",
		Description:  "ADX<25 かつ MTF-ATR正常。BB+RSI平均回帰の統計的エッジが有効な状態です。",
		BBUpper:      158.950,
		BBLower:      158.350,
		RSI:          48.5,
		ADX:          18.2,
		ATRPips:      14.5,
		EntryAllowed: true,
		UpdatedAt:    time.Now(),
	}

	c.JSON(http.StatusOK, regime)
}

func (h *Handler) GenerateAiReport(c *gin.Context) {
	trades, err := h.repo.GetAllTrades()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	metrics := h.analyzer.CalculateMetrics(trades)
	report, err := h.geminiClient.EvaluatePerformance(c.Request.Context(), &metrics)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	_ = h.repo.SaveAiReport(report)
	h.wsHub.BroadcastJSON(gin.H{
		"type":   "AI_REPORT_GENERATED",
		"report": report,
	})

	c.JSON(http.StatusOK, report)
}

// RunBacktest executes 1-year USD/JPY simulation
func (h *Handler) RunBacktest(c *gin.Context) {
	params := backtest.DefaultStrategyParams()
	if err := c.ShouldBindJSON(&params); err != nil {
		// Use defaults if empty body
		params = backtest.DefaultStrategyParams()
	}

	bars := h.getHistoricalBars()
	result := h.backtestEngine.Run(bars, params)

	bestParamsStr := fmt.Sprintf("BB(20, %.1fσ), RSI(14, <%.0f/>%.0f), ADX(<%.0f), ATR(1.5x), Timeout(%dmin)",
		params.BBStdDev, params.RSIOversold, params.RSIOverbought, params.ADXThreshold, params.TimeoutMinutes)

	aiReport, _ := h.geminiClient.EvaluateBacktestReport(
		c.Request.Context(),
		result.TotalTrades,
		result.WinRate,
		result.ProfitFactor,
		result.TotalProfit,
		result.MaxDrawdown,
		bestParamsStr,
	)

	h.resultMutex.Lock()
	h.lastBacktestResult = &result
	h.lastAiReport = aiReport
	h.resultMutex.Unlock()

	c.JSON(http.StatusOK, gin.H{
		"result":    result,
		"ai_report": aiReport,
	})
}

// OptimizeBacktest executes parallel grid search across parameter space
func (h *Handler) OptimizeBacktest(c *gin.Context) {
	bars := h.getHistoricalBars()
	ranking := h.optimizer.OptimizeGrid(bars)

	c.JSON(http.StatusOK, gin.H{
		"rankings": ranking,
	})
}

// ExportBacktestCSV exports trade history of the last backtest run
func (h *Handler) ExportBacktestCSV(c *gin.Context) {
	h.resultMutex.RLock()
	res := h.lastBacktestResult
	h.resultMutex.RUnlock()

	if res == nil || len(res.Trades) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "No backtest results available to export. Please run backtest first."})
		return
	}

	c.Header("Content-Disposition", "attachment; filename=backtest_trades_1year.csv")
	c.Header("Content-Type", "text/csv; charset=utf-8")

	writer := csv.NewWriter(c.Writer)
	_ = writer.Write([]string{"Ticket", "Action", "Lots", "OpenPrice", "ClosePrice", "OpenTime", "CloseTime", "ProfitJPY", "Pips", "Reason", "Regime"})

	for _, t := range res.Trades {
		_ = writer.Write([]string{
			strconv.Itoa(t.Ticket),
			t.Action,
			fmt.Sprintf("%.2f", t.Lots),
			fmt.Sprintf("%.3f", t.OpenPrice),
			fmt.Sprintf("%.3f", t.ClosePrice),
			t.OpenTime.Format("2006-01-02 15:04:05"),
			t.CloseTime.Format("2006-01-02 15:04:05"),
			fmt.Sprintf("%.0f", t.Profit),
			fmt.Sprintf("%.1f", t.Pips),
			t.Reason,
			t.Regime,
		})
	}
	writer.Flush()
}

type KillSwitchRequest struct {
	Active bool   `json:"active"`
	Reason string `json:"reason"`
}

func (h *Handler) ToggleKillSwitch(c *gin.Context) {
	var req KillSwitchRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	h.ipcServer.SetKillSwitch(req.Active)

	h.wsHub.BroadcastJSON(gin.H{
		"type":        "KILL_SWITCH_UPDATED",
		"kill_switch": req.Active,
		"reason":      req.Reason,
	})

	c.JSON(http.StatusOK, gin.H{
		"status":      "success",
		"kill_switch": req.Active,
		"reason":      req.Reason,
	})
}

func (h *Handler) GetSystemStatus(c *gin.Context) {
	isKill := h.ipcServer.IsKillSwitchActive()
	c.JSON(http.StatusOK, gin.H{
		"status":       "online",
		"version":      "2.3.0 (AI Co-Evolution & Adaptive Tuning Strategy)",
		"ipc_port":     5556,
		"gateway_port": 5555,
		"kill_switch":  isKill,
	})
}

// GetAdaptiveProfile returns the current AI-adapted hyperparameter profile.
func (h *Handler) GetAdaptiveProfile(c *gin.Context) {
	profile := h.adaptiveService.GetCurrentProfile()
	c.JSON(http.StatusOK, profile)
}

// TriggerAdaptiveTuning triggers an immediate AI market diagnosis & parameter adaptation.
func (h *Handler) TriggerAdaptiveTuning(c *gin.Context) {
	ctx := c.Request.Context()

	// Get latest regime & metrics
	trades, _ := h.repo.GetAllTrades()
	metrics := h.analyzer.CalculateMetrics(trades)

	regime := &domain.MarketRegimeInfo{
		Symbol:       "USDJPY",
		Regime:       domain.RegimeClear,
		StateName:    "CLEAR (レンジ・エントリー許可)",
		Description:  "ADX<25 かつ MTF-ATR正常。BB+RSI平均回帰の統計的エッジが有効な状態です。",
		BBUpper:      158.950,
		BBLower:      158.350,
		RSI:          48.5,
		ADX:          18.2,
		ATRPips:      14.5,
		EntryAllowed: true,
		UpdatedAt:    time.Now(),
	}

	// Calculate recent loss streak
	lossStreak := 0
	for i := len(trades) - 1; i >= 0; i-- {
		if trades[i].Profit < 0 {
			lossStreak++
		} else {
			break
		}
	}

	profile, err := h.adaptiveService.AdaptMarketHabit(ctx, "MANUAL_TRIGGER", regime, &metrics, lossStreak)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error(), "profile": profile})
		return
	}

	// Broadcast updated profile via WebSocket
	h.wsHub.BroadcastJSON(gin.H{
		"type":    "ADAPTIVE_PROFILE_UPDATED",
		"profile": profile,
	})

	c.JSON(http.StatusOK, gin.H{
		"status":  "success",
		"profile": profile,
	})
}

