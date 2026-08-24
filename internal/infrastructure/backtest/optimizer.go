package backtest

import (
	"math"
	"runtime"
	"sort"
	"sync"
)

// GridSearchResult holds single parameter configuration and resulting score
type GridSearchResult struct {
	Params          StrategyParams `json:"params"`
	ProfitFactor    float64        `json:"profit_factor"`
	WinRate         float64        `json:"win_rate"`
	TotalProfit     float64        `json:"total_profit"`
	MaxDrawdown     float64        `json:"max_drawdown"`
	TotalTrades     int            `json:"total_trades"`
	RobustnessScore float64        `json:"robustness_score"`
	Rank            int            `json:"rank"`
}

// Optimizer executes parallel grid search for optimal parameters
type Optimizer struct {
	engine *BacktestEngine
}

func NewOptimizer(engine *BacktestEngine) *Optimizer {
	return &Optimizer{engine: engine}
}

// OptimizeGrid executes parallel hyperparameter search across multiple worker goroutines
func (o *Optimizer) OptimizeGrid(bars []Bar) []GridSearchResult {
	// Candidate search space
	bbStdDevs := []float64{1.8, 2.0, 2.2, 2.5}
	rsiThresholds := []struct{ Oversold, Overbought float64 }{
		{25.0, 75.0},
		{30.0, 70.0},
		{35.0, 65.0},
	}
	adxThresholds := []float64{20.0, 25.0, 30.0}
	atrFactors := []float64{1.3, 1.5, 1.8}
	timeouts := []int{60, 120, 180}

	tasks := make([]StrategyParams, 0)
	for _, bb := range bbStdDevs {
		for _, rsi := range rsiThresholds {
			for _, adx := range adxThresholds {
				for _, atr := range atrFactors {
					for _, to := range timeouts {
						p := DefaultStrategyParams()
						p.BBStdDev = bb
						p.RSIOversold = rsi.Oversold
						p.RSIOverbought = rsi.Overbought
						p.ADXThreshold = adx
						p.ATRFactor = atr
						p.TimeoutMinutes = to
						tasks = append(tasks, p)
					}
				}
			}
		}
	}

	numWorkers := runtime.NumCPU()
	taskChan := make(chan StrategyParams, len(tasks))
	resultChan := make(chan GridSearchResult, len(tasks))

	for _, t := range tasks {
		taskChan <- t
	}
	close(taskChan)

	var wg sync.WaitGroup
	for w := 0; w < numWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for param := range taskChan {
				res := o.engine.Run(bars, param)
				resultChan <- GridSearchResult{
					Params:          param,
					ProfitFactor:    res.ProfitFactor,
					WinRate:         res.WinRate,
					TotalProfit:     res.TotalProfit,
					MaxDrawdown:     res.MaxDrawdown,
					TotalTrades:     res.TotalTrades,
					RobustnessScore: res.RobustnessScore,
				}
			}
		}()
	}

	wg.Wait()
	close(resultChan)

	results := make([]GridSearchResult, 0, len(tasks))
	for r := range resultChan {
		if r.TotalTrades >= 20 { // Filter out statistically insignificant sample sizes
			results = append(results, r)
		}
	}

	// Sort by RobustnessScore descending, then ProfitFactor descending
	sort.Slice(results, func(i, j int) bool {
		if results[i].RobustnessScore != results[j].RobustnessScore {
			return results[i].RobustnessScore > results[j].RobustnessScore
		}
		if results[i].ProfitFactor != results[j].ProfitFactor {
			return results[i].ProfitFactor > results[j].ProfitFactor
		}
		return results[i].TotalProfit > results[j].TotalProfit
	})

	// Assign Ranks
	for i := range results {
		results[i].Rank = i + 1
		results[i].ProfitFactor = math.Round(results[i].ProfitFactor*100) / 100
		results[i].WinRate = math.Round(results[i].WinRate*10) / 10
	}

	// Return top 20 configurations
	if len(results) > 20 {
		return results[:20]
	}
	return results
}
