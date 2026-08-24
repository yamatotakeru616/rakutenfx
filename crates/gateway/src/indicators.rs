use std::collections::VecDeque;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BollingerBands {
    pub middle: f64,
    pub upper: f64,
    pub lower: f64,
    pub std_dev: f64,
}

#[derive(Debug, Clone)]
pub struct TechnicalIndicators {
    max_history: usize,
    prices: VecDeque<f64>,
}

impl TechnicalIndicators {
    pub fn new(max_history: usize) -> Self {
        Self {
            max_history,
            prices: VecDeque::with_capacity(max_history),
        }
    }

    pub fn add_price(&mut self, price: f64) {
        if self.prices.len() >= self.max_history {
            self.prices.pop_front();
        }
        self.prices.push_back(price);
    }

    pub fn sma(&self, period: usize) -> Option<f64> {
        if self.prices.len() < period || period == 0 {
            return None;
        }
        let sum: f64 = self.prices.iter().rev().take(period).sum();
        Some(sum / period as f64)
    }

    #[allow(dead_code)]
    pub fn ema(&self, period: usize) -> Option<f64> {
        if self.prices.len() < period || period == 0 {
            return None;
        }
        let k = 2.0 / (period as f64 + 1.0);
        let mut iter = self.prices.iter().rev().take(period).rev();
        let first = *iter.next()?;
        let mut ema = first;

        for price in iter {
            ema = (price * k) + (ema * (1.0 - k));
        }
        Some(ema)
    }

    /// ボリンジャーバンド (Bollinger Bands) の算出
    pub fn bollinger_bands(&self, period: usize, num_std_dev: f64) -> Option<BollingerBands> {
        let middle = self.sma(period)?;
        let slice: Vec<f64> = self.prices.iter().rev().take(period).copied().collect();
        
        let variance: f64 = slice
            .iter()
            .map(|&p| {
                let diff = p - middle;
                diff * diff
            })
            .sum::<f64>()
            / period as f64;
            
        let std_dev = variance.sqrt();
        let upper = middle + (std_dev * num_std_dev);
        let lower = middle - (std_dev * num_std_dev);

        Some(BollingerBands {
            middle,
            upper,
            lower,
            std_dev,
        })
    }

    pub fn rsi(&self, period: usize) -> Option<f64> {
        if self.prices.len() <= period || period == 0 {
            return None;
        }

        let slice: Vec<f64> = self.prices.iter().rev().take(period + 1).rev().copied().collect();
        let mut gains = 0.0;
        let mut losses = 0.0;

        for i in 1..slice.len() {
            let change = slice[i] - slice[i - 1];
            if change > 0.0 {
                gains += change;
            } else {
                losses += change.abs();
            }
        }

        let avg_gain = gains / period as f64;
        let avg_loss = losses / period as f64;

        if avg_loss == 0.0 {
            return Some(100.0);
        }

        let rs = avg_gain / avg_loss;
        Some(100.0 - (100.0 / (1.0 + rs)))
    }

    /// ティックベースの平均ボラティリティ (ATR相当の価格変動幅)
    pub fn atr(&self, period: usize) -> Option<f64> {
        if self.prices.len() <= period || period == 0 {
            return None;
        }

        let slice: Vec<f64> = self.prices.iter().rev().take(period + 1).rev().copied().collect();
        let mut total_range = 0.0;

        for i in 1..slice.len() {
            let diff = (slice[i] - slice[i - 1]).abs();
            total_range += diff;
        }

        Some(total_range / period as f64)
    }

    /// MTF-ATR 異常ボラティリティ判定 (直近ATR > 長期SMA(ATR) * threshold_mult)
    pub fn mtf_atr_filter(&self, atr_period: usize, sma_period: usize, threshold_mult: f64) -> Option<(f64, f64, bool)> {
        let current_atr = self.atr(atr_period)?;
        let long_atr = self.atr(sma_period.max(atr_period * 2))?;
        let is_spike = current_atr > (long_atr * threshold_mult);
        Some((current_atr, long_atr, is_spike))
    }

    /// ADX (Average Directional Index) 近似トレンド強度計算 (0〜100)
    pub fn adx(&self, period: usize) -> Option<f64> {
        if self.prices.len() <= (period * 2) || period == 0 {
            // 最低限のデータが無い場合はデフォルトのレンジ値(20.0)を返却
            return Some(20.0);
        }

        let slice: Vec<f64> = self.prices.iter().rev().take(period + 1).rev().copied().collect();
        let mut plus_dm = 0.0;
        let mut minus_dm = 0.0;
        let mut tr = 0.0;

        for i in 1..slice.len() {
            let up_move = slice[i] - slice[i - 1];
            let down_move = slice[i - 1] - slice[i];

            if up_move > down_move && up_move > 0.0 {
                plus_dm += up_move;
            }
            if down_move > up_move && down_move > 0.0 {
                minus_dm += down_move;
            }
            tr += (slice[i] - slice[i - 1]).abs();
        }

        if tr == 0.0 {
            return Some(20.0);
        }

        let plus_di = (plus_dm / tr) * 100.0;
        let minus_di = (minus_dm / tr) * 100.0;
        let di_sum = plus_di + minus_di;
        if di_sum == 0.0 {
            return Some(20.0);
        }

        let dx = ((plus_di - minus_di).abs() / di_sum) * 100.0;
        Some(dx.clamp(0.0, 100.0))
    }

    /// 直近N期間の最高値・最安値 (スイングハイ・スイングロー)
    pub fn swing_high_low(&self, period: usize) -> Option<(f64, f64)> {
        if self.prices.len() < period || period == 0 {
            return None;
        }
        let slice: Vec<f64> = self.prices.iter().rev().take(period).copied().collect();
        let mut high = f64::MIN;
        let mut low = f64::MAX;

        for &p in &slice {
            if p > high {
                high = p;
            }
            if p < low {
                low = p;
            }
        }
        Some((high, low))
    }

    /// 上昇スイングにおけるフィボナッチ・リトレースメント値の算出
    pub fn fibonacci_retracement_up(&self, period: usize) -> Option<FibonacciLevels> {
        let (high, low) = self.swing_high_low(period)?;
        let diff = high - low;
        if diff <= 0.0 {
            return None;
        }

        Some(FibonacciLevels {
            high,
            low,
            level_382: high - (diff * 0.382),
            level_500: high - (diff * 0.500),
            level_618: high - (diff * 0.618),
            level_786: high - (diff * 0.786),
        })
    }

    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.prices.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.prices.is_empty()
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FibonacciLevels {
    pub high: f64,
    pub low: f64,
    pub level_382: f64,
    pub level_500: f64,
    pub level_618: f64,
    pub level_786: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sma() {
        let mut ind = TechnicalIndicators::new(10);
        for p in [10.0, 20.0, 30.0, 40.0, 50.0] {
            ind.add_price(p);
        }
        assert_eq!(ind.sma(3), Some(40.0));
        assert_eq!(ind.sma(5), Some(30.0));
    }

    #[test]
    fn test_bollinger_bands() {
        let mut ind = TechnicalIndicators::new(20);
        for p in [100.0, 101.0, 102.0, 101.0, 100.0] {
            ind.add_price(p);
        }
        let bb = ind.bollinger_bands(5, 2.0).unwrap();
        assert_eq!(bb.middle, 100.8);
        assert!(bb.upper > bb.middle);
        assert!(bb.lower < bb.middle);
    }

    #[test]
    fn test_rsi() {
        let mut ind = TechnicalIndicators::new(20);
        for p in [100.0, 102.0, 104.0, 106.0, 108.0, 110.0] {
            ind.add_price(p);
        }
        let rsi = ind.rsi(5).unwrap();
        assert!(rsi > 90.0);
    }

    #[test]
    fn test_adx() {
        let mut ind = TechnicalIndicators::new(30);
        for p in (0..20).map(|i| 100.0 + i as f64 * 2.0) {
            ind.add_price(p);
        }
        let adx = ind.adx(5).unwrap();
        assert!(adx > 0.0);
    }
}
