use std::collections::VecDeque;

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

    #[allow(dead_code)]
    pub fn len(&self) -> usize {
        self.prices.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.prices.is_empty()
    }
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
    fn test_rsi() {
        let mut ind = TechnicalIndicators::new(20);
        for p in [100.0, 102.0, 104.0, 106.0, 108.0, 110.0] {
            ind.add_price(p);
        }
        let rsi = ind.rsi(5).unwrap();
        assert!(rsi > 90.0);
    }

    #[test]
    fn test_atr() {
        let mut ind = TechnicalIndicators::new(20);
        for p in [100.0, 101.0, 100.5, 102.0, 101.0] {
            ind.add_price(p);
        }
        let atr = ind.atr(4).unwrap();
        assert!(atr > 0.0);
    }
}
