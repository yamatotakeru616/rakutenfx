import argparse
import os
import sys

# Windows CP932 環境対応
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

from ai_agent import TradeAiAgent
from analyzer import TradeAnalyzer
from charts import ChartGenerator
from notifier import DiscordNotifier


def main():
    parser = argparse.ArgumentParser(description="MT4 Trade Performance Evaluator & AI Notifier")
    parser.add_argument("--db", type=str, default="trade_pipeline.db", help="Path to SQLite database")
    parser.add_argument("--webhook", type=str, default=None, help="Discord Webhook URL")
    parser.add_argument("--chart-dir", type=str, default="artifacts/reports", help="Directory to save chart images")
    args = parser.parse_args()

    print(f"[1/4] Loading trade logs from {args.db}...")
    analyzer = TradeAnalyzer(db_path=args.db)
    metrics = analyzer.calculate_metrics()

    if not metrics:
        print("[Warning] No closed trades found in database. Generating baseline demo dashboard for docs/...")
        demo_trades = [
            TradeRecord(ticket=10001, symbol='USDJPY', action='BUY', lots=0.5, open_price=158.50, close_price=158.80, open_time='2026-08-20 10:00:00', close_time='2026-08-20 10:30:00', profit=15000.0, comment='AutoOrder_FibDow'),
            TradeRecord(ticket=10002, symbol='USDJPY', action='SELL', lots=0.5, open_price=158.90, close_price=158.94, open_time='2026-08-20 11:00:00', close_time='2026-08-20 11:15:00', profit=-2000.0, comment='AutoOrder_FibDow'),
            TradeRecord(ticket=10003, symbol='USDJPY', action='BUY', lots=0.5, open_price=158.55, close_price=159.05, open_time='2026-08-20 12:00:00', close_time='2026-08-20 12:45:00', profit=25000.0, comment='AutoOrder_FibDow')
        ]
        metrics = TradeMetrics(
            total_trades=3,
            winning_trades=2,
            losing_trades=1,
            win_rate=66.7,
            total_profit=38000.0,
            gross_profit=40000.0,
            gross_loss=2000.0,
            profit_factor=20.0,
            max_drawdown=2000.0,
            max_drawdown_pct=1.4,
            avg_trade_profit=12666.7,
            largest_win=25000.0,
            largest_loss=-2000.0,
            trades=demo_trades
        )

    print(f"[2/4] Calculated metrics for {metrics.total_trades} trades. Generating chart...")
    chart_gen = ChartGenerator(output_dir=args.chart_dir)
    chart_path = chart_gen.generate_equity_curve(metrics.trades)
    print(f"      Chart saved to: {chart_path}")

    # docs/ フォルダ（GitHub Pages用）にも同時出力
    docs_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "docs"))
    if not os.path.exists(docs_dir):
        docs_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "docs"))
    docs_chart_gen = ChartGenerator(output_dir=docs_dir)
    docs_chart_path = docs_chart_gen.generate_equity_curve(metrics.trades, filename="equity_curve.svg")

    print("[3/4] Generating AI Trade Diagnosis with Gemini & Multimodal Images...")
    ai_agent = TradeAiAgent()
    evaluation = ai_agent.evaluate_performance(metrics)

    # チャート画像とGemini診断の収集
    screenshots_data = []
    trades_dir = "artifacts/trades"
    if os.path.exists(trades_dir):
        for t in metrics.trades[-6:]:  # 直近6トレード
            img_name = f"ticket_{t.ticket}.png"
            img_path = os.path.join(trades_dir, img_name)
            if os.path.exists(img_path):
                img_diag = ai_agent.evaluate_chart_screenshot(img_path, trade_info={
                    "symbol": t.symbol,
                    "action": t.action,
                    "price": t.open_price,
                    "lot": t.lots,
                    "profit": t.profit,
                })
                screenshots_data.append({
                    "ticket": t.ticket,
                    "image_path": img_path,
                    "rank": "S" if t.profit > 1000 else ("A" if t.profit >= 0 else "B"),
                    "feedback": img_diag[:150] + "...",
                    "profit": t.profit,
                })

    # HTMLダッシュボードの生成 (artifacts/reports/ ＆ docs/)
    dashboard_path = chart_gen.generate_html_dashboard(
        metrics=metrics,
        ai_evaluation=evaluation,
        equity_chart_path=chart_path,
        trade_screenshots=screenshots_data,
    )
    docs_dashboard_path = docs_chart_gen.generate_html_dashboard(
        metrics=metrics,
        ai_evaluation=evaluation,
        equity_chart_path=docs_chart_path,
        trade_screenshots=screenshots_data,
        filename="index.html"
    )
    print(f"      HTML Dashboard generated: {dashboard_path} & {docs_dashboard_path}")

    print("[4/4] Finalizing evaluation pipeline...")
    if args.webhook:
        notifier = DiscordNotifier(webhook_url=args.webhook)
        notifier.send_report(metrics=metrics, ai_evaluation=evaluation, chart_image_path=chart_path)

    print("\n[SUCCESS] Evaluation pipeline completed successfully!")


if __name__ == "__main__":
    main()
