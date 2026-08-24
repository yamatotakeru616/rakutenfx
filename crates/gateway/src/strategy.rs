use std::collections::HashMap;
use chrono::{DateTime, Timelike, Utc};
use tracing::{info, warn};

use crate::bar_generator::{BarGenerator, DowBreakout, Timeframe};
use crate::indicators::TechnicalIndicators;
use crate::models::{ExecutionType, MarketRegimeState, Signal, SignalAction, Tick};

#[derive(Debug, Clone)]
pub struct StrategyConfig {
    // ボリンジャーバンド設定
    pub bb_period: usize,
    pub bb_dev: f64,
    // RSI設定
    pub rsi_period: usize,
    pub rsi_overbought: f64,
    pub rsi_oversold: f64,
    // MTF-ATR設定 (上位足ボラティリティフィルター)
    pub atr_period: usize,
    pub mtf_atr_sma_period: usize,
    pub mtf_atr_threshold_mult: f64,
    // ADX設定 (トレンド強度フィルター)
    pub adx_period: usize,
    pub adx_threshold: f64,
    // フィボナッチ ＆ ダウ設定
    pub fib_swing_period: usize,
    pub dow_lookback: usize,
    // 資金管理 ＆ リスク設定
    pub target_risk_per_trade_jpy: f64,
    pub min_signal_interval_sec: i64,
    pub micro_sl_min_pips: f64,
    pub max_lot_limit: f64,
    pub max_positions: usize, // ピラミッティング上限 (最大2)
}

impl Default for StrategyConfig {
    fn default() -> Self {
        Self {
            bb_period: 20,
            bb_dev: 2.0,
            rsi_period: 14,
            rsi_overbought: 70.0,
            rsi_oversold: 30.0,
            atr_period: 14,
            mtf_atr_sma_period: 50,
            mtf_atr_threshold_mult: 1.5,
            adx_period: 14,
            adx_threshold: 25.0, // USD/JPY基準 (GBPJPYは動的調整)
            fib_swing_period: 50,
            dow_lookback: 6,
            target_risk_per_trade_jpy: 2000.0,
            min_signal_interval_sec: 15,
            micro_sl_min_pips: 4.0,
            max_lot_limit: 1.00,
            max_positions: 2,
        }
    }
}

pub struct SignalEngine {
    config: StrategyConfig,
    indicators: HashMap<String, TechnicalIndicators>,
    bar_generators: HashMap<String, BarGenerator>,
    last_signal_time: HashMap<String, DateTime<Utc>>,
    current_position_count: HashMap<String, (SignalAction, usize)>,
}

impl SignalEngine {
    pub fn new(config: StrategyConfig) -> Self {
        Self {
            config,
            indicators: HashMap::new(),
            bar_generators: HashMap::new(),
            last_signal_time: HashMap::new(),
            current_position_count: HashMap::new(),
        }
    }

    /// 通貨ペアごとの 1 pip の価格単位、最大許容スプレッド (pips)、適正ADX閾値を取得
    fn get_symbol_profile(&self, symbol: &str) -> (f64, f64, f64, f64) {
        // (pip_unit, max_allowed_spread_pips, pip_value_per_lot_jpy, adx_threshold)
        let upper = symbol.to_uppercase();
        if upper.contains("GBP") {
            (0.01, 3.5, 1000.0, 15.0) // GBPJPY等はADX閾値を低めに設定
        } else if upper.contains("JPY") {
            (0.01, 3.0, 1000.0, self.config.adx_threshold)
        } else if upper.contains("XAU") || upper.contains("GOLD") {
            (0.1, 70.0, 1500.0, 20.0)
        } else {
            (0.0001, 2.5, 15000.0 * 0.0001 * 100000.0, self.config.adx_threshold)
        }
    }

    pub fn process_tick(&mut self, tick: &Tick) -> Option<Signal> {
        let (pip_unit, max_spread_pips, pip_value_jpy, custom_adx_threshold) = self.get_symbol_profile(&tick.symbol);

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

        // 2. 指標データの更新 ＆ インジケーター計算
        let ind = self
            .indicators
            .entry(tick.symbol.clone())
            .or_insert_with(|| TechnicalIndicators::new(self.config.mtf_atr_sma_period.max(self.config.bb_period) + 100));

        ind.add_price(mid_price);

        // 3. M1 バー生成 ＆ ダウ転換判定
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

        // 各種インジケーターの算出
        let bb = ind.bollinger_bands(self.config.bb_period, self.config.bb_dev)?;
        let rsi = ind.rsi(self.config.rsi_period).unwrap_or(50.0);
        let atr = ind.atr(self.config.atr_period).unwrap_or(pip_unit * 15.0);
        let adx = ind.adx(self.config.adx_period).unwrap_or(20.0);
        let (_, _, is_atr_spike) = ind.mtf_atr_filter(
            self.config.atr_period,
            self.config.mtf_atr_sma_period,
            self.config.mtf_atr_threshold_mult,
        ).unwrap_or((atr, atr, false));

        let is_adx_trend = adx >= custom_adx_threshold;

        // 4. マーケットコンテキスト 4ステート判定
        let regime = match (is_atr_spike, is_adx_trend) {
            (true, true) => MarketRegimeState::Purple,   // ボラ高 + トレンド強 (二重フィルター)
            (true, false) => MarketRegimeState::Orange,  // ボラ高のみ (ATRフィルター)
            (false, true) => MarketRegimeState::Red,     // トレンド強のみ (ADXフィルター)
            (false, false) => MarketRegimeState::Clear,  // フィルター未作動 (エントリー許可)
        };

        // クールダウン期間の確認
        if let Some(last_time) = self.last_signal_time.get(&tick.symbol) {
            let elapsed = tick.time.signed_duration_since(*last_time).num_seconds();
            if elapsed < self.config.min_signal_interval_sec {
                return None;
            }
        }

        // 5. 59分台先読みガード (Next Hour Lookahead)
        let minute = tick.time.minute();
        if minute == 59 {
            // XX時59分の境界線リスク回避（安全措置）
            info!("⏳ 59-minute boundary lookahead filter active. Skipping new entries.");
            return None;
        }

        // 6. コア逆張りシグナル判定 (BB + RSI 平均回帰)
        let is_buy_mr = mid_price < bb.lower && rsi < self.config.rsi_oversold;
        let is_sell_mr = mid_price > bb.upper && rsi > self.config.rsi_overbought;

        // ダウブレイクアウト（フィボナッチ順張り）との複合エッジ
        let is_buy_dow = matches!(dow_breakout, DowBreakout::BullishBreakout { .. });
        let is_sell_dow = matches!(dow_breakout, DowBreakout::BearishBreakout { .. });

        let buy_triggered = (is_buy_mr || is_buy_dow) && regime == MarketRegimeState::Clear;
        let sell_triggered = (is_sell_mr || is_sell_dow) && regime == MarketRegimeState::Clear;

        if !buy_triggered && !sell_triggered {
            return None;
        }

        // 7. ポジション管理・土転 (Reverse) ＆ ピラミッティング (最大2)
        let (current_action, current_count) = self
            .current_position_count
            .get(&tick.symbol)
            .copied()
            .unwrap_or((SignalAction::Hold, 0));

        let (action, exec_type) = if buy_triggered {
            if current_action == SignalAction::Sell && current_count > 0 {
                (SignalAction::Buy, ExecutionType::Reverse) // ドテン買い
            } else if current_action == SignalAction::Buy && current_count < self.config.max_positions {
                (SignalAction::Buy, ExecutionType::Pyramidding) // ピラミッティング買い
            } else if current_count == 0 {
                (SignalAction::Buy, ExecutionType::New) // 新規買い
            } else {
                return None; // ポジション上限到達
            }
        } else {
            if current_action == SignalAction::Buy && current_count > 0 {
                (SignalAction::Sell, ExecutionType::Reverse) // ドテン売り
            } else if current_action == SignalAction::Sell && current_count < self.config.max_positions {
                (SignalAction::Sell, ExecutionType::Pyramidding) // ピラミッティング売り
            } else if current_count == 0 {
                (SignalAction::Sell, ExecutionType::New) // 新規売り
            } else {
                return None;
            }
        };

        // 8. 動的SL/TP ＆ ポジションサイジング計算
        let raw_atr_pips = (atr / pip_unit).max(10.0);
        let stop_loss_pips = (raw_atr_pips * 1.0).clamp(self.config.micro_sl_min_pips, 50.0).round();
        let take_profit_pips = (stop_loss_pips * 2.0).round(); // リスクリワード 1:2

        let calculated_lot = (self.config.target_risk_per_trade_jpy / (stop_loss_pips * pip_value_jpy))
            .clamp(0.01, self.config.max_lot_limit);
        let lot = (calculated_lot * 100.0).round() / 100.0;

        let reason = format!(
            "MEAN_REV[BB={:.3}/{:.3}, RSI={:.1}, ADX={:.1}, ATR={:.1}pips, Regime={:?}, Exec={:?}]",
            bb.lower, bb.upper, rsi, adx, raw_atr_pips, regime, exec_type
        );

        info!("🎯 Generated {:?} Signal for {}: {}", action, tick.symbol, reason);
        self.last_signal_time.insert(tick.symbol.clone(), tick.time);

        // ポジション数更新
        let new_count = match exec_type {
            ExecutionType::New => 1,
            ExecutionType::Pyramidding => current_count + 1,
            ExecutionType::Reverse => 1,
        };
        self.current_position_count.insert(tick.symbol.clone(), (action, new_count));

        Some(Signal {
            symbol: tick.symbol.clone(),
            action,
            lot,
            stop_loss_pips,
            take_profit_pips,
            reason,
            regime,
            exec_type,
            created_at: Utc::now(),
        })
    }
}
