package usecase

import (
	"context"
	"log"
	"rakutenfx/internal/domain"
	"rakutenfx/internal/infrastructure/ai"
	"sync"
	"time"
)

// AdaptiveStrategyService manages AI co-evolution and hyperparameter auto-tuning.
type AdaptiveStrategyService struct {
	aiClient       *ai.GeminiClient
	currentProfile *domain.AdaptiveProfile
	mu             sync.RWMutex
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

	return &AdaptiveStrategyService{
		aiClient:       aiClient,
		currentProfile: defaultProfile,
	}
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
