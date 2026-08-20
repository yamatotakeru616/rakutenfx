import sqlite3
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional


@dataclass
class TradeRecord:
    ticket: int
    symbol: str
    action: str
    lots: float
    open_price: float
    close_price: Optional[float]
    open_time: str
    close_time: Optional[str]
    profit: float
    comment: Optional[str]


@dataclass
class TradeMetrics:
    total_trades: int
    winning_trades: int
    losing_trades: int
    win_rate: float
    total_profit: float
    gross_profit: float
    gross_loss: float
    profit_factor: float
    max_drawdown: float
    max_drawdown_pct: float
    avg_trade_profit: float
    largest_win: float
    largest_loss: float
    trades: List[TradeRecord]


class TradeAnalyzer:
    def __init__(self, db_path: str = "trade_pipeline.db"):
        self.db_path = db_path

    def load_trades(self, limit: Optional[int] = None) -> List[TradeRecord]:
        try:
            conn = sqlite3.connect(self.db_path)
            cursor = conn.cursor()
            query = """
                SELECT ticket, symbol, action, lots, open_price, close_price, open_time, close_time, profit, comment
                FROM trades
                WHERE close_time IS NOT NULL
                ORDER BY close_time ASC
            """
            if limit:
                query += f" LIMIT {limit}"

            cursor.execute(query)
            rows = cursor.fetchall()
            conn.close()
        except Exception as e:
            # テーブルが存在しないかロックされている場合は空リスト
            return []

        trades = []
        for r in rows:
            trades.append(
                TradeRecord(
                    ticket=r[0],
                    symbol=r[1],
                    action=r[2],
                    lots=r[3],
                    open_price=r[4],
                    close_price=r[5],
                    open_time=r[6],
                    close_time=r[7],
                    profit=r[8],
                    comment=r[9],
                )
            )
        return trades

    def calculate_metrics(self, trades: Optional[List[TradeRecord]] = None) -> Optional[TradeMetrics]:
        if trades is None:
            trades = self.load_trades()

        if not trades:
            return None

        total_trades = len(trades)
        wins = [t for t in trades if t.profit > 0]
        losses = [t for t in trades if t.profit < 0]

        winning_trades = len(wins)
        losing_trades = len(losses)
        win_rate = (winning_trades / total_trades) * 100.0 if total_trades > 0 else 0.0

        total_profit = sum(t.profit for t in trades)
        gross_profit = sum(t.profit for t in wins) if wins else 0.0
        gross_loss = abs(sum(t.profit for t in losses)) if losses else 0.0

        profit_factor = (gross_profit / gross_loss) if gross_loss > 0 else (999.0 if gross_profit > 0 else 0.0)

        # Max Drawdown 計算
        cumulative_profit = 0.0
        peak = 0.0
        max_drawdown = 0.0

        for t in trades:
            cumulative_profit += t.profit
            if cumulative_profit > peak:
                peak = cumulative_profit
            drawdown = peak - cumulative_profit
            if drawdown > max_drawdown:
                max_drawdown = drawdown

        max_drawdown_pct = (max_drawdown / (peak + 100000.0)) * 100.0 if peak > 0 else 0.0
        avg_trade_profit = (total_profit / total_trades) if total_trades > 0 else 0.0
        largest_win = max([t.profit for t in wins], default=0.0)
        largest_loss = min([t.profit for t in losses], default=0.0)

        return TradeMetrics(
            total_trades=total_trades,
            winning_trades=winning_trades,
            losing_trades=losing_trades,
            win_rate=win_rate,
            total_profit=total_profit,
            gross_profit=gross_profit,
            gross_loss=gross_loss,
            profit_factor=profit_factor,
            max_drawdown=max_drawdown,
            max_drawdown_pct=max_drawdown_pct,
            avg_trade_profit=avg_trade_profit,
            largest_win=largest_win,
            largest_loss=largest_loss,
            trades=trades,
        )
