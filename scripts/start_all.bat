@echo off
chcp 65001 > nul
title 🚀 楽天MT4 AIクオンツ パイプライン 一括起動ランナー

echo ======================================================================
echo    🚀 楽天MT4 AIクオンツ パイプライン (Port 5555 & 5556)
echo ======================================================================
echo.

cd /d "%~dp0\.."

echo [1/2] Python AI キルスイッチ IPC サーバー (Port 5556) を起動中...
start "Python AI Kill-Switch IPC [Port 5556]" cmd /k "python python\evaluator\ipc_server.py"

timeout /t 2 /nobreak > nul

echo [2/2] Rust 超高速 Gateway サーバー (Port 5555) を起動中...
start "Rust Ultra-Fast Gateway [Port 5555]" cmd /k "cargo run --bin gateway -- serve"

echo.
echo ======================================================================
echo  ✅ 全サーバーの起動が完了しました！
echo  MT4で EA (RakutenTradeAgent) をチャートに適用してください。
echo ======================================================================
echo.
pause
