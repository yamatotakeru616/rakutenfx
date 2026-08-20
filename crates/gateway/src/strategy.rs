use std::collections::HashMap;
use chrono::{DateTime, Utc};
use tracing::{info, warn};

use crate::bar_generator::{BarGenerator, DowBreakout, Timeframe};
use crate::indicators::TechnicalIndicators;
use crate::models::{Signal, SignalAction, Tick};

#[derive(Debug, Clone)]
pub struct StrategyConfig {
    pub short_period: usize,
    pub long_period: usize,
    pub rsi_period: usize,
    pub atr_period: usize,
    pub fib_swing_period: usize,        // フィボナッチスイング高安値判定期間
    pub dow_lookback: usize,            // 下位足ダウ転換判定ルックバック本数
    pub rsi_overbought: f64,
    pub rsi_oversold: f64,
    pub target_risk_per_trade_jpy: f64, // 1トレードの許容最大損失額 (円)
    pub min_signal_interval_sec: i64,
    pub micro_sl_min_pips: f64,         // 極小損切り下限 (pips)
    pub max_lot_limit: f64,             // 最大許容ロット
}

impl Default for StrategyConfig {
    fn default() -> Self {
        Self {
            short_period: 5,
            long_period: 20,
            rsi_period: 14,
            atr_period: 14,
            fib_swing_period: 50,
            dow_lookback: 6,
            rsi_overbought: 70.0,
            rsi_oversold: 30.0,
            target_risk_per_trade_jpy: 2000.0, // 2,000円固定リスク
            min_signal_interval_sec: 15,
            micro_sl_min_pips: 4.0,            // 極小SL 4.0 pips
            max_lot_limit: 1.00,               // 1.00 Lotまで許容
        }
    }
}

pub struct SignalEngine {
    config: StrategyConfig,
    indicators: HashMap<String, TechnicalIndicators>,
    bar_generators: HashMap<String, BarGenerator>,
    last_signal_time: HashMap<String, DateTime<Utc>>,
    last_sma_diff: HashMap<String, f64>,
}

impl SignalEngine {
    pub fn new(config: StrategyConfig) -> Self {
        Self {
            config,
            indicators: HashMap::new(),
            bar_generators: HashMap::new(),
            last_signal_time: HashMap::new(),
            last_sma_diff: HashMap::new(),
        }
    }

    /// 通貨ペアごとの 1 pip の価格単位と最大許容スプレッド (pips) を取得
    fn get_symbol_profile(&self, symbol: &str) -> (f64, f64, f64) {
        // (pip_unit, max_allowed_spread_pips, pip_value_per_lot_jpy)
        let upper = symbol.to_uppercase();
        if upper.contains("JPY") {
            (0.01, 3.0, 1000.0) // 1ロット(10万通貨)で 1pip = 1,000円
        } else if upper.contains("XAU") || upper.contains("GOLD") {
            (0.1, 70.0, 1500.0) // ゴールド
        } else {
            (0.0001, 2.5, 15000.0 * 0.0001 * 100000.0) // ドルストレート (EURUSD等: 1pip ≈ 1500円)
        }
    }

    pub fn process_tick(&mut self, tick: &Tick) -> Option<Signal> {
        let (pip_unit, max_spread_pips, pip_value_jpy) = self.get_symbol_profile(&tick.symbol);

        // 1. スプレッド拡大ガード (Max Spread Filter)
        let raw_spread = tick.ask - tick.bid;
        let current_spread_pips = raw_spread / pip_unit;

        if current_spread_pips > max_spread_pips {
            warn!(
                "🛡️ Spread too wide for {}: {:.1} pips (Max allowed: {:.1} pips). Skipping signal.",
                tick.symbol, current_spread_pips, max_spread_pips
            );
            return None;
        }

        let mid_price = (tick.bid + tick.ask) / 2.0;

        // 1. 下位足 (M1) バーのリアルタイム合成とダウ転換判定
        let bar_gen = self
            .bar_generators
            .entry(tick.symbol.clone())
            .or_insert_with(|| BarGenerator::new(Timeframe::M1, 100));

        let closed_bar_opt = bar_gen.on_tick(mid_price, tick.volume, tick.time);
        let dow_breakout = if closed_bar_opt.is_some() {
            bar_gen.check_dow_breakout(self.config.dow_lookback)
        } else {
            DowBreakout::None
        };

        let ind = self
            .indicators
            .entry(tick.symbol.clone())
            .or_insert_with(|| TechnicalIndicators::new(self.config.fib_swing_period.max(self.config.long_period) + 50));

        ind.add_price(mid_price);

        let short_sma = ind.sma(self.config.short_period)?;
        let long_sma = ind.sma(self.config.long_period)?;
        let rsi = ind.rsi(self.config.rsi_period).unwrap_or(50.0);
        let atr = ind.atr(self.config.atr_period).unwrap_or(pip_unit * 15.0);
        let fib_opt = ind.fibonacci_retracement_up(self.config.fib_swing_period);

        let current_diff = short_sma - long_sma;
        let prev_diff = *self.last_sma_diff.get(&tick.symbol).unwrap_or(&current_diff);
        self.last_sma_diff.insert(tick.symbol.clone(), current_diff);

        // クールダウン期間の確認
        if let Some(last_time) = self.last_signal_time.get(&tick.symbol) {
            let elapsed = tick.time.signed_duration_since(*last_time).num_seconds();
            if elapsed < self.config.min_signal_interval_sec {
                return None;
            }
        }

        // 2. フィボナッチ ＆ 動的極小SL/TP ＆ ポジションサイジング計算
        let raw_atr_pips = atr / pip_unit;
        
        // ダウ理論転換時の直近安値/高値に基づく精密極小SL
        let (calculated_sl_pips, is_dow_triggered) = match dow_breakout {
            DowBreakout::BullishBreakout { recent_swing_low, .. } => {
                let sl_dist_pips = ((mid_price - recent_swing_low) / pip_unit).max(self.config.micro_sl_min_pips);
                (sl_dist_pips.clamp(self.config.micro_sl_min_pips, 50.0).round(), true)
            }
            DowBreakout::BearishBreakout { recent_swing_high, .. } => {
                let sl_dist_pips = ((recent_swing_high - mid_price) / pip_unit).max(self.config.micro_sl_min_pips);
                (sl_dist_pips.clamp(self.config.micro_sl_min_pips, 50.0).round(), true)
            }
            DowBreakout::None => {
                let default_sl = (raw_atr_pips * 0.8).clamp(self.config.micro_sl_min_pips, 50.0).round();
                (default_sl, false)
            }
        };

        let stop_loss_pips = calculated_sl_pips;
        // リスクリワード 1:2.5〜3.0 を目標設定
        let take_profit_pips = (stop_loss_pips * 2.5).round();

        // 許容損失額(2,000円)からロットサイズを逆算 (0.01〜max_lot_limitにクランプ)
        let calculated_lot = (self.config.target_risk_per_trade_jpy / (stop_loss_pips * pip_value_jpy))
            .clamp(0.01, self.config.max_lot_limit);
        let lot = (calculated_lot * 100.0).round() / 100.0;

        // フィボナッチゾーン情報 (存在する場合)
        let fib_info = if let Some(fib) = fib_opt {
            let in_fib_zone = mid_price >= fib.level_786 && mid_price <= fib.level_382;
            if in_fib_zone {
                format!("FIB_ZONE[38.2%: {:.3}, 50%: {:.3}, 61.8%: {:.3}]", fib.level_382, fib.level_500, fib.level_618)
            } else {
                "FIB_NORMAL".to_string()
            }
        } else {
            "FIB_N/A".to_string()
        };

        // 判定条件1: 下位足ダウ上昇ブレイク または ゴールデンクロス & RSIフィルター
        let is_buy_sma = prev_diff <= 0.0 && current_diff > 0.0;
        let is_buy_dow = matches!(dow_breakout, DowBreakout::BullishBreakout { .. });

        if (is_buy_dow || is_buy_sma) && rsi < self.config.rsi_overbought {
            let trigger_tag = if is_buy_dow { "DOW_BREAKOUT_BULL" } else { "SMA_GOLDEN_CROSS" };
            let reason = format!(
                "{} + RSI({:.1}) + {} | MICRO_SL(SL={:.0}pips, TP={:.0}pips, Lot={:.2}, DowTrigger={})",
                trigger_tag, rsi, fib_info, stop_loss_pips, take_profit_pips, lot, is_dow_triggered
            );
            info!("🎯 Generated BUY Signal for {}: {}", tick.symbol, reason);
            self.last_signal_time.insert(tick.symbol.clone(), tick.time);

            return Some(Signal {
                symbol: tick.symbol.clone(),
                action: SignalAction::Buy,
                lot,
                stop_loss_pips,
                take_profit_pips,
                reason,
                created_at: Utc::now(),
            });
        }

        // 判定条件2: 下位足ダウ下降ブレイク または デッドクロス & RSIフィルター
        let is_sell_sma = prev_diff >= 0.0 && current_diff < 0.0;
        let is_sell_dow = matches!(dow_breakout, DowBreakout::BearishBreakout { .. });

        if (is_sell_dow || is_sell_sma) && rsi > self.config.rsi_oversold {
            let trigger_tag = if is_sell_dow { "DOW_BREAKOUT_BEAR" } else { "SMA_DEAD_CROSS" };
            let reason = format!(
                "{} + RSI({:.1}) + {} | MICRO_SL(SL={:.0}pips, TP={:.0}pips, Lot={:.2}, DowTrigger={})",
                trigger_tag, rsi, fib_info, stop_loss_pips, take_profit_pips, lot, is_dow_triggered
            );
            info!("🎯 Generated SELL Signal for {}: {}", tick.symbol, reason);
            self.last_signal_time.insert(tick.symbol.clone(), tick.time);

            return Some(Signal {
                symbol: tick.symbol.clone(),
                action: SignalAction::Sell,
                lot,
                stop_loss_pips,
                take_profit_pips,
                reason,
                created_at: Utc::now(),
            });
        }

        None
    }
}
