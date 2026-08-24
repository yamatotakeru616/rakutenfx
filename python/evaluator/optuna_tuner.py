"""
🚀 Rakuten FX Quant Studio - Optuna Bayesian Hyperparameter Tuner
Go native single-binary engine と連携し、ベイズ最適化（TPE Sampler）で最良パラメータを自律探索＆Goサーバーへ即時反映するハイブリッドモジュール。
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


class OptunaQuantTuner:
    """
    Optuna ベイズ最適化クオンツチューナー
    """

    def __init__(self, api_base_url: str = "http://localhost:8080"):
        self.api_base_url = api_base_url.rstrip("/")

    def check_go_server_online(self) -> bool:
        try:
            r = requests.get(f"{self.api_base_url}/api/status", timeout=2)
            return r.status_code == 200
        except Exception:
            return False

    def evaluate_parameters(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Go サーバーのバックテストAPIを呼び出し、1年間のパフォーマンスを取得
        """
        url = f"{self.api_base_url}/api/backtest/run"
        try:
            res = requests.post(url, json=params, timeout=30)
            if res.status_code != 200:
                return {}
            data = res.json()
            return data.get("result", {})
        except Exception as e:
            print(f"[Optuna] Evaluation error: {e}")
            return {}

    def objective(self, trial: optuna.Trial) -> float:
        """
        Optuna 試行目的関数: 堅牢性スコア（Robustness Score）の最大化
        """
        # 1. 探索空間のサンプリング
        bb_std = trial.suggest_float("bb_std_dev", 1.8, 2.8, step=0.1)
        rsi_os = trial.suggest_float("rsi_oversold", 20.0, 35.0, step=5.0)
        adx_th = trial.suggest_float("adx_threshold", 18.0, 30.0, step=1.0)
        atr_factor = trial.suggest_float("atr_factor", 1.2, 2.0, step=0.1)
        timeout = trial.suggest_int("timeout_minutes", 45, 180, step=15)
        rr_ratio = trial.suggest_float("risk_reward_ratio", 1.5, 2.5, step=0.1)
        sl_pips = trial.suggest_float("stop_loss_pips", 8.0, 15.0, step=1.0)

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
            "start_jst_hour": 16,
            "end_jst_hour": 24,
            "initial_balance": 100000.0,
            "risk_percent": 2.0,
            "risk_reward_ratio": round(rr_ratio, 1),
            "use_dynamic_risk_lot": True,
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

        # 最低取引回数フィルター (過剰適合ペナルティ)
        if total_trades < 25:
            return -100.0 + total_trades

        # 堅牢性スコアを主指標とし、PF 1.30以上および低DDにボーナス
        fitness = score
        if pf >= 1.30:
            fitness += 20.0
        if max_dd_pct > 0:
            fitness -= (max_dd_pct * 0.5)

        # 試行の属性に詳細を記録
        trial.set_user_attr("pf", round(pf, 2))
        trial.set_user_attr("win_rate", round(win_rate, 1))
        trial.set_user_attr("profit", int(net_profit))
        trial.set_user_attr("trades", total_trades)
        trial.set_user_attr("max_dd_pct", round(max_dd_pct, 1))
        trial.set_user_attr("score", round(score, 1))

        return fitness

    def run_study(self, n_trials: int = 25) -> optuna.Study:
        """
        Optuna 最適化スタディを実行
        """
        print("=" * 70)
        print("  🧠 RAKUTEN FX - OPTUNA BAYESIAN PARAMETER OPTIMIZER")
        print(f"  Target: Maximize Robustness Score & Profit Factor (Trials: {n_trials})")
        print("=" * 70)

        if not self.check_go_server_online():
            print(f"[ERROR] Go server is not running on {self.api_base_url}.")
            print("Please run `go run ./cmd/server/main.go` first.")
            sys.exit(1)

        sampler = optuna.samplers.TPESampler(seed=42)
        study = optuna.create_study(direction="maximize", sampler=sampler)

        start_time = time.time()
        study.optimize(self.objective, n_trials=n_trials, show_progress_bar=True)
        elapsed = time.time() - start_time

        print("\n" + "=" * 70)
        print("  🏆 OPTIMIZATION FINISHED")
        print(f"  Elapsed Time: {elapsed:.2f}s | Best Fitness: {study.best_value:.2f}")
        print("=" * 70)

        best_params = study.best_params
        best_trial = study.best_trial
        attrs = best_trial.user_attrs

        print(f"  • Profit Factor:   {attrs.get('pf', 0.0):.2f}")
        print(f"  • Win Rate:        {attrs.get('win_rate', 0.0):.1f}%")
        print(f"  • Net Profit:      ¥{attrs.get('profit', 0):,}")
        print(f"  • Total Trades:    {attrs.get('trades', 0)} trades")
        print(f"  • Max Drawdown:    {attrs.get('max_dd_pct', 0.0):.1f}%")
        print(f"  • Robustness:      {attrs.get('score', 0.0):.1f} / 100")
        print("-" * 70)
        print(f"  • BB StdDev:       {best_params.get('bb_std_dev')} σ")
        print(f"  • RSI (OS / OB):   {best_params.get('rsi_oversold')} / {100.0 - best_params.get('rsi_oversold')}")
        print(f"  • ADX Threshold:   {best_params.get('adx_threshold')}")
        print(f"  • ATR Factor:      {best_params.get('atr_factor')}x")
        print(f"  • Timeout:         {best_params.get('timeout_minutes')} min")
        print(f"  • Risk:Reward:     1 : {best_params.get('risk_reward_ratio')}")
        print(f"  • Stop Loss:       {best_params.get('stop_loss_pips')} pips")
        print("=" * 70)

        return study

    def apply_best_profile_to_go_server(self, study: optuna.Study) -> bool:
        """
        導出した最良パラメータを Go サーバーへ即座に反映 (POST /api/ai/adaptive-profile)
        """
        best_p = study.best_params
        attrs = study.best_trial.user_attrs

        profile_payload = {
            "session_name": "OPTUNA_BAYESIAN_OPTIMIZED",
            "market_habit": "ベイズ最適平均回帰 (Optuna Quant Tuning)",
            "edge_health_score": int(min(100, max(60, attrs.get("score", 85) + 15))),
            "recommended_bb_std": round(best_p.get("bb_std_dev", 2.0), 1),
            "recommended_rsi_os": round(best_p.get("rsi_oversold", 30.0), 1),
            "recommended_rsi_ob": round(100.0 - best_p.get("rsi_oversold", 30.0), 1),
            "recommended_adx": round(best_p.get("adx_threshold", 25.0), 1),
            "recommended_atr_factor": round(best_p.get("atr_factor", 1.5), 1),
            "recommended_timeout": int(best_p.get("timeout_minutes", 120)),
            "recommended_lot": 0.20,
            "decay_warning": False,
            "action_rationale": f"Optuna TPEベイズ最適化完了: PF {attrs.get('pf', 0.0):.2f}, 勝率 {attrs.get('win_rate', 0.0):.1f}%, 堅牢スコア {attrs.get('score', 0.0):.1f}。市場の直近構造に完全同調。",
        }

        url = f"{self.api_base_url}/api/ai/adaptive-profile"
        try:
            res = requests.post(url, json=profile_payload, timeout=5)
            if res.status_code == 200:
                print("\n✅ [SUCCESS] Best parameters successfully applied to Go Server & Web HUD via WebSocket!")
                return True
            else:
                print(f"[ERROR] Failed to apply profile to Go server: {res.text}")
                return False
        except Exception as e:
            print(f"[ERROR] Network error applying profile: {e}")
            return False


def main():
    parser = argparse.ArgumentParser(description="Rakuten FX Optuna Quant Tuner")
    parser.add_argument("--trials", type=int, default=20, help="Number of Optuna optimization trials")
    parser.add_argument("--apply", action="store_true", help="Automatically apply best profile to running Go server")
    parser.add_argument("--url", type=str, default="http://localhost:8080", help="Go server base URL")

    args = parser.parse_args()

    tuner = OptunaQuantTuner(api_base_url=args.url)
    study = tuner.run_study(n_trials=args.trials)

    if args.apply:
        tuner.apply_best_profile_to_go_server(study)


if __name__ == "__main__":
    main()
