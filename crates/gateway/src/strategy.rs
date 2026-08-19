use std::collections::HashMap;
use chrono::{DateTime, Utc};
use tracing::{info, warn};

use crate::indicators::TechnicalIndicators;
use crate::models::{Signal, SignalAction, Tick};

#[derive(Debug, Clone)]
pub struct StrategyConfig {
    pub short_period: usize,
    pub long_period: usize,
    pub rsi_period: usize,
    pub atr_period: usize,
    pub rsi_overbought: f64,
    pub rsi_oversold: f64,
    pub target_risk_per_trade_jpy: f64, // 1トレードの許容最大損失額 (円)
    pub min_signal_interval_sec: i64,
}

impl Default for StrategyConfig {
    fn default() -> Self {
        Self {
            short_period: 5,
            long_period: 20,
            rsi_period: 14,
            atr_period: 14,
            rsi_overbought: 70.0,
            rsi_oversold: 30.0,
            target_risk_per_trade_jpy: 2000.0, // 2,000円固定リスク
            min_signal_interval_sec: 15,
        }
    }
}

pub struct SignalEngine {
    config: StrategyConfig,
    indicators: HashMap<String, TechnicalIndicators>,
    last_signal_time: HashMap<String, DateTime<Utc>>,
    last_sma_diff: HashMap<String, f64>,
}

impl SignalEngine {
    pub fn new(config: StrategyConfig) -> Self {
        Self {
            config,
            indicators: HashMap::new(),
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

        let ind = self
            .indicators
            .entry(tick.symbol.clone())
            .or_insert_with(|| TechnicalIndicators::new(self.config.long_period + 50));

        ind.add_price(mid_price);

        let short_sma = ind.sma(self.config.short_period)?;
        let long_sma = ind.sma(self.config.long_period)?;
        let rsi = ind.rsi(self.config.rsi_period).unwrap_or(50.0);
        let atr = ind.atr(self.config.atr_period).unwrap_or(pip_unit * 15.0);

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

        // 2. 動的ATRベースのSL/TP ＆ ポジションサイジング計算
        let raw_atr_pips = atr / pip_unit;
        let stop_loss_pips = (raw_atr_pips * 1.5).clamp(12.0, 80.0).round();
        let take_profit_pips = (stop_loss_pips * 2.0).round(); // リスクリワード 1:2

        // 許容損失額からロットサイズを自動算出 (0.01〜0.50 lotにクランプ)
        let calculated_lot = (self.config.target_risk_per_trade_jpy / (stop_loss_pips * pip_value_jpy))
            .clamp(0.01, 0.50);
        let lot = (calculated_lot * 100.0).round() / 100.0;

        // ゴールデンクロス (短期が長期を下から上に抜ける) & RSIフィルター
        if prev_diff <= 0.0 && current_diff > 0.0 && rsi < self.config.rsi_overbought {
            let reason = format!(
                "SMA_GOLDEN_CROSS + RSI({:.1}) | ATR_DYNAMIC(SL={:.0}pips, TP={:.0}pips, Lot={:.2}, Spread={:.1}pips)",
                rsi, stop_loss_pips, take_profit_pips, lot, current_spread_pips
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

        // デッドクロス (短期が長期を上から下に抜ける) & RSIフィルター
        if prev_diff >= 0.0 && current_diff < 0.0 && rsi > self.config.rsi_oversold {
            let reason = format!(
                "SMA_DEAD_CROSS + RSI({:.1}) | ATR_DYNAMIC(SL={:.0}pips, TP={:.0}pips, Lot={:.2}, Spread={:.1}pips)",
                rsi, stop_loss_pips, take_profit_pips, lot, current_spread_pips
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
