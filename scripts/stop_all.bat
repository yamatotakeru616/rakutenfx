@echo off
chcp 65001 > nul
title 🛑 楽天MT4 AIクオンツ パイプライン 一括停止

echo ======================================================================
echo    🛑 楽天MT4 AIクオンツ パイプライン サーバー停止
echo ======================================================================
echo.

taskkill /F /IM rakutenfx.exe /T 2>nul
taskkill /F /IM gateway.exe /T 2>nul

echo.
echo ✅ 全サーバープロセス（Go Server / Rust Gateway）を停止しました。
echo.
pause
