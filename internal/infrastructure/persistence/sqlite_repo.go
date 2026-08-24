package persistence

import (
	"database/sql"
	"fmt"
	"log"
	"rakutenfx/internal/domain"
	"time"

	_ "modernc.org/sqlite"
)

type SQLiteRepository struct {
	db *sql.DB
}

func NewSQLiteRepository(dbPath string) (*SQLiteRepository, error) {
	// WALモードおよびパフォーマンスチューニング接続文字列
	dsn := fmt.Sprintf("%s?_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=busy_timeout(5000)", dbPath)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("failed to open sqlite db: %w", err)
	}

	// 接続プール設定
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(time.Hour)

	repo := &SQLiteRepository{db: db}
	if err := repo.initTables(); err != nil {
		return nil, fmt.Errorf("failed to init tables: %w", err)
	}

	log.Printf("[DB] SQLite database initialized at %s (WAL Mode)", dbPath)
	return repo, nil
}

func (r *SQLiteRepository) initTables() error {
	schema := `
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

	CREATE TABLE IF NOT EXISTS ai_reports (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		title TEXT NOT NULL,
		overall_rank TEXT NOT NULL,
		summary TEXT NOT NULL,
		strengths_json TEXT NOT NULL,
		weaknesses_json TEXT NOT NULL,
		action_points_json TEXT NOT NULL,
		raw_report TEXT NOT NULL,
		created_at DATETIME NOT NULL DEFAULT (datetime('now'))
	);
	`
	_, err := r.db.Exec(schema)
	return err
}

func (r *SQLiteRepository) GetAllTrades() ([]domain.TradeRecord, error) {
	rows, err := r.db.Query(`
		SELECT id, ticket, symbol, action, lots, open_price, close_price, open_time, close_time, profit, COALESCE(comment, ''), created_at
		FROM trades
		ORDER BY id ASC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var trades []domain.TradeRecord
	for rows.Next() {
		var t domain.TradeRecord
		var closePrice sql.NullFloat64
		var closeTime sql.NullString
		if err := rows.Scan(
			&t.ID, &t.Ticket, &t.Symbol, &t.Action, &t.Lots,
			&t.OpenPrice, &closePrice, &t.OpenTime, &closeTime,
			&t.Profit, &t.Comment, &t.CreatedAt,
		); err != nil {
			return nil, err
		}
		if closePrice.Valid {
			t.ClosePrice = &closePrice.Float64
		}
		if closeTime.Valid {
			t.CloseTime = &closeTime.String
		}
		trades = append(trades, t)
	}
	return trades, nil
}

func (r *SQLiteRepository) GetRecentSignals(limit int) ([]domain.Signal, error) {
	rows, err := r.db.Query(`
		SELECT id, symbol, action, lot, stop_loss_pips, take_profit_pips, reason, created_at
		FROM signals
		ORDER BY id DESC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var signals []domain.Signal
	for rows.Next() {
		var s domain.Signal
		if err := rows.Scan(
			&s.ID, &s.Symbol, &s.Action, &s.Lot,
			&s.StopLossPips, &s.TakeProfitPips, &s.Reason, &s.CreatedAt,
		); err != nil {
			return nil, err
		}
		signals = append(signals, s)
	}
	return signals, nil
}

func (r *SQLiteRepository) InsertSignal(s *domain.Signal) error {
	now := time.Now().Format("2006-01-02 15:04:05")
	if s.CreatedAt == "" {
		s.CreatedAt = now
	}
	_, err := r.db.Exec(`
		INSERT INTO signals (symbol, action, lot, stop_loss_pips, take_profit_pips, reason, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`, s.Symbol, s.Action, s.Lot, s.StopLossPips, s.TakeProfitPips, s.Reason, s.CreatedAt)
	return err
}

func (r *SQLiteRepository) InsertTick(t *domain.Tick) error {
	now := time.Now().Format("2006-01-02 15:04:05")
	if t.CreatedAt == "" {
		t.CreatedAt = now
	}
	_, err := r.db.Exec(`
		INSERT INTO ticks (symbol, bid, ask, time, volume, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, t.Symbol, t.Bid, t.Ask, t.Time, t.Volume, t.CreatedAt)
	return err
}

func (r *SQLiteRepository) SaveAiReport(report *domain.AiEvaluationReport) error {
	// JSON文字列変換用のダミー（後で拡張可能）
	_, err := r.db.Exec(`
		INSERT INTO ai_reports (title, overall_rank, summary, strengths_json, weaknesses_json, action_points_json, raw_report, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, report.Title, report.OverallRank, report.Summary, "[]", "[]", "[]", report.RawReport, time.Now())
	return err
}

func (r *SQLiteRepository) Close() error {
	return r.db.Close()
}
