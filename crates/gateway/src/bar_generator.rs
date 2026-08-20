use chrono::{DateTime, Duration, TimeZone, Utc};
use std::collections::VecDeque;

/// タイムフレーム種別
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Timeframe {
    M1, // 1分足 (60秒)
    M5, // 5分足 (300秒)
    H1, // 1時間足 (3600秒)
}

impl Timeframe {
    pub fn duration_seconds(&self) -> i64 {
        match self {
            Timeframe::M1 => 60,
            Timeframe::M5 => 300,
            Timeframe::H1 => 3600,
        }
    }
}

/// OHLCV バー構造体
#[derive(Debug, Clone, PartialEq)]
pub struct Bar {
    pub open_time: DateTime<Utc>,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    pub timeframe: Timeframe,
}

impl Bar {
    pub fn new(timeframe: Timeframe, open_time: DateTime<Utc>, price: f64, volume: f64) -> Self {
        Self {
            open_time,
            open: price,
            high: price,
            low: price,
            close: price,
            volume,
            timeframe,
        }
    }

    pub fn update(&mut self, price: f64, volume: f64) {
        if price > self.high {
            self.high = price;
        }
        if price < self.low {
            self.low = price;
        }
        self.close = price;
        self.volume += volume;
    }
}

/// ダウ理論ブレイクアウト種別
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DowBreakout {
    /// 戻り高値を確定足実体で上抜け (上昇トレンド転換)
    BullishBreakout {
        broken_resistance: f64,
        recent_swing_low: f64,
    },
    /// 押し安値を確定足実体で下抜け (下降トレンド転換)
    BearishBreakout {
        broken_support: f64,
        recent_swing_high: f64,
    },
    /// ブレイクなし
    None,
}

/// ティック列からリアルタイムにバーを合成し、ダウ転換を自律判定するインメモリエンジン
#[derive(Debug, Clone)]
pub struct BarGenerator {
    pub timeframe: Timeframe,
    pub max_bars: usize,
    pub current_bar: Option<Bar>,
    pub closed_bars: VecDeque<Bar>,
}

impl BarGenerator {
    pub fn new(timeframe: Timeframe, max_bars: usize) -> Self {
        Self {
            timeframe,
            max_bars,
            current_bar: None,
            closed_bars: VecDeque::with_capacity(max_bars),
        }
    }

    /// タイムスタンプを対応するバーの開始時刻にアラインメント
    fn align_time(&self, time: DateTime<Utc>) -> DateTime<Utc> {
        let sec = self.timeframe.duration_seconds();
        let timestamp = time.timestamp();
        let aligned_ts = timestamp - (timestamp % sec);
        Utc.timestamp_opt(aligned_ts, 0).unwrap()
    }

    /// 単一ティックを処理し、バー確定時にOption<Bar>を返却
    pub fn on_tick(&mut self, price: f64, volume: f64, time: DateTime<Utc>) -> Option<Bar> {
        let aligned_open_time = self.align_time(time);

        match self.current_bar.take() {
            Some(mut bar) => {
                if bar.open_time == aligned_open_time {
                    // 同一バー内の更新
                    bar.update(price, volume);
                    self.current_bar = Some(bar);
                    None
                } else {
                    // 直前のバーが確定 (Close)
                    let closed = bar.clone();
                    if self.closed_bars.len() >= self.max_bars {
                        self.closed_bars.pop_front();
                    }
                    self.closed_bars.push_back(bar);

                    // 新しいバーを開始
                    self.current_bar = Some(Bar::new(self.timeframe, aligned_open_time, price, volume));
                    Some(closed)
                }
            }
            None => {
                // 初回ティック
                self.current_bar = Some(Bar::new(self.timeframe, aligned_open_time, price, volume));
                None
            }
        }
    }

    /// 直近の確定足からスイング高値（戻り高値）とスイング安値（押し安値）を探索
    #[allow(dead_code)]
    pub fn find_swing_points(&self, lookback: usize) -> Option<(f64, f64)> {
        if self.closed_bars.len() < lookback || lookback < 3 {
            return None;
        }

        let bars: Vec<&Bar> = self.closed_bars.iter().rev().take(lookback).collect();
        let mut max_high = f64::MIN;
        let mut min_low = f64::MAX;

        for b in bars {
            if b.high > max_high {
                max_high = b.high;
            }
            if b.low < min_low {
                min_low = b.low;
            }
        }

        Some((max_high, min_low))
    }

    /// 確定足の終値が直近の戻り高値/押し安値をブレイクしたか判定 (ダウ理論転換検知)
    pub fn check_dow_breakout(&self, lookback: usize) -> DowBreakout {
        if self.closed_bars.len() < lookback + 1 || lookback < 3 {
            return DowBreakout::None;
        }

        let latest_closed = self.closed_bars.back().unwrap();
        // 最新の確定足を除く過去N本からスイング高安を算出
        let prev_bars: Vec<&Bar> = self.closed_bars.iter().rev().skip(1).take(lookback).collect();
        let mut prev_swing_high = f64::MIN;
        let mut prev_swing_low = f64::MAX;

        for b in &prev_bars {
            if b.high > prev_swing_high {
                prev_swing_high = b.high;
            }
            if b.low < prev_swing_low {
                prev_swing_low = b.low;
            }
        }

        // 1. 戻り高値を実体終値で上抜け (上昇トレンド転換)
        if latest_closed.close > prev_swing_high {
            return DowBreakout::BullishBreakout {
                broken_resistance: prev_swing_high,
                recent_swing_low: prev_swing_low,
            };
        }

        // 2. 押し安値を実体終値で下抜け (下降トレンド転換)
        if latest_closed.close < prev_swing_low {
            return DowBreakout::BearishBreakout {
                broken_support: prev_swing_low,
                recent_swing_high: prev_swing_high,
            };
        }

        DowBreakout::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bar_generation_and_closure() {
        let mut gen = BarGenerator::new(Timeframe::M1, 100);
        let t0 = Utc.with_ymd_and_hms(2026, 8, 20, 10, 0, 0).unwrap();

        // 10:00:05 ティック
        let closed = gen.on_tick(155.00, 1.0, t0 + Duration::seconds(5));
        assert!(closed.is_none());

        // 10:00:30 ティック
        let closed = gen.on_tick(155.20, 1.0, t0 + Duration::seconds(30));
        assert!(closed.is_none());

        // 10:00:50 ティック
        let closed = gen.on_tick(154.90, 1.0, t0 + Duration::seconds(50));
        assert!(closed.is_none());

        // 10:01:02 ティック (1分経過 ➔ 前のバーが確定)
        let closed = gen.on_tick(155.10, 1.0, t0 + Duration::seconds(62));
        assert!(closed.is_some());

        let bar = closed.unwrap();
        assert_eq!(bar.open, 155.00);
        assert_eq!(bar.high, 155.20);
        assert_eq!(bar.low, 154.90);
        assert_eq!(bar.close, 154.90);
        assert_eq!(bar.volume, 3.0);
        assert_eq!(gen.closed_bars.len(), 1);
    }

    #[test]
    fn test_dow_breakout_detection() {
        let mut gen = BarGenerator::new(Timeframe::M1, 50);
        let t0 = Utc.with_ymd_and_hms(2026, 8, 20, 10, 0, 0).unwrap();

        // 過去バーを合成 (下降トレンドで戻り高値 155.30 を形成)
        let prices = [
            (155.20, 155.30, 155.10, 155.15), // Bar 1 (高値 155.30)
            (155.15, 155.20, 155.00, 155.05), // Bar 2
            (155.05, 155.10, 154.90, 154.95), // Bar 3 (安値 154.90)
            (154.95, 155.00, 154.85, 154.90), // Bar 4
        ];

        for (i, &(o, h, l, c)) in prices.iter().enumerate() {
            let bt = t0 + Duration::seconds(i as i64 * 60);
            gen.on_tick(o, 1.0, bt + Duration::seconds(1));
            gen.on_tick(h, 1.0, bt + Duration::seconds(10));
            gen.on_tick(l, 1.0, bt + Duration::seconds(20));
            gen.on_tick(c, 1.0, bt + Duration::seconds(50));
        }

        // 次の足で 155.30 (戻り高値) を一気に実体で上抜け (Close: 155.45)
        let break_t = t0 + Duration::seconds(4 * 60);
        gen.on_tick(154.90, 1.0, break_t + Duration::seconds(1));
        gen.on_tick(155.50, 1.0, break_t + Duration::seconds(20));
        gen.on_tick(155.45, 1.0, break_t + Duration::seconds(50));

        // 次足開始で上記ブレイク足が確定
        let next_t = t0 + Duration::seconds(5 * 60);
        gen.on_tick(155.45, 1.0, next_t + Duration::seconds(1));

        let breakout = gen.check_dow_breakout(4);
        match breakout {
            DowBreakout::BullishBreakout { broken_resistance, recent_swing_low } => {
                assert_eq!(broken_resistance, 155.30);
                assert_eq!(recent_swing_low, 154.85);
            }
            _ => panic!("Expected BullishBreakout, got {:?}", breakout),
        }
    }
}
