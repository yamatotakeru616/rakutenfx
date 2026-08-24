package http

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"rakutenfx/internal/domain"
	"rakutenfx/internal/infrastructure/ai"
	"rakutenfx/internal/infrastructure/ipc"
	"rakutenfx/internal/infrastructure/persistence"
	"rakutenfx/internal/usecase"
	"rakutenfx/web"
	"testing"

	"github.com/gin-gonic/gin"
)

func setupTestRouter(t *testing.T) (*gin.Engine, *persistence.SQLiteRepository) {
	gin.SetMode(gin.TestMode)
	tmpDir, err := os.MkdirTemp("", "handler_test_*")
	if err != nil {
		t.Fatalf("failed to create temp dir: %v", err)
	}

	dbPath := filepath.Join(tmpDir, "test.db")
	repo, err := persistence.NewSQLiteRepository(dbPath)
	if err != nil {
		t.Fatalf("failed to init sqlite repo: %v", err)
	}

	analyzer := usecase.NewTradeAnalyzer()
	geminiClient := ai.NewGeminiClient()
	ipcServer := ipc.NewIpcServer("127.0.0.1:0", repo)
	wsHub := NewWebSocketHub()
	go wsHub.Run()

	h := NewHandler(repo, analyzer, geminiClient, ipcServer, wsHub)

	return SetupRouter(h, web.StaticFS), repo
}

func TestHandler_StatusEndpoints(t *testing.T) {
	router, repo := setupTestRouter(t)
	defer repo.Close()

	// 1. Test /api/status
	w := httptest.NewRecorder()
	req, _ := http.NewRequest("GET", "/api/status", nil)
	router.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", w.Code)
	}

	var statusResp map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &statusResp); err != nil {
		t.Fatalf("failed to parse status JSON: %v", err)
	}
	if statusResp["status"] != "online" {
		t.Errorf("expected online status, got %v", statusResp["status"])
	}

	// 2. Test /api/macro/fundamental-status
	wMacro := httptest.NewRecorder()
	reqMacro, _ := http.NewRequest("GET", "/api/macro/fundamental-status", nil)
	router.ServeHTTP(wMacro, reqMacro)

	if wMacro.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", wMacro.Code)
	}

	var macroResp domain.MacroFundamentalStatus
	if err := json.Unmarshal(wMacro.Body.Bytes(), &macroResp); err != nil {
		t.Fatalf("failed to parse macro JSON: %v", err)
	}
	if macroResp.NextEventName == "" {
		t.Errorf("expected non-empty NextEventName")
	}

	// 3. Test /api/metrics
	wMetrics := httptest.NewRecorder()
	reqMetrics, _ := http.NewRequest("GET", "/api/metrics", nil)
	router.ServeHTTP(wMetrics, reqMetrics)

	if wMetrics.Code != http.StatusOK {
		t.Errorf("expected status 200 for metrics, got %d", wMetrics.Code)
	}

	// 4. Test /api/backtest/history
	wHistory := httptest.NewRecorder()
	reqHistory, _ := http.NewRequest("GET", "/api/backtest/history", nil)
	router.ServeHTTP(wHistory, reqHistory)

	if wHistory.Code != http.StatusOK {
		t.Errorf("expected status 200 for history, got %d", wHistory.Code)
	}
}
