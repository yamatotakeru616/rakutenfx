use std::net::SocketAddr;
use std::path::PathBuf;
use anyhow::Result;
use clap::{Parser, Subcommand};
use tracing::info;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

mod db;
mod emulator;
mod indicators;
mod models;
mod server;
mod strategy;

use db::Database;
use emulator::Mt4Emulator;
use server::GatewayServer;
use strategy::{SignalEngine, StrategyConfig};

#[derive(Parser, Debug)]
#[command(name = "mt4-gateway")]
#[command(about = "Rust Gateway and Signal Engine for MT4 Trading Pipeline", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Listen address for MT4 TCP socket
    #[arg(short, long, default_value = "127.0.0.1:5555")]
    bind: SocketAddr,

    /// Path to SQLite database file
    #[arg(short, long, default_value = "trade_pipeline.db")]
    db: PathBuf,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Start the Gateway server
    Serve {
        #[arg(short, long, default_value = "127.0.0.1:5555")]
        bind: SocketAddr,
        #[arg(short, long, default_value = "trade_pipeline.db")]
        db: PathBuf,
    },
    /// Run virtual MT4 emulator to simulate ticks and demo orders
    Emulate {
        #[arg(short, long, default_value = "127.0.0.1:5555")]
        target: SocketAddr,
        #[arg(short, long, default_value = "USDJPY")]
        symbol: String,
        #[arg(short, long, default_value_t = 155.0)]
        base_price: f64,
        #[arg(short = 'n', long, default_value_t = 100)]
        ticks: usize,
        #[arg(short, long, default_value_t = 50)]
        interval_ms: u64,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "gateway=info,tower_http=debug".into()))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Emulate {
            target,
            symbol,
            base_price,
            ticks,
            interval_ms,
        }) => {
            info!("Starting MT4 Virtual Emulator...");
            let mut emulator = Mt4Emulator::new(target, symbol, base_price, 0.004);
            emulator.run(ticks, interval_ms).await?;
        }
        Some(Commands::Serve { bind, db }) => {
            info!("Starting MT4 Gateway Server on {}...", bind);
            let database = Database::new(&db)?;
            let config = StrategyConfig::default();
            let engine = SignalEngine::new(config);
            let server = GatewayServer::new(bind, database, engine);
            server.run().await?;
        }
        None => {
            info!("Starting MT4 Gateway Server on {}...", cli.bind);
            let database = Database::new(&cli.db)?;
            let config = StrategyConfig::default();
            let engine = SignalEngine::new(config);
            let server = GatewayServer::new(cli.bind, database, engine);
            server.run().await?;
        }
    }

    Ok(())
}
