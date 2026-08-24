package usecase

import (
	"rakutenfx/internal/domain"
	"testing"
)

func TestTradeAnalyzer_CalculateMetrics(t *testing.T) {
	analyzer := NewTradeAnalyzer()

	p1, p2 := 158.80, 158.94
	t1, t2 := "2026-08-20 10:30:00", "2026-08-20 11:15:00"

	trades := []domain.TradeRecord{
		{
			Ticket:     1,
			Profit:     10000.0,
			ClosePrice: &p1,
			CloseTime:  &t1,
		},
		{
			Ticket:     2,
			Profit:     -2000.0,
			ClosePrice: &p2,
			CloseTime:  &t2,
		},
	}

	metrics := analyzer.CalculateMetrics(trades)

	if metrics.TotalTrades != 2 {
		t.Errorf("expected 2 total trades, got %d", metrics.TotalTrades)
	}
	if metrics.WinningTrades != 1 {
		t.Errorf("expected 1 winning trade, got %d", metrics.WinningTrades)
	}
	if metrics.LosingTrades != 1 {
		t.Errorf("expected 1 losing trade, got %d", metrics.LosingTrades)
	}
	if metrics.WinRate != 50.0 {
		t.Errorf("expected 50.0 win rate, got %f", metrics.WinRate)
	}
	if metrics.TotalProfit != 8000.0 {
		t.Errorf("expected 8000.0 total profit, got %f", metrics.TotalProfit)
	}
	if metrics.ProfitFactor != 5.0 {
		t.Errorf("expected 5.0 PF, got %f", metrics.ProfitFactor)
	}
}
