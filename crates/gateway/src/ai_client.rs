use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::time::timeout;
use tracing::{info, warn};

use crate::models::{Signal, SignalAction};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalCheckRequest {
    #[serde(rename = "type")]
    pub req_type: String,
    pub symbol: String,
    pub action: SignalAction,
    pub image_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignalCheckResponse {
    #[serde(rename = "type")]
    pub resp_type: String,
    pub decision: String, // "APPROVE", "REJECT_KILL_SWITCH", "NEUTRAL"
    pub confidence: f64,
    pub matched_pattern: Option<String>,
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct AiKillSwitchClient {
    pub server_addr: SocketAddr,
    pub enabled: bool,
    pub timeout_ms: u64,
}

impl AiKillSwitchClient {
    pub fn new(server_addr: SocketAddr, enabled: bool) -> Self {
        Self {
            server_addr,
            enabled,
            timeout_ms: 100, // 100ms 超高速タイムアウト
        }
    }

    /// シグナルの安全性をPython AIキルスイッチへ問い合わせ
    pub async fn verify_signal(&self, signal: &Signal, image_path: Option<&str>) -> bool {
        if !self.enabled {
            return true; // キルスイッチ無効時は全承認
        }

        let img = image_path.unwrap_or("").to_string();
        let req = SignalCheckRequest {
            req_type: "CHECK_SIGNAL".to_string(),
            symbol: signal.symbol.clone(),
            action: signal.action,
            image_path: img,
        };

        let req_json = match serde_json::to_string(&req) {
            Ok(j) => j + "\n",
            Err(_) => return true,
        };

        let verify_future = async {
            let mut stream = TcpStream::connect(self.server_addr).await?;
            stream.write_all(req_json.as_bytes()).await?;
            stream.flush().await?;

            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            if reader.read_line(&mut line).await? > 0 {
                let resp: SignalCheckResponse = serde_json::from_str(line.trim())?;
                Ok(resp)
            } else {
                Err(anyhow::anyhow!("Empty response from AI IPC Server"))
            }
        };

        match timeout(Duration::from_millis(self.timeout_ms), verify_future).await {
            Ok(Ok(resp)) => {
                if resp.decision == "REJECT_KILL_SWITCH" {
                    warn!(
                        "🛡️ [AI_KILL_SWITCH_ACTIVE] Intercepted and BLOCKED {:?} order for {}: {}",
                        signal.action, signal.symbol, resp.reason
                    );
                    false
                } else {
                    info!(
                        "✅ [AI_APPROVED] Signal approved by AI Kill-Switch (Confidence: {:.1}%): {}",
                        resp.confidence, resp.reason
                    );
                    true
                }
            }
            Ok(Err(e)) => {
                warn!(
                    "[AI KillSwitch] IPC request failed ({:?}). Falling back to approve signal.",
                    e
                );
                true
            }
            Err(_) => {
                warn!("[AI KillSwitch] IPC timeout ({}ms). Falling back to approve signal.", self.timeout_ms);
                true
            }
        }
    }
}
