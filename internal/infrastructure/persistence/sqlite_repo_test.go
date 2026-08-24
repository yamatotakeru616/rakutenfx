package persistence

import (
	"os"
	"path/filepath"
	"rakutenfx/internal/domain"
	"testing"
	"time"
)

func TestSQLiteRepository_FullFlow(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "sqlite_test_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	dbPath := filepath.Join(tmpDir, "test_rakutenfx.db")
	repo, err := NewSQLiteRepository(dbPath)
	if err != nil {
		t.Fatalf("failed to initialize SQLite repository: %v", err)
	}
	defer repo.Close()

	// 1. Test Save and Get Backtest Run
	runRec := &domain.BacktestRunRecord{
		Symbol:          "USDJPY",
		ParamsJSON:      `{"bb_std_dev":2.8,"rsi_oversold":30}`,
		TotalTrades:     100,
		WinRate:         45.0,
		ProfitFactor:    1.35,
		TotalProfit:     50000,
		MaxDrawdown:     15000,
		MaxDrawdownPct:  15.0,
		SharpeRatio:     1.8,
		RobustnessScore: 85.0,
		AiReportJSON:    `{"summary":"Excellent"}`,
	}

	runID, err := repo.SaveBacktestRun(runRec)
	if err != nil {
		t.Fatalf("SaveBacktestRun failed: %v", err)
	}
	if runID <= 0 {
		t.Fatalf("expected positive run ID, got %d", runID)
	}

	fetchedRun, err := repo.GetBacktestRunByID(runID)
	if err != nil {
		t.Fatalf("GetBacktestRunByID failed: %v", err)
	}
	if fetchedRun.ProfitFactor != 1.35 {
		t.Errorf("expected ProfitFactor 1.35, got %.2f", fetchedRun.ProfitFactor)
	}

	// 2. Test Save and Get Backtest Trades with EntryReason & MacroBias
	now := time.Now()
	trades := []domain.BacktestTradeRecord{
		{
			RunID:       runID,
			Ticket:      1,
			Action:      "BUY",
			Lots:        0.20,
			OpenPrice:   155.500,
			ClosePrice:  155.700,
			OpenTime:    now.Add(-time.Hour),
			CloseTime:   now,
			Profit:      4000,
			Pips:        20.0,
			Reason:      "TP_HIT",
			Regime:      "CLEAR",
			EntryReason: "4H FR 50% + Dow突破 | 日米金利差(3.4%)ドル高優勢",
			MacroBias:   "BULLISH_USD",
		},
		{
			RunID:       runID,
			Ticket:      2,
			Action:      "SELL",
			Lots:        0.20,
			OpenPrice:   156.000,
			ClosePrice:  156.075,
			OpenTime:    now.Add(-30 * time.Minute),
			CloseTime:   now.Add(-10 * time.Minute),
			Profit:      -1500,
			Pips:        -7.5,
			Reason:      "SL_HIT",
			Regime:      "CLEAR",
			EntryReason: "4H FR 61.8% + RSI 78 | 日米金利差(3.4%)ドル高優勢",
			MacroBias:   "BULLISH_USD",
		},
	}

	err = repo.SaveBacktestTrades(runID, trades)
	if err != nil {
		t.Fatalf("SaveBacktestTrades failed: %v", err)
	}

	fetchedTrades, err := repo.GetBacktestTradesByRunID(runID)
	if err != nil {
		t.Fatalf("GetBacktestTradesByRunID failed: %v", err)
	}
	if len(fetchedTrades) != 2 {
		t.Fatalf("expected 2 trades, got %d", len(fetchedTrades))
	}
	if fetchedTrades[0].EntryReason != trades[0].EntryReason {
		t.Errorf("expected EntryReason '%s', got '%s'", trades[0].EntryReason, fetchedTrades[0].EntryReason)
	}
	if fetchedTrades[0].MacroBias != "BULLISH_USD" {
		t.Errorf("expected MacroBias 'BULLISH_USD', got '%s'", fetchedTrades[0].MacroBias)
	}

	// 3. Test Signal and Tick Insertion
	sig := &domain.Signal{
		Symbol:         "USDJPY",
		Action:         "BUY",
		Lot:            0.20,
		StopLossPips:   7.5,
		TakeProfitPips: 15.8,
		Reason:         "AI Strategy Buy",
	}
	if err := repo.InsertSignal(sig); err != nil {
		t.Fatalf("InsertSignal failed: %v", err)
	}
	signals, err := repo.GetRecentSignals(10)
	if err != nil || len(signals) == 0 {
		t.Fatalf("GetRecentSignals failed: %v", err)
	}

	tick := &domain.Tick{
		Symbol: "USDJPY",
		Bid:    155.500,
		Ask:    155.502,
		Time:   "2026-08-24 17:00:00",
		Volume: 100,
	}
	if err := repo.InsertTick(tick); err != nil {
		t.Fatalf("InsertTick failed: %v", err)
	}
}
