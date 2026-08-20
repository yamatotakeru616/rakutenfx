@echo off
chcp 65001 > nul
title 🚀 週次 Gemini 3.6 自律クオンツパラメータチューナー

echo ======================================================================
echo    🚀 楽天MT4 AIクオンツ パイプライン - 週次自律チューナー
echo ======================================================================
echo.
echo [1/2] 過去1週間の取引履歴（DuckDB / SQLite）を集計し、Gemini 3.6 に最適化を要請中...
echo.

cd /d "%~dp0\.."
python python\evaluator\auto_tuner.py

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ❌ [Error] パラメータチューニング中にエラーが発生しました。
) else (
    echo.
    echo ======================================================================
    echo  ✅ [Success] config.toml のパラメータ更新が正常に完了しました！
    echo ======================================================================
    echo.
    echo [最新の config.toml 設定内容]
    type config.toml
)

echo.
echo 処理が完了しました。Enterキーを押すと終了します。
pause > nul
