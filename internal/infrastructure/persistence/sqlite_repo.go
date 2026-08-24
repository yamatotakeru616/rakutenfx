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

	CREATE TABLE IF NOT EXISTS backtest_runs (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		symbol TEXT NOT NULL,
		params_json TEXT NOT NULL,
		total_trades INTEGER NOT NULL,
		win_rate REAL NOT NULL,
		profit_factor REAL NOT NULL,
		total_profit REAL NOT NULL,
		max_drawdown REAL NOT NULL,
		max_drawdown_pct REAL NOT NULL,
		sharpe_ratio REAL NOT NULL,
		robustness_score REAL NOT NULL,
		ai_report_json TEXT NOT NULL,
		created_at DATETIME NOT NULL DEFAULT (datetime('now'))
	);
	CREATE INDEX IF NOT EXISTS idx_bt_runs_created ON backtest_runs (created_at);

	CREATE TABLE IF NOT EXISTS backtest_trades (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		run_id INTEGER NOT NULL,
		ticket INTEGER NOT NULL,
		action TEXT NOT NULL,
		lots REAL NOT NULL,
		open_price REAL NOT NULL,
		close_price REAL NOT NULL,
		open_time DATETIME NOT NULL,
		close_time DATETIME NOT NULL,
		profit REAL NOT NULL,
		pips REAL NOT NULL,
		reason TEXT NOT NULL,
		regime TEXT NOT NULL,
		FOREIGN KEY(run_id) REFERENCES backtest_runs(id) ON DELETE CASCADE
	);
	CREATE INDEX IF NOT EXISTS idx_bt_trades_run ON backtest_trades (run_id);

	CREATE TABLE IF NOT EXISTS backtest_optimizations (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		run_id INTEGER NOT NULL,
		rank INTEGER NOT NULL,
		params_json TEXT NOT NULL,
		profit_factor REAL NOT NULL,
		win_rate REAL NOT NULL,
		total_profit REAL NOT NULL,
		max_drawdown REAL NOT NULL,
		total_trades INTEGER NOT NULL,
		robustness_score REAL NOT NULL,
		created_at DATETIME NOT NULL DEFAULT (datetime('now'))
	);
	CREATE INDEX IF NOT EXISTS idx_bt_opts_run ON backtest_optimizations (run_id);
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

// SaveBacktestRun saves a backtest execution summary and returns the inserted run ID.
func (r *SQLiteRepository) SaveBacktestRun(rec *domain.BacktestRunRecord) (int64, error) {
	res, err := r.db.Exec(`
		INSERT INTO backtest_runs (
			symbol, params_json, total_trades, win_rate, profit_factor,
			total_profit, max_drawdown, max_drawdown_pct, sharpe_ratio,
			robustness_score, ai_report_json, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, rec.Symbol, rec.ParamsJSON, rec.TotalTrades, rec.WinRate, rec.ProfitFactor,
		rec.TotalProfit, rec.MaxDrawdown, rec.MaxDrawdownPct, rec.SharpeRatio,
		rec.RobustnessScore, rec.AiReportJSON, time.Now())
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// SaveBacktestTrades saves all simulated trade records for a run.
func (r *SQLiteRepository) SaveBacktestTrades(runID int64, trades []domain.BacktestTradeRecord) error {
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO backtest_trades (
			run_id, ticket, action, lots, open_price, close_price,
			open_time, close_time, profit, pips, reason, regime
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for _, t := range trades {
		_, err := stmt.Exec(
			runID, t.Ticket, t.Action, t.Lots, t.OpenPrice, t.ClosePrice,
			t.OpenTime, t.CloseTime, t.Profit, t.Pips, t.Reason, t.Regime,
		)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

// SaveOptimizations saves grid search top rankings for a run.
func (r *SQLiteRepository) SaveOptimizations(runID int64, opts []domain.BacktestOptimizationRecord) error {
	tx, err := r.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO backtest_optimizations (
			run_id, rank, params_json, profit_factor, win_rate,
			total_profit, max_drawdown, total_trades, robustness_score, created_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	now := time.Now()
	for _, o := range opts {
		_, err := stmt.Exec(
			runID, o.Rank, o.ParamsJSON, o.ProfitFactor, o.WinRate,
			o.TotalProfit, o.MaxDrawdown, o.TotalTrades, o.RobustnessScore, now,
		)
		if err != nil {
			return err
		}
	}
	return tx.Commit()
}

// GetBacktestRuns retrieves past backtest execution summaries.
func (r *SQLiteRepository) GetBacktestRuns(limit int) ([]domain.BacktestRunRecord, error) {
	rows, err := r.db.Query(`
		SELECT id, symbol, params_json, total_trades, win_rate, profit_factor,
		       total_profit, max_drawdown, max_drawdown_pct, sharpe_ratio,
		       robustness_score, ai_report_json, created_at
		FROM backtest_runs
		ORDER BY id DESC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []domain.BacktestRunRecord
	for rows.Next() {
		var rec domain.BacktestRunRecord
		if err := rows.Scan(
			&rec.ID, &rec.Symbol, &rec.ParamsJSON, &rec.TotalTrades, &rec.WinRate,
			&rec.ProfitFactor, &rec.TotalProfit, &rec.MaxDrawdown, &rec.MaxDrawdownPct,
			&rec.SharpeRatio, &rec.RobustnessScore, &rec.AiReportJSON, &rec.CreatedAt,
		); err != nil {
			return nil, err
		}
		list = append(list, rec)
	}
	return list, nil
}

func (r *SQLiteRepository) Close() error {
	return r.db.Close()
}
