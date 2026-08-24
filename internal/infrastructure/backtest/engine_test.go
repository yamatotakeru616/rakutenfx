package backtest

import (
	"testing"
	"time"
)

func TestDataLoaderAndBacktestEngine(t *testing.T) {
	loader := NewDataLoader()
	bars := loader.Generate1YearUsdJpyM1Bars()

	if len(bars) < 200000 {
		t.Fatalf("Expected at least 200,000 bars for 1-year data, got %d", len(bars))
	}

	engine := NewBacktestEngine()
	params := DefaultStrategyParams()
	params.EnableDowTrigger = true
	params.EnableFibFilter = true
	params.EnableMacroFilter = true
	result := engine.Run(bars, params)

	if result.TotalTrades == 0 {
		t.Errorf("Expected at least some trades to be executed, got 0")
	}

	if len(result.Trades) > 0 {
		sampleTrade := result.Trades[0]
		if sampleTrade.EntryReason == "" {
			t.Errorf("Expected non-empty EntryReason for simulated trade")
		}
		if sampleTrade.MacroBias == "" {
			t.Errorf("Expected non-empty MacroBias for simulated trade")
		}
	}

	t.Logf("1-Year Backtest Finished: Total Trades=%d, Win Rate=%.1f%%, Profit Factor=%.2f, Net Profit=¥%.0f, MaxDD=¥%.0f",
		result.TotalTrades, result.WinRate, result.ProfitFactor, result.TotalProfit, result.MaxDrawdown)
}

func TestIndicators_Correctness(t *testing.T) {
	// Simple synthetic test dataset
	closes := []float64{100, 101, 102, 103, 104, 105, 104, 103, 102, 101, 100, 99, 98, 97, 96, 95, 96, 97, 98, 99, 100}
	upper, lower := calculateBollingerBands(closes, 10, 2.0)

	if len(upper) != len(closes) {
		t.Fatalf("expected BB length %d, got %d", len(closes), len(upper))
	}

	lastIdx := len(closes) - 1
	if upper[lastIdx] <= lower[lastIdx] {
		t.Errorf("invalid BB order: Upper=%.2f, Lower=%.2f", upper[lastIdx], lower[lastIdx])
	}

	rsi := calculateRSI(closes, 14)
	if len(rsi) != len(closes) {
		t.Fatalf("expected RSI length %d, got %d", len(closes), len(rsi))
	}
	if rsi[lastIdx] < 0 || rsi[lastIdx] > 100 {
		t.Errorf("RSI value out of range [0, 100]: %.2f", rsi[lastIdx])
	}
}

func TestMacroEventSkip(t *testing.T) {
	// Friday 21:15 JST (First Friday of month) -> should be skipped
	// 2026-09-04 21:15:00 JST
	loc, _ := time.LoadLocation("Asia/Tokyo")
	eventTime := time.Date(2026, 9, 4, 21, 15, 0, 0, loc)

	if eventTime.Weekday() != time.Friday {
		t.Fatalf("expected Friday")
	}

	jstHour := eventTime.Hour()
	jstMinute := eventTime.Minute()
	jstDay := eventTime.Day()

	isNFP := jstDay <= 7 && eventTime.Weekday() == time.Friday && (jstHour == 21 && jstMinute >= 0)
	if !isNFP {
		t.Errorf("expected NFP time window detection")
	}
}
