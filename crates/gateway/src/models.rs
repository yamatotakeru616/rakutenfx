use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};
use serde::{de, Deserialize, Deserializer, Serialize, Serializer};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SignalAction {
    Buy,
    Sell,
    CloseAll,
    Hold,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum MarketRegimeState {
    /// 紫色: ボラティリティ高 (ATR) ＋ トレンド強 (ADX)（二重フィルター作動）
    Purple,
    /// 橙色: ボラティリティ高のみ (ATRフィルター作動)
    Orange,
    /// 赤色: トレンド強のみ (ADXフィルター作動)
    Red,
    /// 無色/緑: フィルター未作動（エントリー許可状態）
    Clear,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ExecutionType {
    New,
    Reverse,
    Pyramidding,
}

pub fn parse_flexible_datetime(s: &str) -> Result<DateTime<Utc>, String> {
    // 1. RFC3339 / ISO8601
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(dt.with_timezone(&Utc));
    }

    // 2. MT4標準フォーマット "YYYY.MM.DD HH:MM:SS"
    if let Ok(ndt) = NaiveDateTime::parse_from_str(s, "%Y.%m.%d %H:%M:%S") {
        return Ok(Utc.from_utc_datetime(&ndt));
    }

    // 3. "YYYY-MM-DD HH:MM:SS"
    if let Ok(ndt) = NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S") {
        return Ok(Utc.from_utc_datetime(&ndt));
    }

    // 4. "YYYY/MM/DD HH:MM:SS"
    if let Ok(ndt) = NaiveDateTime::parse_from_str(s, "%Y/%m/%d %H:%M:%S") {
        return Ok(Utc.from_utc_datetime(&ndt));
    }

    // フォールバック: 現在時刻
    Ok(Utc::now())
}

pub fn deserialize_flexible_datetime<'de, D>(deserializer: D) -> Result<DateTime<Utc>, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    parse_flexible_datetime(&s).map_err(de::Error::custom)
}

pub fn deserialize_flexible_datetime_opt<'de, D>(deserializer: D) -> Result<Option<DateTime<Utc>>, D::Error>
where
    D: Deserializer<'de>,
{
    let opt = Option::<String>::deserialize(deserializer)?;
    match opt {
        Some(s) if !s.trim().is_empty() => {
            parse_flexible_datetime(&s).map(Some).map_err(de::Error::custom)
        }
        _ => Ok(None),
    }
}

pub fn serialize_datetime<S>(dt: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    serializer.serialize_str(&dt.to_rfc3339())
}

pub fn serialize_datetime_opt<S>(dt: &Option<DateTime<Utc>>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    match dt {
        Some(d) => serializer.serialize_str(&d.to_rfc3339()),
        None => serializer.serialize_none(),
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tick {
    pub symbol: String,
    pub bid: f64,
    pub ask: f64,
    #[serde(
        deserialize_with = "deserialize_flexible_datetime",
        serialize_with = "serialize_datetime",
        default = "Utc::now"
    )]
    pub time: DateTime<Utc>,
    #[serde(default)]
    pub volume: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Signal {
    pub symbol: String,
    pub action: SignalAction,
    pub lot: f64,
    pub stop_loss_pips: f64,
    pub take_profit_pips: f64,
    pub reason: String,
    #[serde(default = "default_regime")]
    pub regime: MarketRegimeState,
    #[serde(default = "default_exec_type")]
    pub exec_type: ExecutionType,
    #[serde(
        deserialize_with = "deserialize_flexible_datetime",
        serialize_with = "serialize_datetime",
        default = "Utc::now"
    )]
    pub created_at: DateTime<Utc>,
}

fn default_regime() -> MarketRegimeState {
    MarketRegimeState::Clear
}

fn default_exec_type() -> ExecutionType {
    ExecutionType::New
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TradeLog {
    pub ticket: i64,
    pub symbol: String,
    pub action: SignalAction,
    pub lots: f64,
    pub open_price: f64,
    pub close_price: Option<f64>,
    #[serde(
        deserialize_with = "deserialize_flexible_datetime",
        serialize_with = "serialize_datetime"
    )]
    pub open_time: DateTime<Utc>,
    #[serde(
        deserialize_with = "deserialize_flexible_datetime_opt",
        serialize_with = "serialize_datetime_opt",
        default
    )]
    pub close_time: Option<DateTime<Utc>>,
    pub profit: f64,
    pub comment: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum IncomingMessage {
    #[serde(rename = "TICK")]
    Tick(Tick),
    #[serde(rename = "TRADE_LOG")]
    TradeLog(TradeLog),
    #[serde(rename = "PING")]
    Ping,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum OutgoingMessage {
    #[serde(rename = "SIGNAL")]
    Signal(Signal),
    #[serde(rename = "ACK")]
    Ack { message: String },
    #[serde(rename = "PONG")]
    Pong,
    #[serde(rename = "ERROR")]
    Error { message: String },
}
