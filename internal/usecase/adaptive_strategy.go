package usecase

import (
	"context"
	"log"
	"rakutenfx/internal/domain"
	"rakutenfx/internal/infrastructure/ai"
	"sync"
	"time"
)

// AdaptiveStrategyService manages AI co-evolution, macro analysis, and hyperparameter auto-tuning.
type AdaptiveStrategyService struct {
	aiClient           *ai.GeminiClient
	currentProfile     *domain.AdaptiveProfile
	currentMacroStatus *domain.MacroFundamentalStatus
	mu                 sync.RWMutex
}

func NewAdaptiveStrategyService(aiClient *ai.GeminiClient) *AdaptiveStrategyService {
	// Initialize with Default S-Class Profile
	defaultProfile := &domain.AdaptiveProfile{
		SessionName:          "ACTIVE_SESSION",
		MarketHabit:          "レンジ平均回帰型 (Mean Reverting)",
		EdgeHealthScore:      92,
		RecommendedBBStd:     2.0,
		RecommendedRSIOS:     30.0,
		RecommendedRSIOB:     70.0,
		RecommendedADX:       25.0,
		RecommendedATRFactor: 1.5,
		RecommendedTimeout:   120,
		RecommendedLot:       0.20,
		DecayWarning:         false,
		ActionRationale:      "AI共創エンジン稼働中。市場の癖とアルゴリズムの整合性を常時監視し、陳腐化を未然に防衛。",
		AdaptedAt:            time.Now(),
	}

	defaultMacro := &domain.MacroFundamentalStatus{
		NextEventName:        "米CPI (消費者物価指数)",
		NextEventTime:        time.Now().Add(2 * time.Hour),
		MinutesToEvent:       120,
		ImpactLevel:          "HIGH",
		EventKillSwitchArmed: false,
		US10YYield:           4.25,
		JP10YYield:           0.85,
		YieldSpread:          3.40,
		MacroBias:            "BULLISH_USD",
		GeminiSentimentScore: 0.65,
		GeminiRationale:      "米金利高止まりと日銀緩和継続スタンスにより、マクロ的ドル高円安トレンド継続。押し目買い優位。",
		UpdatedAt:            time.Now(),
	}

	return &AdaptiveStrategyService{
		aiClient:           aiClient,
		currentProfile:     defaultProfile,
		currentMacroStatus: defaultMacro,
	}
}

// GetMacroStatus returns the current macroeconomic & fundamental status.
func (s *AdaptiveStrategyService) GetMacroStatus() *domain.MacroFundamentalStatus {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.currentMacroStatus
}

// UpdateMacroStatus updates the current macroeconomic & fundamental status.
func (s *AdaptiveStrategyService) UpdateMacroStatus(status *domain.MacroFundamentalStatus) *domain.MacroFundamentalStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	if status.UpdatedAt.IsZero() {
		status.UpdatedAt = time.Now()
	}
	s.currentMacroStatus = status
	log.Printf("[AdaptiveStrategy] 🌍 Macro Status Updated: NextEvent='%s', Armed=%v, Spread=%.2f%%, Bias='%s', GeminiScore=%.2f",
		status.NextEventName, status.EventKillSwitchArmed, status.YieldSpread, status.MacroBias, status.GeminiSentimentScore)
	return s.currentMacroStatus
}

// GetCurrentProfile returns the latest adapted hyperparameter profile.
func (s *AdaptiveStrategyService) GetCurrentProfile() *domain.AdaptiveProfile {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.currentProfile
}

// AdaptMarketHabit triggers an AI diagnosis and updates parameters dynamically.
func (s *AdaptiveStrategyService) AdaptMarketHabit(
	ctx context.Context,
	triggerReason string,
	regime *domain.MarketRegimeInfo,
	metrics *domain.TradeMetrics,
	lossStreak int,
) (*domain.AdaptiveProfile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Determine session name
	jstHour := (time.Now().UTC().Hour() + 9) % 24
	sessionName := "TOKYO_SESSION"
	if jstHour >= 16 && jstHour < 21 {
		sessionName = "LONDON_SESSION"
	} else if jstHour >= 21 || jstHour < 2 {
		sessionName = "NEW_YORK_SESSION"
	}
	if triggerReason != "" {
		sessionName = sessionName + " [" + triggerReason + "]"
	}

	profile, err := s.aiClient.AnalyzeMarketHabitAndAdapt(ctx, sessionName, regime, metrics, lossStreak)
	if err != nil {
		log.Printf("[AdaptiveStrategy] AI Adaptation warning: %v", err)
		return s.currentProfile, err
	}

	s.currentProfile = profile
	log.Printf("[AdaptiveStrategy] 🧠 AI Strategy Adapted: Habit='%s', HealthScore=%d, BB=%.1fσ, RSI=%.0f/%.0f, ADX=%.0f, Timeout=%dm",
		profile.MarketHabit, profile.EdgeHealthScore, profile.RecommendedBBStd, profile.RecommendedRSIOS, profile.RecommendedRSIOB, profile.RecommendedADX, profile.RecommendedTimeout)

	return profile, nil
}

// ApplyProfile allows external optimizers (e.g., Python Optuna) to directly inject optimal profiles.
func (s *AdaptiveStrategyService) ApplyProfile(profile *domain.AdaptiveProfile) *domain.AdaptiveProfile {
	s.mu.Lock()
	defer s.mu.Unlock()

	if profile.AdaptedAt.IsZero() {
		profile.AdaptedAt = time.Now()
	}
	s.currentProfile = profile
	log.Printf("[AdaptiveStrategy] ⚡ External Profile Applied (Optuna/ML): Habit='%s', Score=%d, BB=%.1fσ, RSI=%.0f/%.0f, ADX=%.0f, Timeout=%dm",
		profile.MarketHabit, profile.EdgeHealthScore, profile.RecommendedBBStd, profile.RecommendedRSIOS, profile.RecommendedRSIOB, profile.RecommendedADX, profile.RecommendedTimeout)

	return s.currentProfile
}

