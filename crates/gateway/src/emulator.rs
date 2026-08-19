use std::net::SocketAddr;
use std::time::Duration;
use anyhow::{Context, Result};
use chrono::Utc;
use rand::Rng;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::time::sleep;
use tracing::info;

use crate::models::{IncomingMessage, OutgoingMessage, SignalAction, Tick, TradeLog};

pub struct Mt4Emulator {
    server_addr: SocketAddr,
    symbol: String,
    base_price: f64,
    spread: f64,
}

impl Mt4Emulator {
    pub fn new(server_addr: SocketAddr, symbol: String, base_price: f64, spread: f64) -> Self {
        Self {
            server_addr,
            symbol,
            base_price,
            spread,
        }
    }

    pub async fn run(&mut self, iterations: usize, interval_ms: u64) -> Result<()> {
        info!("Connecting MT4 Emulator to Gateway at {}", self.server_addr);
        let stream = TcpStream::connect(self.server_addr)
            .await
            .with_context(|| format!("Failed to connect to Gateway at {}", self.server_addr))?;

        let (reader, mut writer) = stream.into_split();
        let mut buf_reader = BufReader::new(reader);

        let mut rng = rand::thread_rng();
        let mut current_price = self.base_price;
        let mut ticket_counter = 100000i64;
        let mut active_position: Option<(i64, SignalAction, f64, f64, f64)> = None; // ticket, action, open_price, sl, tp

        info!("Starting emulation loop ({} iterations)...", iterations);

        for i in 1..=iterations {
            // ランダムウォークで価格変動をシミュレート
            let raw_delta: f64 = rng.gen_range(-0.05f64..0.05f64);
            let delta = (raw_delta * 100.0).round() / 100.0;
            current_price = ((current_price + delta) * 1000.0).round() / 1000.0;
            let bid = current_price;
            let ask = current_price + self.spread;

            // ポジションのSL/TP判定
            if let Some((ticket, action, open_price, sl, tp)) = active_position {
                let should_close = match action {
                    SignalAction::Buy => bid <= sl || bid >= tp,
                    SignalAction::Sell => ask >= sl || ask <= tp,
                    _ => false,
                };

                if should_close {
                    let close_price = if action == SignalAction::Buy { bid } else { ask };
                    let profit = if action == SignalAction::Buy {
                        (close_price - open_price) * 100000.0 * 0.1
                    } else {
                        (open_price - close_price) * 100000.0 * 0.1
                    };

                    info!(
                        "Emulator closed position #{} (Action: {:?}, Open: {:.3}, Close: {:.3}, Profit: {:.1} JPY)",
                        ticket, action, open_price, close_price, profit
                    );

                    let trade_log = TradeLog {
                        ticket,
                        symbol: self.symbol.clone(),
                        action,
                        lots: 0.1,
                        open_price,
                        close_price: Some(close_price),
                        open_time: Utc::now() - chrono::Duration::seconds(30),
                        close_time: Some(Utc::now()),
                        profit,
                        comment: Some("Emulator_AutoClose".to_string()),
                    };

                    let msg = serde_json::to_string(&IncomingMessage::TradeLog(trade_log))? + "\n";
                    writer.write_all(msg.as_bytes()).await?;
                    writer.flush().await?;

                    active_position = None;
                }
            }

            // ティック送信
            let tick = Tick {
                symbol: self.symbol.clone(),
                bid,
                ask,
                time: Utc::now(),
                volume: rng.gen_range(1.0..15.0),
            };

            let tick_msg = serde_json::to_string(&IncomingMessage::Tick(tick))? + "\n";
            writer.write_all(tick_msg.as_bytes()).await?;
            writer.flush().await?;

            // ゲートウェイからのシグナル受信
            let mut response_line = String::new();
            if buf_reader.read_line(&mut response_line).await? > 0 {
                if let Ok(OutgoingMessage::Signal(signal)) =
                    serde_json::from_str::<OutgoingMessage>(response_line.trim())
                {
                    if (signal.action == SignalAction::Buy || signal.action == SignalAction::Sell)
                        && active_position.is_none()
                    {
                        ticket_counter += 1;
                        let open_price = if signal.action == SignalAction::Buy { ask } else { bid };
                        let sl = if signal.action == SignalAction::Buy {
                            open_price - (signal.stop_loss_pips * 0.01)
                        } else {
                            open_price + (signal.stop_loss_pips * 0.01)
                        };
                        let tp = if signal.action == SignalAction::Buy {
                            open_price + (signal.take_profit_pips * 0.01)
                        } else {
                            open_price - (signal.take_profit_pips * 0.01)
                        };

                        info!(
                            "🎯 Emulator executing demo order #{} (Action: {:?}, Price: {:.3}, SL: {:.3}, TP: {:.3}, Reason: {})",
                            ticket_counter, signal.action, open_price, sl, tp, signal.reason
                        );

                        // オープン時の約定ログも送信
                        let trade_log = TradeLog {
                            ticket: ticket_counter,
                            symbol: self.symbol.clone(),
                            action: signal.action.clone(),
                            lots: signal.lot,
                            open_price,
                            close_price: None,
                            open_time: Utc::now(),
                            close_time: None,
                            profit: 0.0,
                            comment: Some(format!("Signal: {}", signal.reason)),
                        };
                        let msg = serde_json::to_string(&IncomingMessage::TradeLog(trade_log))? + "\n";
                        writer.write_all(msg.as_bytes()).await?;
                        writer.flush().await?;

                        active_position = Some((ticket_counter, signal.action, open_price, sl, tp));
                    }
                }
            }

            if i % 20 == 0 {
                info!("Emulation progress: {} / {} ticks processed", i, iterations);
            }

            sleep(Duration::from_millis(interval_ms)).await;
        }

        // シミュレーション終了時に保有中ポジションがあれば最終価格で成行決済
        if let Some((ticket, action, open_price, _, _)) = active_position {
            let close_price = current_price;
            let profit = if action == SignalAction::Buy {
                (close_price - open_price) * 100000.0 * 0.1
            } else {
                (open_price - close_price) * 100000.0 * 0.1
            };

            info!(
                "Closing remaining position #{} at end of simulation (Action: {:?}, Profit: {:.1} JPY)",
                ticket, action, profit
            );

            let trade_log = TradeLog {
                ticket,
                symbol: self.symbol.clone(),
                action,
                lots: 0.1,
                open_price,
                close_price: Some(close_price),
                open_time: Utc::now() - chrono::Duration::seconds(30),
                close_time: Some(Utc::now()),
                profit,
                comment: Some("SimulationEnd_MarketClose".to_string()),
            };

            let msg = serde_json::to_string(&IncomingMessage::TradeLog(trade_log))? + "\n";
            writer.write_all(msg.as_bytes()).await?;
            writer.flush().await?;
        }

        info!("MT4 Emulator completed {} iterations successfully.", iterations);
        Ok(())
    }
}
