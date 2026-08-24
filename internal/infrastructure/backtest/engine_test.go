package backtest

import (
	"testing"
)

func TestDataLoaderAndBacktestEngine(t *testing.T) {
	loader := NewDataLoader()
	bars := loader.Generate1YearUsdJpyM1Bars()

	if len(bars) < 200000 {
		t.Fatalf("Expected at least 200,000 bars for 1-year data, got %d", len(bars))
	}

	engine := NewBacktestEngine()
	params := DefaultStrategyParams()
	result := engine.Run(bars, params)

	if result.TotalTrades == 0 {
		t.Errorf("Expected at least some trades to be executed, got 0")
	}

	t.Logf("1-Year Backtest Finished: Total Trades=%d, Win Rate=%.1f%%, Profit Factor=%.2f, Net Profit=¥%.0f, MaxDD=¥%.0f",
		result.TotalTrades, result.WinRate, result.ProfitFactor, result.TotalProfit, result.MaxDrawdown)
}
