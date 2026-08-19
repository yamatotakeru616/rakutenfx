import os
from typing import List, Optional
from analyzer import TradeRecord


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
            plt.plot(x, cumulative, label="Cumulative Profit (JPY)", color="#2563eb", linewidth=2.0)
            plt.fill_between(x, cumulative, 0, color="#3b82f6", alpha=0.15)
            plt.axhline(0, color="#94a3b8", linestyle="--", linewidth=1.0)
            plt.title("MT4 Automated Trading - Cumulative Equity Curve", fontsize=14, fontweight="bold", pad=15)
            plt.xlabel("Trade Count", fontsize=11)
            plt.ylabel("Profit / Loss (JPY)", fontsize=11)
            plt.legend(loc="upper left")
            plt.tight_layout()

            output_path = os.path.join(self.output_dir, filename)
            plt.savefig(output_path)
            plt.close()
            return output_path
        except Exception as e:
            # 2. Matplotlibがブロックされる場合は純粋なSVGチャートを生成
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

        svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" style="background-color: #0f172a; font-family: sans-serif;">
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
