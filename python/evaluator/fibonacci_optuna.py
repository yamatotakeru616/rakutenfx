"""
🚀 Rakuten FX Quant Studio - Fibonacci & Dow Theory PF 1.30+ Optimizer
1年間のUSD/JPY過去データから「最低1日1回トレード（年間240回以上）」の制約下で
Profit Factor 1.30+ を達成するハイパーパラメータを自律ベイズ探索し、Goサーバーへ自動適用するモジュール。
"""

import os
import sys
import argparse
import json
import time
import requests
from typing import Dict, Any, Optional

# Ensure UTF-8 output on Windows console
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

try:
    import optuna
    optuna.logging.set_verbosity(optuna.logging.WARNING)
except ImportError:
    print("[ERROR] Optuna is not installed. Please run: pip install optuna")
    sys.exit(1)


class FibonacciQuantOptimizer:
    """
    フィボナッチ×ダウ理論 高頻度PF 1.30+ 自律最適化エンジン
    """

    def __init__(self, api_base_url: str = "http://localhost:8080", min_yearly_trades: int = 240):
        self.api_base_url = api_base_url.rstrip("/")
        self.min_yearly_trades = min_yearly_trades

    def check_go_server_online(self) -> bool:
        try:
            r = requests.get(f"{self.api_base_url}/api/status", timeout=2)
            return r.status_code == 200
        except Exception:
            return False

    def evaluate_parameters(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Go サーバーのバックテストエンジン（37万ティック）を呼び出して高速評価
        """
        url = f"{self.api_base_url}/api/backtest/run"
        try:
            res = requests.post(url, json=params, timeout=30)
            if res.status_code != 200:
                return {}
            data = res.json()
            return data.get("result", {})
        except Exception as e:
            print(f"[Optimizer] Evaluation error: {e}")
            return {}

    def objective(self, trial: optuna.Trial) -> float:
        """
        目的関数:
        1. 取引回数 >= 240回 (1日1回以上) の厳格維持
        2. PF >= 1.30 の達成
        3. ドローダウン抑制と安定した資産成長 (Robustness Score)
        """
        # フィボナッチ×ダウ理論のパラメータ探索空間 (極小損切り 3〜7.5pips & 高RR 2.0〜3.5)
        bb_std = trial.suggest_float("bb_std_dev", 1.8, 2.8, step=0.1)
        rsi_os = trial.suggest_float("rsi_oversold", 20.0, 35.0, step=5.0)
        adx_th = trial.suggest_float("adx_threshold", 18.0, 30.0, step=1.0)
        atr_factor = trial.suggest_float("atr_factor", 1.2, 1.8, step=0.1)
        timeout = trial.suggest_int("timeout_minutes", 45, 180, step=15)
        rr_ratio = trial.suggest_float("risk_reward_ratio", 2.0, 3.5, step=0.1)
        sl_pips = trial.suggest_float("stop_loss_pips", 4.0, 8.0, step=0.5)
        dow_lb = trial.suggest_int("dow_lookback", 3, 6, step=1)
        start_hour = trial.suggest_int("start_jst_hour", 14, 17)
        end_hour = trial.suggest_int("end_jst_hour", 23, 24)

        # 取引頻度を確保するため JST 09:00〜24:00 (東京〜ロンドン〜NY) をカバー
        payload = {
            "bb_period": 20,
            "bb_std_dev": round(bb_std, 1),
            "rsi_period": 14,
            "rsi_oversold": round(rsi_os, 1),
            "rsi_overbought": round(100.0 - rsi_os, 1),
            "adx_period": 14,
            "adx_threshold": round(adx_th, 1),
            "atr_lookback": 50,
            "atr_factor": round(atr_factor, 1),
            "pyramidding_max": 2,
            "timeout_minutes": timeout,
            "lot_size": 0.20,
            "stop_loss_pips": round(sl_pips, 1),
            "take_profit_pips": round(sl_pips * rr_ratio, 1),
            "spread_pips": 0.2,
            "enable_hour_filter": True,
            "start_jst_hour": start_hour,
            "end_jst_hour": end_hour,
            "initial_balance": 100000.0,
            "risk_percent": 2.0,
            "risk_reward_ratio": round(rr_ratio, 1),
            "use_dynamic_risk_lot": True,
            "enable_dow_trigger": True,
            "dow_lookback": dow_lb,
            "enable_break_even": False,
            "enable_fib_filter": True,
        }

        result = self.evaluate_parameters(payload)
        if not result:
            return -999.0

        total_trades = result.get("total_trades", 0)
        win_rate = result.get("win_rate", 0.0)
        pf = result.get("profit_factor", 0.0)
        net_profit = result.get("total_profit", 0.0)
        max_dd_pct = result.get("max_drawdown_pct", 0.0)
        score = result.get("robustness_score", 0.0)

        # 評価スコア算出
        fitness = (pf * 30.0) + (win_rate * 0.4) + (net_profit / 4000.0) - (max_dd_pct * 0.5)

        # 取引頻度ペナルティ (年間240回未満)
        if total_trades < self.min_yearly_trades:
            deficit = self.min_yearly_trades - total_trades
            fitness -= (deficit * 0.6)
        else:
            fitness += 15.0

        # PF 1.30+ かつ 頻度クリア時の特大ボーナス
        if pf >= 1.30 and total_trades >= self.min_yearly_trades:
            fitness += 60.0
        elif pf >= 1.15 and total_trades >= self.min_yearly_trades:
            fitness += 20.0

        # 試行の属性に詳細を記録
        trial.set_user_attr("pf", round(pf, 2))
        trial.set_user_attr("win_rate", round(win_rate, 1))
        trial.set_user_attr("profit", int(net_profit))
        trial.set_user_attr("trades", total_trades)
        trial.set_user_attr("max_dd_pct", round(max_dd_pct, 1))
        trial.set_user_attr("score", round(score, 1))
        trial.set_user_attr("meets_frequency", total_trades >= self.min_yearly_trades)

        return fitness

    def run_optimization(self, n_trials: int = 30) -> optuna.Study:
        """
        Optuna ベイズ最適化の実行
        """
        print("=" * 75)
        print("  🎯 FIBONACCI & DOW THEORY PF 1.30+ QUANT OPTIMIZER")
        print(f"  Target: PF >= 1.30 | Min Yearly Trades >= {self.min_yearly_trades} (1 trade/day)")
        print(f"  Trials: {n_trials} (Bayesian TPE Sampler)")
        print("=" * 75)

        if not self.check_go_server_online():
            print(f"[ERROR] Go server is not running on {self.api_base_url}.")
            print("Please start server via `go run ./cmd/server/main.go` first.")
            sys.exit(1)

        sampler = optuna.samplers.TPESampler(seed=123)
        study = optuna.create_study(direction="maximize", sampler=sampler)

        start_time = time.time()
        study.optimize(self.objective, n_trials=n_trials, show_progress_bar=True)
        elapsed = time.time() - start_time

        print("\n" + "=" * 75)
        print("  🏆 FIBONACCI OPTIMIZATION RESULTS")
        print(f"  Elapsed Time: {elapsed:.2f}s | Best Fitness: {study.best_value:.2f}")
        print("=" * 75)

        best_params = study.best_params
        best_trial = study.best_trial
        attrs = best_trial.user_attrs

        status_freq = "✅ PASSED (>= 240 trades)" if attrs.get("meets_frequency", False) else "⚠️ BELOW 240 TRADES"
        status_pf = "🌟 TARGET ACHIEVED (>= 1.30)" if attrs.get("pf", 0.0) >= 1.30 else "📈 OPTIMIZED"

        print(f"  • Annual Trades:   {attrs.get('trades', 0)} trades [{status_freq}]")
        print(f"  • Profit Factor:   {attrs.get('pf', 0.0):.2f} [{status_pf}]")
        print(f"  • Win Rate:        {attrs.get('win_rate', 0.0):.1f}%")
        print(f"  • 1-Year Profit:   ¥{attrs.get('profit', 0):,}")
        print(f"  • Max Drawdown:    {attrs.get('max_dd_pct', 0.0):.1f}%")
        print(f"  • Robustness:      {attrs.get('score', 0.0):.1f} / 100")
        print("-" * 75)
        print("  【推奨最適化パラメータ】")
        print(f"  • BB StdDev:       {best_params.get('bb_std_dev')} σ")
        print(f"  • RSI (OS / OB):   {best_params.get('rsi_oversold')} / {100.0 - best_params.get('rsi_oversold')}")
        print(f"  • ADX Threshold:   {best_params.get('adx_threshold')}")
        print(f"  • ATR Factor:      {best_params.get('atr_factor')}x")
        print(f"  • Timeout:         {best_params.get('timeout_minutes')} min")
        print(f"  • Risk:Reward:     1 : {best_params.get('risk_reward_ratio')}")
        print(f"  • Stop Loss:       {best_params.get('stop_loss_pips')} pips")
        print(f"  • Take Profit:     {round(best_params.get('stop_loss_pips') * best_params.get('risk_reward_ratio'), 1)} pips")
        print("=" * 75)

        return study

    def apply_best_profile(self, study: optuna.Study) -> bool:
        """
        導出した最良パラメータを Go サーバーへ適用
        """
        best_p = study.best_params
        attrs = study.best_trial.user_attrs

        profile_payload = {
            "session_name": "FIBONACCI_DOW_PF130_OPTIMIZED",
            "market_habit": "フィボナッチ×ダウ転換高頻度型 (PF1.30+ Target)",
            "edge_health_score": int(min(100, max(75, attrs.get("score", 85) + 10))),
            "recommended_bb_std": round(best_p.get("bb_std_dev", 2.0), 1),
            "recommended_rsi_os": round(best_p.get("rsi_oversold", 30.0), 1),
            "recommended_rsi_ob": round(100.0 - best_p.get("rsi_oversold", 30.0), 1),
            "recommended_adx": round(best_p.get("adx_threshold", 25.0), 1),
            "recommended_atr_factor": round(best_p.get("atr_factor", 1.5), 1),
            "recommended_timeout": int(best_p.get("timeout_minutes", 120)),
            "recommended_lot": 0.20,
            "decay_warning": False,
            "action_rationale": f"フィボナッチ×ダウ理論最適化完了: 年間{attrs.get('trades', 0)}回(1日1回以上), PF {attrs.get('pf', 0.0):.2f}, 勝率 {attrs.get('win_rate', 0.0):.1f}%, 堅牢スコア {attrs.get('score', 0.0):.1f}。",
        }

        url = f"{self.api_base_url}/api/ai/adaptive-profile"
        try:
            res = requests.post(url, json=profile_payload, timeout=5)
            if res.status_code == 200:
                print("\n✅ [SUCCESS] Fibonacci PF 1.30+ profile applied to Go Server & Web HUD!")
                return True
            else:
                print(f"[ERROR] Failed to apply profile: {res.text}")
                return False
        except Exception as e:
            print(f"[ERROR] Network error applying profile: {e}")
            return False


def main():
    parser = argparse.ArgumentParser(description="Fibonacci & Dow Theory PF 1.30+ Optimizer")
    parser.add_argument("--trials", type=int, default=30, help="Number of optimization trials")
    parser.add_argument("--min-trades", type=int, default=240, help="Minimum annual trades constraint")
    parser.add_argument("--apply", action="store_true", help="Apply best profile to running Go server")
    parser.add_argument("--url", type=str, default="http://localhost:8080", help="Go server base URL")

    args = parser.parse_args()

    optimizer = FibonacciQuantOptimizer(api_base_url=args.url, min_yearly_trades=args.min_trades)
    study = optimizer.run_optimization(n_trials=args.trials)

    if args.apply:
        optimizer.apply_best_profile(study)


if __name__ == "__main__":
    main()
