package http

import (
	"net/http"
	"rakutenfx/internal/domain"
	"rakutenfx/internal/infrastructure/ai"
	"rakutenfx/internal/infrastructure/ipc"
	"rakutenfx/internal/infrastructure/persistence"
	"rakutenfx/internal/usecase"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
)

type Handler struct {
	repo         *persistence.SQLiteRepository
	analyzer     *usecase.TradeAnalyzer
	geminiClient *ai.GeminiClient
	ipcServer    *ipc.IpcServer
	wsHub        *WebSocketHub
}

func NewHandler(
	repo *persistence.SQLiteRepository,
	analyzer *usecase.TradeAnalyzer,
	geminiClient *ai.GeminiClient,
	ipcServer *ipc.IpcServer,
	wsHub *WebSocketHub,
) *Handler {
	return &Handler{
		repo:         repo,
		analyzer:     analyzer,
		geminiClient: geminiClient,
		ipcServer:    ipcServer,
		wsHub:        wsHub,
	}
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
	
	// 直近シグナルまたはデフォルト値から4ステート状態を構築
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
		"status":      "online",
		"version":     "2.1.0 (Multi-Filter Mean Reversion Engine)",
		"ipc_port":    5556,
		"gateway_port": 5555,
		"kill_switch": isKill,
	})
}
