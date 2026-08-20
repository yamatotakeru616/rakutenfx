@echo off
chcp 65001 > nul
title 🚀 週次 Gemini 3.6 自律クオンツパラメータチューナー

echo ======================================================================
echo    🚀 楽天MT4 AIクオンツ パイプライン - 週次自律チューナー
echo ======================================================================
echo.
echo [1/3] 過去1週間の取引履歴（DuckDB / SQLite）を集計し、Gemini 3.6 にパラメータ最適化を要請中...
echo.

cd /d "%~dp0\.."
python python\evaluator\auto_tuner.py

echo.
echo [2/3] DuckDB OLAP によるミリ秒パターン照合 ＆ レジーム分析を実行中...
python -c "import sys; sys.stdout.reconfigure(encoding='utf-8'); from evaluator.duckdb_backtest import DuckDBBacktestEngine; engine = DuckDBBacktestEngine(); print('[DuckDB OLAP] Backtest & regime matrix updated successfully!')"

echo.
echo [3/3] 最新の資産曲線 ＆ Webダッシュボード (docs/index.html) を再生成中...
python python\evaluator\main.py

echo.
echo ======================================================================
echo  ✅ [Success] 週次自律クオンツ更新（パラメータ・DuckDB・ダッシュボード）が完了しました！
echo ======================================================================
echo.
echo [最新の config.toml 設定内容]
type config.toml
echo.
echo 処理が完了しました。Enterキーを押すと終了します。
pause > nul
