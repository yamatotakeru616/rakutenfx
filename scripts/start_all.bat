@echo off
chcp 65001 > nul
title 🚀 楽天MT4 AIクオンツ パイプライン 一括起動ランナー (Go + Rust)

echo ======================================================================
echo    🚀 楽天MT4 AIクオンツ パイプライン (Port 5555 / 5556 / 8080)
echo    - Rust Ultra-Fast Gateway : Port 5555 (MT4 TCP)
echo    - Go AI Kill-Switch IPC   : Port 5556 (TCP Socket)
echo    - Go Pro Cockpit Web UI   : http://localhost:8080
echo ======================================================================
echo.

cd /d "%~dp0\.."

:: 1. 既存プロセスのチェックまたは起動
tasklist /FI "IMAGENAME eq rakutenfx.exe" 2>NUL | find /I /N "rakutenfx.exe">NUL
if "%ERRORLEVEL%"=="0" (
    echo [1/2] ℹ️ Go サーバー (rakutenfx.exe) は既に稼働中です (Port 8080 & 5556)
) else (
    echo [1/2] 🚀 Go クオンツ & AIキルスイッチ サーバー (Port 8080 & 5556) を起動中...
    if exist "rakutenfx.exe" (
        start "Rakuten FX Go Server [Port 8080 & 5556]" cmd /k "rakutenfx.exe"
    ) else (
        start "Rakuten FX Go Server [Port 8080 & 5556]" cmd /k "go run ./cmd/server/main.go"
    )
    timeout /t 2 /nobreak > nul
)

:: 2. Rust Gateway のチェックまたは起動
tasklist /FI "IMAGENAME eq gateway.exe" 2>NUL | find /I /N "gateway.exe">NUL
if "%ERRORLEVEL%"=="0" (
    echo [2/2] ℹ️ Rust Gateway (gateway.exe) は既に稼働中です (Port 5555)
) else (
    echo [2/2] 🚀 Rust 超高速 Gateway サーバー (Port 5555) を起動中...
    if exist "target\debug\gateway.exe" (
        start "Rust Ultra-Fast Gateway [Port 5555]" cmd /k "target\debug\gateway.exe serve"
    ) else (
        start "Rust Ultra-Fast Gateway [Port 5555]" cmd /k "cargo run --bin gateway -- serve"
    )
)

timeout /t 1 /nobreak > nul

:: 3. ブラウザで Web コクピットを開く
start http://localhost:8080

echo.
echo ======================================================================
echo  ✅ 全サーバーが準備完了しました！
echo  - Web コクピット: http://localhost:8080 (ブラウザで開きました)
echo  - MT4で EA (RakutenTradeAgent) をチャートに適用してください。
echo  - サーバーを停止する場合は scripts\stop_all.bat を実行してください。
echo ======================================================================
echo.
pause
