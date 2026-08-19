use std::path::Path;
use std::sync::{Arc, Mutex};
use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use tracing::info;

use crate::models::{Signal, SignalAction, Tick, TradeLog};

#[derive(Clone)]
pub struct Database {
    conn: Arc<Mutex<Connection>>,
}

impl Database {
    pub fn new<P: AsRef<Path>>(path: P) -> Result<Self> {
        let conn = Connection::open(path.as_ref())
            .with_context(|| format!("Failed to open SQLite database at {:?}", path.as_ref()))?;

        // パフォーマンス向上のためのSQLite設定 (WALモード, synchronous=NORMAL)
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
            "#,
        )?;

        let db = Self {
            conn: Arc::new(Mutex::new(conn)),
        };
        db.init_tables()?;
        info!("Database initialized successfully at {:?}", path.as_ref());
        Ok(db)
    }

    fn init_tables(&self) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS ticks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                symbol TEXT NOT NULL,
                bid REAL NOT NULL,
                ask REAL NOT NULL,
                time TEXT NOT NULL,
                volume REAL NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX IF NOT EXISTS idx_ticks_symbol_time ON ticks (symbol, time);

            CREATE TABLE IF NOT EXISTS signals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                symbol TEXT NOT NULL,
                action TEXT NOT NULL,
                lot REAL NOT NULL,
                stop_loss_pips REAL NOT NULL,
                take_profit_pips REAL NOT NULL,
                reason TEXT NOT NULL,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_signals_created_at ON signals (created_at);

            CREATE TABLE IF NOT EXISTS trades (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ticket INTEGER UNIQUE NOT NULL,
                symbol TEXT NOT NULL,
                action TEXT NOT NULL,
                lots REAL NOT NULL,
                open_price REAL NOT NULL,
                close_price REAL,
                open_time TEXT NOT NULL,
                close_time TEXT,
                profit REAL NOT NULL,
                comment TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );

            CREATE INDEX IF NOT EXISTS idx_trades_ticket ON trades (ticket);
            CREATE INDEX IF NOT EXISTS idx_trades_symbol ON trades (symbol);
            "#,
        )?;
        Ok(())
    }

    pub fn insert_tick(&self, tick: &Tick) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO ticks (symbol, bid, ask, time, volume) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                tick.symbol,
                tick.bid,
                tick.ask,
                tick.time.to_rfc3339(),
                tick.volume,
            ],
        )?;
        Ok(())
    }

    pub fn insert_signal(&self, signal: &Signal) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let action_str = match signal.action {
            SignalAction::Buy => "BUY",
            SignalAction::Sell => "SELL",
            SignalAction::CloseAll => "CLOSE_ALL",
            SignalAction::Hold => "HOLD",
        };

        conn.execute(
            "INSERT INTO signals (symbol, action, lot, stop_loss_pips, take_profit_pips, reason, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                signal.symbol,
                action_str,
                signal.lot,
                signal.stop_loss_pips,
                signal.take_profit_pips,
                signal.reason,
                signal.created_at.to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub fn insert_or_update_trade(&self, trade: &TradeLog) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        let action_str = match trade.action {
            SignalAction::Buy => "BUY",
            SignalAction::Sell => "SELL",
            SignalAction::CloseAll => "CLOSE_ALL",
            SignalAction::Hold => "HOLD",
        };

        conn.execute(
            r#"
            INSERT INTO trades (ticket, symbol, action, lots, open_price, close_price, open_time, close_time, profit, comment)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(ticket) DO UPDATE SET
                close_price = excluded.close_price,
                close_time = excluded.close_time,
                profit = excluded.profit,
                comment = excluded.comment
            "#,
            params![
                trade.ticket,
                trade.symbol,
                action_str,
                trade.lots,
                trade.open_price,
                trade.close_price,
                trade.open_time.to_rfc3339(),
                trade.close_time.map(|t| t.to_rfc3339()),
                trade.profit,
                trade.comment,
            ],
        )?;
        Ok(())
    }

    #[allow(dead_code)]
    pub fn get_trade_count(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM trades", [], |row| row.get(0))?;
        Ok(count)
    }

    #[allow(dead_code)]
    pub fn get_tick_count(&self) -> Result<i64> {
        let conn = self.conn.lock().unwrap();
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM ticks", [], |row| row.get(0))?;
        Ok(count)
    }
}
