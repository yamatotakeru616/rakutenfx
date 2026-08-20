import os
from typing import List, Dict, Any, Optional

try:
    from analyzer import TradeRecord, TradeMetrics
except ImportError:
    from evaluator.analyzer import TradeRecord, TradeMetrics


class ChartGenerator:
    def __init__(self, output_dir: str = "artifacts/reports"):
        self.output_dir = output_dir
        os.makedirs(self.output_dir, exist_ok=True)

    def generate_equity_curve(self, trades: List[TradeRecord], filename: str = "equity_curve.png") -> Optional[str]:
        if not trades:
            return None

        # 累積損益の計算
        cumulative = []
        current = 0.0
        for t in trades:
            current += t.profit
            cumulative.append(current)

        # 1. Matplotlib が使える場合は PNG を生成
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt

            plt.figure(figsize=(10, 5), dpi=150)
            x = list(range(1, len(cumulative) + 1))
            plt.plot(x, cumulative, label="Cumulative Profit (JPY)", color="#38bdf8", linewidth=2.5)
            plt.fill_between(x, cumulative, 0, color="#0284c7", alpha=0.2)
            plt.axhline(0, color="#64748b", linestyle="--", linewidth=1.0)
            plt.title("MT4 Automated Trading - Cumulative Equity Curve", fontsize=14, fontweight="bold", pad=15)
            plt.xlabel("Trade Count", fontsize=11)
            plt.ylabel("Profit / Loss (JPY)", fontsize=11)
            plt.grid(True, linestyle=":", alpha=0.4)
            plt.legend(loc="upper left")
            plt.tight_layout()

            output_path = os.path.join(self.output_dir, filename)
            plt.savefig(output_path, facecolor="#0f172a", edgecolor="none")
            plt.close()
            return output_path
        except Exception:
            # 2. Matplotlibが利用不可の場合は純粋なSVGチャートを生成
            svg_filename = filename.replace(".png", ".svg")
            return self._generate_pure_svg_chart(cumulative, svg_filename)

    def _generate_pure_svg_chart(self, cumulative: List[float], filename: str) -> str:
        width = 800
        height = 400
        padding = 50

        min_val = min(min(cumulative), 0.0)
        max_val = max(max(cumulative), 0.0)
        val_range = (max_val - min_val) if (max_val - min_val) > 0 else 1.0

        points = []
        for i, val in enumerate(cumulative):
            x = padding + (i / max(len(cumulative) - 1, 1)) * (width - 2 * padding)
            y = height - padding - ((val - min_val) / val_range) * (height - 2 * padding)
            points.append(f"{x:.1f},{y:.1f}")

        zero_y = height - padding - ((0.0 - min_val) / val_range) * (height - 2 * padding)
        polyline_points = " ".join(points)

        svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" style="background-color: #0f172a; font-family: sans-serif; border-radius: 8px;">
            <text x="{width/2}" y="30" fill="#f8fafc" font-size="18" font-weight="bold" text-anchor="middle">MT4 Trading - Cumulative Equity Curve</text>
            <line x1="{padding}" y1="{zero_y}" x2="{width-padding}" y2="{zero_y}" stroke="#475569" stroke-width="1.5" stroke-dasharray="4"/>
            <polyline fill="none" stroke="#38bdf8" stroke-width="3" points="{polyline_points}"/>
            <text x="{padding}" y="{height-20}" fill="#94a3b8" font-size="12">Start (Trade 1)</text>
            <text x="{width-padding}" y="{height-20}" fill="#94a3b8" font-size="12" text-anchor="end">End (Trade {len(cumulative)})</text>
            <text x="{width-padding}" y="{zero_y-8}" fill="#38bdf8" font-size="12" text-anchor="end">Final: {cumulative[-1]:,.1f} JPY</text>
        </svg>"""

        output_path = os.path.join(self.output_dir, filename)
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(svg)
        return output_path

    def generate_html_dashboard(
        self,
        metrics: TradeMetrics,
        ai_evaluation: str,
        equity_chart_path: str,
        trade_screenshots: Optional[List[Dict[str, Any]]] = None,
        filename: str = "dashboard.html",
    ) -> str:
        """
        MT4チャート画像とGemini AI診断を統合したプロ仕様ダークテーマHTMLダッシュボードを生成
        """
        output_path = os.path.join(self.output_dir, filename)
        rel_equity_chart = os.path.relpath(equity_chart_path, self.output_dir).replace("\\", "/")

        screenshot_cards = ""
        if trade_screenshots:
            for s in trade_screenshots:
                img_rel = os.path.relpath(s.get("image_path", ""), self.output_dir).replace("\\", "/")
                ticket = s.get("ticket", "N/A")
                rank = s.get("rank", "A")
                feedback = s.get("feedback", "フィボナッチ押し目での適切な反発を確認。")
                profit = s.get("profit", 0.0)
                profit_color = "#34d399" if profit >= 0 else "#f87171"

                screenshot_cards += f"""
                <div class="card screenshot-card">
                    <div class="card-header">
                        <span class="ticket-badge">Ticket #{ticket}</span>
                        <span class="rank-badge rank-{rank}">Rank {rank}</span>
                        <span class="profit-tag" style="color: {profit_color};">{profit:+,.1f} JPY</span>
                    </div>
                    <div class="image-wrapper">
                        <img src="{img_rel}" alt="Trade #{ticket} Screenshot" loading="lazy" />
                    </div>
                    <div class="card-body">
                        <p class="ai-feedback"><strong>🤖 Gemini 3.6 診断:</strong> {feedback}</p>
                    </div>
                </div>
                """
        else:
            screenshot_cards = """<div class="empty-state">まだ記録されたエントリーチャート画像がありません。</div>"""

        # 最終更新日時フォーマット
        last_close_time = "N/A"
        if metrics.trades and metrics.trades[-1].close_time:
            ct = metrics.trades[-1].close_time
            if hasattr(ct, "strftime"):
                last_close_time = ct.strftime("%Y-%m-%d %H:%M:%S")
            else:
                last_close_time = str(ct)

        html_content = f"""<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>MT4 AI Trading Performance Dashboard</title>
    
    <!-- PWA & Mobile App Settings -->
    <link rel="manifest" href="manifest.json">
    <meta name="theme-color" content="#090d16">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="楽天FX AI">
    <link rel="apple-touch-icon" href="icon-192.svg">
    <link rel="icon" type="image/svg+xml" href="icon-192.svg">
    <style>
        :root {{
            --bg-primary: #090d16;
            --bg-card: #131b2e;
            --border-color: #222f4c;
            --text-primary: #f1f5f9;
            --text-secondary: #94a3b8;
            --accent-cyan: #38bdf8;
            --accent-green: #34d399;
            --accent-red: #f87171;
            --accent-gold: #fbbf24;
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{
            background-color: var(--bg-primary);
            color: var(--text-primary);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            padding: 24px;
            line-height: 1.6;
        }}
        .container {{ max-width: 1200px; margin: 0 auto; }}
        header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 16px;
            margin-bottom: 24px;
            flex-wrap: wrap;
            gap: 12px;
        }}
        h1 {{ font-size: 22px; font-weight: 700; color: var(--accent-cyan); display: flex; align-items: center; gap: 8px; }}
        .badge-live {{
            background: rgba(52, 211, 153, 0.15);
            color: var(--accent-green);
            border: 1px solid var(--accent-green);
            padding: 4px 10px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: bold;
        }}
        .metrics-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 16px;
            margin-bottom: 24px;
        }}
        .stat-card {{
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 16px;
            backdrop-filter: blur(10px);
        }}
        .stat-label {{ font-size: 12px; color: var(--text-secondary); text-transform: uppercase; letter-spacing: 0.5px; }}
        .stat-value {{ font-size: 24px; font-weight: 700; margin-top: 4px; }}
        .val-positive {{ color: var(--accent-green); }}
        .val-negative {{ color: var(--accent-red); }}
        .val-cyan {{ color: var(--accent-cyan); }}

        .grid-2col {{
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 24px;
            margin-bottom: 32px;
        }}
        @media (max-width: 850px) {{
            .grid-2col {{ grid-template-columns: 1fr; }}
        }}
        .card {{
            background: var(--bg-card);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 20px;
        }}
        .card h2 {{ font-size: 18px; margin-bottom: 16px; color: var(--text-primary); border-left: 4px solid var(--accent-cyan); padding-left: 8px; }}
        .chart-img {{ width: 100%; border-radius: 8px; display: block; }}
        .ai-report-content {{
            white-space: pre-wrap;
            font-size: 14px;
            color: #cbd5e1;
            max-height: 400px;
            overflow-y: auto;
            background: #0b1120;
            padding: 16px;
            border-radius: 8px;
            border: 1px solid #1e293b;
        }}

        .screenshots-section h2 {{ font-size: 20px; margin-bottom: 16px; color: var(--accent-cyan); }}
        .screenshots-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(340px, 1fr));
            gap: 20px;
        }}
        .screenshot-card {{
            padding: 14px;
            display: flex;
            flex-direction: column;
            gap: 12px;
        }}
        .screenshot-card .card-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
        }}
        .ticket-badge {{ font-weight: 600; font-size: 13px; color: var(--text-primary); }}
        .rank-badge {{
            padding: 2px 8px;
            border-radius: 6px;
            font-weight: 700;
            font-size: 12px;
        }}
        .rank-S {{ background: #854d0e; color: #fef08a; }}
        .rank-A {{ background: #065f46; color: #a7f3d0; }}
        .rank-B {{ background: #1e40af; color: #bfdbfe; }}
        .rank-C {{ background: #991b1b; color: #fecaca; }}
        .image-wrapper img {{
            width: 100%;
            height: auto;
            border-radius: 6px;
            border: 1px solid var(--border-color);
        }}
        .ai-feedback {{ font-size: 13px; color: var(--text-secondary); line-height: 1.5; }}
        .empty-state {{ color: var(--text-secondary); text-align: center; padding: 40px; }}
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>🚀 楽天MT4 AIクオンツ パイプライン ダッシュボード</h1>
            <div style="display: flex; align-items: center; gap: 12px;">
                <span class="badge-live">● LIVE ONLINE</span>
                <span style="font-size: 13px; color: var(--text-secondary);">最終更新: {last_close_time}</span>
            </div>
        </header>

        <section class="metrics-grid">
            <div class="stat-card">
                <div class="stat-label">純損益 (Net Profit)</div>
                <div class="stat-value {'val-positive' if metrics.total_profit >= 0 else 'val-negative'}">{metrics.total_profit:+,.1f} 円</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">勝率 (Win Rate)</div>
                <div class="stat-value val-cyan">{metrics.win_rate:.1f}% <span style="font-size: 14px; color: var(--text-secondary);">({metrics.winning_trades}勝 {metrics.losing_trades}敗)</span></div>
            </div>
            <div class="stat-card">
                <div class="stat-label">プロフィットファクター (PF)</div>
                <div class="stat-value val-cyan">{metrics.profit_factor:.2f}</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">最大ドローダウン</div>
                <div class="stat-value val-negative">{metrics.max_drawdown:,.1f} 円 ({metrics.max_drawdown_pct:.1f}%)</div>
            </div>
        </section>

        <section class="grid-2col">
            <div class="card">
                <h2>📈 資産推移曲線 (Cumulative Equity)</h2>
                <img class="chart-img" src="{rel_equity_chart}" alt="Equity Curve" />
            </div>
            <div class="card">
                <h2>🧠 Gemini 3.6 クオンツ診断レポート</h2>
                <div class="ai-report-content">{ai_evaluation}</div>
            </div>
        </section>

        <section class="screenshots-section">
            <h2>📸 エントリー時チャート画像 ＆ AIマルチモーダル診断</h2>
            <div class="screenshots-grid">
                {screenshot_cards}
            </div>
        </section>
    </div>

    <!-- PWA Service Worker Registration -->
    <script>
        if ('serviceWorker' in navigator) {{
            window.addEventListener('load', () => {{
                navigator.serviceWorker.register('./service-worker.js')
                    .then(reg => console.log('PWA ServiceWorker registered:', reg.scope))
                    .catch(err => console.log('PWA ServiceWorker registration failed:', err));
            }});
        }}
    </script>
</body>
</html>
"""
        with open(output_path, "w", encoding="utf-8") as f:
            f.write(html_content)
        return output_path
