import os
from typing import Optional
import requests

from analyzer import TradeMetrics


def load_env_file() -> None:
    for filepath in [".env", ".env.example"]:
        if os.path.exists(filepath):
            with open(filepath, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        key, val = line.split("=", 1)
                        os.environ.setdefault(key.strip(), val.strip())


load_env_file()


class DiscordNotifier:
    def __init__(self, webhook_url: Optional[str] = None):
        self.webhook_url = webhook_url or os.environ.get("DISCORD_WEBHOOK_URL")

    def send_report(
        self,
        metrics: TradeMetrics,
        ai_evaluation: str,
        chart_image_path: Optional[str] = None,
    ) -> bool:
        if not self.webhook_url:
            print("[Info] DISCORD_WEBHOOK_URL is not set. Printing report to console:")
            print("=" * 60)
            print(f"Total Profit: {metrics.total_profit:,.1f} JPY | Win Rate: {metrics.win_rate:.1f}% | PF: {metrics.profit_factor:.2f}")
            print("-" * 60)
            print(ai_evaluation)
            print("=" * 60)
            return True

        embed_color = 0x22c55e if metrics.total_profit >= 0 else 0xef4444

        embed = {
            "title": "MT4 Automated Trading Performance Report",
            "color": embed_color,
            "fields": [
                {
                    "name": "Performance Summary",
                    "value": f"**Total Profit**: `{metrics.total_profit:,.1f} JPY`\n**Win Rate**: `{metrics.win_rate:.1f}%` ({metrics.winning_trades}W {metrics.losing_trades}L)\n**PF**: `{metrics.profit_factor:.2f}`",
                    "inline": True,
                },
                {
                    "name": "Risk Metrics",
                    "value": f"**Max DD**: `{metrics.max_drawdown:,.1f} JPY`\n**Max Win**: `+{metrics.largest_win:,.1f} JPY`\n**Max Loss**: `{metrics.largest_loss:,.1f} JPY`",
                    "inline": True,
                },
                {
                    "name": "AI Diagnosis & Feedback",
                    "value": ai_evaluation[:1024],  # Limit to 1024 characters for Discord embed
                    "inline": False,
                },
            ],
            "footer": {
                "text": "MT4 Trading Pipeline • Powered by Rust & Gemini AI",
            },
        }

        try:
            if chart_image_path and os.path.exists(chart_image_path):
                with open(chart_image_path, "rb") as f:
                    response = requests.post(
                        self.webhook_url,
                        data={"payload_json": f'{{"embeds": [{requests.compat.json.dumps(embed)}]}}'},
                        files={"file": (os.path.basename(chart_image_path), f, "image/png")},
                        timeout=10,
                    )
            else:
                response = requests.post(
                    self.webhook_url,
                    json={"embeds": [embed]},
                    timeout=10,
                )

            if response.status_code in (200, 204):
                print("[Success] Successfully sent report to Discord Webhook!")
                return True
            else:
                print(f"[Error] Failed to send to Discord: Status {response.status_code} - {response.text}")
                return False
        except Exception as e:
            print(f"[Error] Error sending Discord notification: {e}")
            return False
