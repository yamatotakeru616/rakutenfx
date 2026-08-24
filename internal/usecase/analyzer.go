package usecase

import (
	"math"
	"rakutenfx/internal/domain"
)

type TradeAnalyzer struct{}

func NewTradeAnalyzer() *TradeAnalyzer {
	return &TradeAnalyzer{}
}

// CalculateMetrics calculates comprehensive performance metrics from closed trade records.
func (a *TradeAnalyzer) CalculateMetrics(trades []domain.TradeRecord) domain.TradeMetrics {
	if len(trades) == 0 {
		return a.GenerateBaselineMetrics()
	}

	var winningCount, losingCount int
	var grossProfit, grossLoss, totalProfit float64
	var largestWin, largestLoss float64
	var peakEquity, currentEquity, maxDrawdown float64
	var consecutiveWins, maxWins, consecutiveLosses, maxLosses int

	for _, t := range trades {
		p := t.Profit
		totalProfit += p
		currentEquity += p

		if currentEquity > peakEquity {
			peakEquity = currentEquity
		}
		dd := peakEquity - currentEquity
		if dd > maxDrawdown {
			maxDrawdown = dd
		}

		if p > 0 {
			winningCount++
			grossProfit += p
			if p > largestWin {
				largestWin = p
			}
			consecutiveWins++
			consecutiveLosses = 0
			if consecutiveWins > maxWins {
				maxWins = consecutiveWins
			}
		} else if p < 0 {
			losingCount++
			grossLoss += math.Abs(p)
			if p < largestLoss {
				largestLoss = p
			}
			consecutiveLosses++
			consecutiveWins = 0
			if consecutiveLosses > maxLosses {
				maxLosses = consecutiveLosses
			}
		}
	}

	totalTrades := len(trades)
	winRate := 0.0
	if totalTrades > 0 {
		winRate = (float64(winningCount) / float64(totalTrades)) * 100.0
	}

	pf := 0.0
	if grossLoss > 0 {
		pf = grossProfit / grossLoss
	} else if grossProfit > 0 {
		pf = 99.9
	}

	avgTradeProfit := 0.0
	if totalTrades > 0 {
		avgTradeProfit = totalProfit / float64(totalTrades)
	}

	maxDDPct := 0.0
	if peakEquity > 0 {
		maxDDPct = (maxDrawdown / peakEquity) * 100.0
	}

	// 推奨ロット動的計算 (0.10 ~ 0.50 Lot)
	recommendedLot := a.CalculateRecommendedLot(winRate, pf, maxLosses)

	return domain.TradeMetrics{
		TotalTrades:       totalTrades,
		WinningTrades:     winningCount,
		LosingTrades:      losingCount,
		WinRate:           math.Round(winRate*10) / 10,
		TotalProfit:       math.Round(totalProfit*100) / 100,
		GrossProfit:       math.Round(grossProfit*100) / 100,
		GrossLoss:         math.Round(grossLoss*100) / 100,
		ProfitFactor:      math.Round(pf*100) / 100,
		MaxDrawdown:       math.Round(maxDrawdown*100) / 100,
		MaxDrawdownPct:    math.Round(maxDDPct*10) / 10,
		AvgTradeProfit:    math.Round(avgTradeProfit*10) / 10,
		LargestWin:        largestWin,
		LargestLoss:       largestLoss,
		RecommendedLot:    recommendedLot,
		ConsecutiveWins:   maxWins,
		ConsecutiveLosses: maxLosses,
		Trades:            trades,
	}
}

// CalculateRecommendedLot determines dynamic position sizing based on recent edge.
func (a *TradeAnalyzer) CalculateRecommendedLot(winRate, pf float64, consecutiveLosses int) float64 {
	baseLot := 0.25

	// 連敗が多い場合は安全マージンを確保
	if consecutiveLosses >= 3 {
		return 0.10
	}

	// 高勝率かつ高PFの場合はロットを段階的に引き上げ
	if winRate >= 70.0 && pf >= 2.5 {
		return 0.50
	} else if winRate >= 60.0 && pf >= 1.8 {
		return 0.35
	} else if winRate < 45.0 || pf < 1.0 {
		return 0.10
	}

	return baseLot
}

// GenerateBaselineMetrics returns demo data when database has no closed trades.
func (a *TradeAnalyzer) GenerateBaselineMetrics() domain.TradeMetrics {
	p1, p2, p3 := 158.80, 158.94, 159.05
	t1, t2, t3 := "2026-08-20 10:30:00", "2026-08-20 11:15:00", "2026-08-20 12:45:00"

	demoTrades := []domain.TradeRecord{
		{
			Ticket:     10001,
			Symbol:     "USDJPY",
			Action:     "BUY",
			Lots:       0.5,
			OpenPrice:  158.50,
			ClosePrice: &p1,
			OpenTime:   "2026-08-20 10:00:00",
			CloseTime:  &t1,
			Profit:     15000.0,
			Comment:    "AutoOrder_FibDow_618",
			CreatedAt:  "2026-08-20 10:30:00",
		},
		{
			Ticket:     10002,
			Symbol:     "USDJPY",
			Action:     "SELL",
			Lots:       0.5,
			OpenPrice:  158.90,
			ClosePrice: &p2,
			OpenTime:   "2026-08-20 11:00:00",
			CloseTime:  &t2,
			Profit:     -2000.0,
			Comment:    "AutoOrder_FibDow_Cut4pips",
			CreatedAt:  "2026-08-20 11:15:00",
		},
		{
			Ticket:     10003,
			Symbol:     "USDJPY",
			Action:     "BUY",
			Lots:       0.5,
			OpenPrice:  158.55,
			ClosePrice: &p3,
			OpenTime:   "2026-08-20 12:00:00",
			CloseTime:  &t3,
			Profit:     25000.0,
			Comment:    "AutoOrder_FibDow_FE1618",
			CreatedAt:  "2026-08-20 12:45:00",
		},
	}

	return a.CalculateMetrics(demoTrades)
}
