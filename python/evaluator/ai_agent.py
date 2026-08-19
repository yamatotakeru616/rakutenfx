import os
from typing import Optional

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


class TradeAiAgent:
    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key or os.environ.get("GEMINI_API_KEY")
        self.client = None

        if self.api_key:
            try:
                from google import genai
                self.client = genai.Client(api_key=self.api_key)
            except Exception as e:
                print(f"[Warning] Failed to initialize Google GenAI Client: {e}")

    def evaluate_performance(self, metrics: TradeMetrics) -> str:
        prompt = f"""
あなたはプロのFXクオンツ・トレーダー兼AIリスクアナリストです。
以下のMT4自動売買（デモ口座）の運用パフォーマンス指標を詳細に診断・評価し、改善提案を作成してください。

【トレード統計】
- 総トレード数: {metrics.total_trades} 回
- 勝率: {metrics.win_rate:.2f}% ({metrics.winning_trades}勝 {metrics.losing_trades}敗)
- 純損益 (Total Profit): {metrics.total_profit:,.1f} 円
- 総利益 (Gross Profit): {metrics.gross_profit:,.1f} 円
- 総損失 (Gross Loss): {metrics.gross_loss:,.1f} 円
- プロフィットファクター (PF): {metrics.profit_factor:.2f}
- 最大ドローダウン (Max Drawdown): {metrics.max_drawdown:,.1f} 円 ({metrics.max_drawdown_pct:.2f}%)
- 1回あたり平均損益: {metrics.avg_trade_profit:,.1f} 円
- 最大勝ちトレード: {metrics.largest_win:,.1f} 円
- 最大負けトレード: {metrics.largest_loss:,.1f} 円

【出力フォーマット】
以下の項目を明確かつ具体的に出力してください：
1. **総合評価スコア (100点満点)** と 簡易サマリー
2. **強み・好調要因の分析**
3. **リスク要因・ボトルネックの特定** (ドローダウン、勝率、損益比の観点)
4. **次期パラメータチューニング・改善提案 (3点)**
"""

        if self.client:
            for model_name in ["gemini-3.6-flash", "gemini-3.6-pro", "gemini-2.5-flash"]:
                try:
                    response = self.client.models.generate_content(
                        model=model_name,
                        contents=prompt,
                    )
                    if response and response.text:
                        return response.text
                except Exception as e:
                    # エラー理由を表示
                    print(f"[Debug] Model {model_name} failed: {e}")
                    continue

            print("[Warning] Gemini API call failed on all models. Falling back to rule-based evaluation.")

        # APIキーがない場合のフォールバック診断
        return self._generate_fallback_evaluation(metrics)

    def _generate_fallback_evaluation(self, metrics: TradeMetrics) -> str:
        score = 70
        if metrics.profit_factor >= 1.5:
            score += 15
        elif metrics.profit_factor < 1.0:
            score -= 20

        if metrics.win_rate >= 55.0:
            score += 10
        elif metrics.win_rate < 40.0:
            score -= 10

        return f"""### 📊 AI トレード診断レポート (ローカルルールエンジン)

**総合評価スコア**: **{score}点 / 100点**

#### 1. パフォーマンスサマリー
- トレード総数 **{metrics.total_trades}回** 中、純損益は **{metrics.total_profit:,.1f} 円**、勝率 **{metrics.win_rate:.1f}%** を記録。
- プロフィットファクター (PF) は **{metrics.profit_factor:.2f}** となっており、{'健全な収益性' if metrics.profit_factor >= 1.2 else '改善が必要な水準'}です。

#### 2. 強みと改善点
- **最大利益**: +{metrics.largest_win:,.1f} 円 / **最大損失**: {metrics.largest_loss:,.1f} 円
- 最大ドローダウンは **{metrics.max_drawdown:,.1f} 円** に抑えられています。

#### 3. 推奨アクション3選
1. **利益確定（TP）と損切り（SL）の比率最適化**: リスクリワード比率（現在SL 20pips / TP 40pips）のボラティリティ追従化。
2. **RSIフィルター閾値の微調整**: レンジ相場でのダマシ回避のため、RSIの上限・下限フィルターを厳格化。
3. **時間帯フィルターの追加**: 経済指標発表時やロンドン・NYオープン前後の急激なスプレッド拡大を回避するガードロジックの導入。
"""
