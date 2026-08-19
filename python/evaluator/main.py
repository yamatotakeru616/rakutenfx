import argparse
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
        print("[Warning] No closed trades found in database. Exiting.")
        sys.exit(0)

    print(f"[2/4] Calculated metrics for {metrics.total_trades} trades. Generating chart...")
    chart_gen = ChartGenerator(output_dir=args.chart_dir)
    chart_path = chart_gen.generate_equity_curve(metrics.trades)
    print(f"      Chart saved to: {chart_path}")

    print("[3/4] Generating AI Trade Diagnosis with Gemini...")
    ai_agent = TradeAiAgent()
    evaluation = ai_agent.evaluate_performance(metrics)

    print("[4/4] Sending report to Discord...")
    notifier = DiscordNotifier(webhook_url=args.webhook)
    notifier.send_report(metrics=metrics, ai_evaluation=evaluation, chart_image_path=chart_path)

    print("\n[SUCCESS] Evaluation pipeline completed successfully!")


if __name__ == "__main__":
    main()
