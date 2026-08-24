package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/joho/godotenv"

	handlerHttp "rakutenfx/internal/handler/http"
	"rakutenfx/internal/infrastructure/ai"
	"rakutenfx/internal/infrastructure/ipc"
	"rakutenfx/internal/infrastructure/persistence"
	"rakutenfx/internal/usecase"
	"rakutenfx/web"
)

func main() {
	log.Println("======================================================================")
	log.Println("  🚀 Rakuten FX Quant Server - Go Native Single Binary Edition")
	log.Println("======================================================================")

	// 1. 環境変数の読み込み (.env)
	if err := godotenv.Load(); err != nil {
		log.Println("[INFO] No .env file found or error loading, using system environment variables")
	}

	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "trade_pipeline.db"
	}

	httpPort := os.Getenv("HTTP_PORT")
	if httpPort == "" {
		httpPort = "8080"
	}

	ipcAddr := os.Getenv("IPC_ADDR")
	if ipcAddr == "" {
		ipcAddr = "127.0.0.1:5556"
	}

	// 2. SQLite リポジトリ初期化 (CGOレス WALモード)
	repo, err := persistence.NewSQLiteRepository(dbPath)
	if err != nil {
		log.Fatalf("[FATAL] Database initialization failed: %v", err)
	}
	defer repo.Close()

	// 3. コアユースケース & AI クライアント初期化
	analyzer := usecase.NewTradeAnalyzer()
	geminiClient := ai.NewGeminiClient()

	// 4. AI キルスイッチ TCP IPC サーバー (Port 5556) 起動
	ipcServer := ipc.NewIpcServer(ipcAddr, repo)
	if err := ipcServer.Start(); err != nil {
		log.Fatalf("[FATAL] IPC server start failed: %v", err)
	}
	defer ipcServer.Close()

	// 5. リアルタイム WebSocket Hub 起動
	wsHub := handlerHttp.NewWebSocketHub()
	go wsHub.Run()

	// 6. Gin REST API & Web UI ルーター設定 (web.StaticFS 内包)
	handler := handlerHttp.NewHandler(repo, analyzer, geminiClient, ipcServer, wsHub)
	router := handlerHttp.SetupRouter(handler, web.StaticFS)

	srv := &http.Server{
		Addr:    ":" + httpPort,
		Handler: router,
	}

	// 7. HTTP サーバーをゴルーチンで起動
	go func() {
		log.Printf("🌐 [Web HUD] Dashboard & REST API listening on http://localhost:%s", httpPort)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("[FATAL] HTTP server error: %v", err)
		}
	}()

	// 8. グレースフルシャットダウン待機
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("[INFO] Shutting down Rakuten FX Go Server...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("[ERROR] Server forced to shutdown: %v", err)
	}

	log.Println("✅ [SUCCESS] Rakuten FX Go Server exited cleanly.")
}
