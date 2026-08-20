import os
import sys
import json
import shutil
import time
from typing import Dict, Any, Optional

try:
    from analyzer import TradeAnalyzer, TradeMetrics
    from ai_agent import TradeAiAgent
except ImportError:
    from evaluator.analyzer import TradeAnalyzer, TradeMetrics
    from evaluator.ai_agent import TradeAiAgent


class GeminiAutoTuner:
    """
    週次 Gemini 3.6 自律パラメータチューナー
    過去1週間のDuckDB/SQLite約定ログを分析し、来週の最適スイング期間・SL/TP倍率を自動生成して config.toml を更新。
    """

    def __init__(self, config_path: str = "config.toml", db_path: str = "trade_pipeline.db"):
        self.config_path = config_path
        self.db_path = db_path
        self.ai_agent = TradeAiAgent()

    def run_weekly_tuning(self) -> Dict[str, Any]:
        print(f"[AutoTuner] Starting weekly parameter tuning pipeline...")
        analyzer = TradeAnalyzer(db_path=self.db_path)
        metrics = analyzer.calculate_metrics()

        if not metrics:
            print("[AutoTuner] No trades found in database. Using default robust parameters.")
            return self._apply_fallback_tuning()

        print(f"[AutoTuner] Analyzing {metrics.total_trades} trades (WinRate: {metrics.win_rate:.1f}%, PF: {metrics.profit_factor:.2f})...")

        # Gemini 3.6 への構造化最適化プロンプト
        prompt = f"""
あなたは世界屈指の自律クオンツ・システムエンジニアです。
過去1週間のMT4自動売買（フィボナッチ×ダウ理論 極小損切り手法）の運用パフォーマンス指標を分析し、
次週の相場環境に最適化されたGatewayパラメータを厳密なJSON形式で出力してください。

【直近1週間のトレード実績】
- 総トレード数: {metrics.total_trades} 回
- 勝率: {metrics.win_rate:.2f}%
- 純損益: {metrics.total_profit:,.1f} 円
- プロフィットファクター (PF): {metrics.profit_factor:.2f}
- 最大ドローダウン: {metrics.max_drawdown:,.1f} 円
- 平均利益: {metrics.avg_trade_profit:,.1f} 円
- 最大勝ち: {metrics.largest_win:,.1f} 円 / 最大負け: {metrics.largest_loss:,.1f} 円

【チューニング対象パラメータと推奨範囲】
- short_period: 3 〜 10 (短期移動平均)
- long_period: 15 〜 30 (長期移動平均)
- fib_swing_period: 30 〜 80 (フィボナッチスイング高安値ルックバック)
- dow_lookback: 4 〜 12 (下位足ダウ戻り高値ブレイクルックバック)
- rsi_overbought: 65.0 〜 75.0
- rsi_oversold: 25.0 〜 35.0
- micro_sl_min_pips: 3.0 〜 6.0 (極小損切り下限)
- target_risk_per_trade_jpy: 1000.0 〜 5000.0

【出力要件】
以下のJSONフォーマットのみを出力してください（Markdownコードブロックや余計な解説文は不要です）：
{{
    "short_period": 5,
    "long_period": 20,
    "fib_swing_period": 50,
    "dow_lookback": 6,
    "rsi_overbought": 70.0,
    "rsi_oversold": 30.0,
    "micro_sl_min_pips": 4.0,
    "target_risk_per_trade_jpy": 2000.0,
    "tuning_rationale": "最適化理由を日本語で簡潔に記載"
}}
"""

        tuned_params = None
        if self.ai_agent.client:
            for model_name in ["gemini-3.6-flash", "gemini-3.6-pro", "gemini-2.5-flash"]:
                try:
                    response = self.ai_agent.client.models.generate_content(
                        model=model_name,
                        contents=prompt,
                    )
                    if response and response.text:
                        raw_text = response.text.strip()
                        if "```json" in raw_text:
                            raw_text = raw_text.split("```json")[1].split("```")[0].strip()
                        elif "```" in raw_text:
                            raw_text = raw_text.split("```")[1].split("```")[0].strip()
                        tuned_params = json.loads(raw_text)
                        print(f"[AutoTuner] Successfully received tuned parameters from {model_name}!")
                        break
                except Exception as e:
                    print(f"[AutoTuner] Model {model_name} tuning failed: {e}")
                    continue

        if not tuned_params:
            print("[AutoTuner] Falling back to rule-based quant parameter adjustment.")
            tuned_params = self._apply_fallback_tuning(metrics)

        # config.toml の更新
        self._update_config_file(tuned_params)
        return tuned_params

    def _apply_fallback_tuning(self, metrics: Optional[TradeMetrics] = None) -> Dict[str, Any]:
        """ルールベースのクオンツフォールバック調整"""
        if metrics and metrics.profit_factor < 1.0:
            # 成績不振時はフィルターを厳格化
            return {
                "short_period": 6,
                "long_period": 24,
                "fib_swing_period": 60,
                "dow_lookback": 8,
                "rsi_overbought": 68.0,
                "rsi_oversold": 32.0,
                "micro_sl_min_pips": 4.5,
                "target_risk_per_trade_jpy": 1500.0,
                "tuning_rationale": "前週PF低迷のため、ダウ転換ルックバックを8本へ拡大しダマシを厳格排除。リスク額を1,500円へ縮小。",
            }
        else:
            # 好調時またはデフォルト
            return {
                "short_period": 5,
                "long_period": 20,
                "fib_swing_period": 50,
                "dow_lookback": 6,
                "rsi_overbought": 70.0,
                "rsi_oversold": 30.0,
                "micro_sl_min_pips": 4.0,
                "target_risk_per_trade_jpy": 2000.0,
                "tuning_rationale": "順調なパフォーマンスを維持。標準フィボナッチ・ダウパラメータを継続適用。",
            }

    def _update_config_file(self, params: Dict[str, Any]) -> None:
        """config.toml を安全にバックアップしてから書き換え"""
        if os.path.exists(self.config_path):
            backup_path = f"{self.config_path}.bak.{int(time.time())}"
            shutil.copy(self.config_path, backup_path)
            print(f"[AutoTuner] Backed up current config to {backup_path}")

        new_config_content = f"""# 🚀 MT4 Trading Pipeline & Rust Gateway 設定ファイル
# 週次 Gemini 3.6 自律クオンツチューナーにより自動最適化されました。
# 更新日時: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}
# 最適化理由: {params.get('tuning_rationale', 'N/A')}

[strategy]
short_period = {int(params.get('short_period', 5))}
long_period = {int(params.get('long_period', 20))}
rsi_period = 14
atr_period = 14
fib_swing_period = {int(params.get('fib_swing_period', 50))}
dow_lookback = {int(params.get('dow_lookback', 6))}
rsi_overbought = {float(params.get('rsi_overbought', 70.0))}
rsi_oversold = {float(params.get('rsi_oversold', 30.0))}
target_risk_per_trade_jpy = {float(params.get('target_risk_per_trade_jpy', 2000.0))}
min_signal_interval_sec = 15
micro_sl_min_pips = {float(params.get('micro_sl_min_pips', 4.0))}
max_lot_limit = 1.00

[ai_kill_switch]
enabled = true
ipc_server_addr = "127.0.0.1:5556"
loss_similarity_threshold = 85.0
win_confidence_threshold = 80.0

[gateway]
bind_addr = "127.0.0.1:5555"
db_path = "trade_pipeline.db"
"""
        with open(self.config_path, "w", encoding="utf-8") as f:
            f.write(new_config_content)
        print(f"✅ [AutoTuner] Successfully updated {self.config_path} with new optimized parameters!")


if __name__ == "__main__":
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass

    tuner = GeminiAutoTuner()
    res = tuner.run_weekly_tuning()
    print("\n[Result] Tuning Applied:", json.dumps(res, ensure_ascii=False, indent=2))
