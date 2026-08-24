use std::net::SocketAddr;
use std::sync::Arc;
use anyhow::{Context, Result};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use tracing::{error, info, warn};

use crate::ai_client::AiKillSwitchClient;
use crate::db::Database;
use crate::models::{IncomingMessage, OutgoingMessage, Signal, SignalAction};
use crate::strategy::SignalEngine;

pub struct GatewayServer {
    addr: SocketAddr,
    db: Database,
    engine: Arc<Mutex<SignalEngine>>,
    ai_client: AiKillSwitchClient,
}

impl GatewayServer {
    pub fn new(addr: SocketAddr, db: Database, engine: SignalEngine) -> Self {
        let ai_ipc_addr: SocketAddr = "127.0.0.1:5556".parse().unwrap();
        Self {
            addr,
            db,
            engine: Arc::new(Mutex::new(engine)),
            ai_client: AiKillSwitchClient::new(ai_ipc_addr, true),
        }
    }

    pub async fn run(&self) -> Result<()> {
        let listener = TcpListener::bind(self.addr)
            .await
            .with_context(|| format!("Failed to bind TCP listener to {}", self.addr))?;

        info!("🚀 MT4 Gateway Server is listening on {}", self.addr);

        loop {
            match listener.accept().await {
                Ok((stream, client_addr)) => {
                    info!("New client connected from {}", client_addr);
                    let db = self.db.clone();
                    let engine = Arc::clone(&self.engine);
                    let ai_client = self.ai_client.clone();

                    tokio::spawn(async move {
                        if let Err(e) = handle_connection(stream, db, engine, ai_client).await {
                            warn!("Connection error with {}: {:?}", client_addr, e);
                        }
                    });
                }
                Err(e) => {
                    error!("Error accepting connection: {:?}", e);
                }
            }
        }
    }
}

async fn handle_connection(
    stream: TcpStream,
    db: Database,
    engine: Arc<Mutex<SignalEngine>>,
    ai_client: AiKillSwitchClient,
) -> Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut buf_reader = BufReader::new(reader);
    let mut line = String::new();

    while buf_reader.read_line(&mut line).await? > 0 {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            line.clear();
            continue;
        }

        let response = match serde_json::from_str::<IncomingMessage>(trimmed) {
            Ok(IncomingMessage::Tick(tick)) => {
                // 1. DBにティック保存
                if let Err(e) = db.insert_tick(&tick) {
                    error!("Failed to save tick to DB: {:?}", e);
                }

                // 2. シグナル判定
                let signal_opt = {
                    let mut eng = engine.lock().await;
                    eng.process_tick(&tick)
                };

                if let Some(signal) = signal_opt {
                    // AIキルスイッチによる事前インターロック検証
                    let is_approved = ai_client.verify_signal(&signal, None).await;

                    if is_approved {
                        if let Err(e) = db.insert_signal(&signal) {
                            error!("Failed to save signal to DB: {:?}", e);
                        }
                        OutgoingMessage::Signal(signal)
                    } else {
                        info!("🛡️ Signal suppressed by AI Kill-Switch. Sending HOLD to MT4.");
                        OutgoingMessage::Signal(Signal {
                            symbol: tick.symbol,
                            action: SignalAction::Hold,
                            lot: 0.0,
                            stop_loss_pips: 0.0,
                            take_profit_pips: 0.0,
                            reason: "SUPPRESSED_BY_AI_KILL_SWITCH".to_string(),
                            regime: crate::models::MarketRegimeState::Clear,
                            exec_type: crate::models::ExecutionType::New,
                            created_at: chrono::Utc::now(),
                        })
                    }
                } else {
                    OutgoingMessage::Signal(Signal {
                        symbol: tick.symbol,
                        action: SignalAction::Hold,
                        lot: 0.0,
                        stop_loss_pips: 0.0,
                        take_profit_pips: 0.0,
                        reason: "HOLD".to_string(),
                        regime: crate::models::MarketRegimeState::Clear,
                        exec_type: crate::models::ExecutionType::New,
                        created_at: chrono::Utc::now(),
                    })
                }
            }
            Ok(IncomingMessage::TradeLog(trade_log)) => {
                info!(
                    "Received TradeLog for ticket #{}: profit={:.2}",
                    trade_log.ticket, trade_log.profit
                );
                if let Err(e) = db.insert_or_update_trade(&trade_log) {
                    error!("Failed to save trade log to DB: {:?}", e);
                }
                OutgoingMessage::Ack {
                    message: format!("TradeLog for #{} saved", trade_log.ticket),
                }
            }
            Ok(IncomingMessage::Ping) => OutgoingMessage::Pong,
            Err(e) => {
                warn!("Invalid JSON message: {} (Error: {:?})", trimmed, e);
                OutgoingMessage::Error {
                    message: format!("JSON parse error: {:?}", e),
                }
            }
        };

        let mut res_json = serde_json::to_string(&response)?;
        res_json.push('\n');
        writer.write_all(res_json.as_bytes()).await?;
        writer.flush().await?;

        line.clear();
    }

    Ok(())
}
