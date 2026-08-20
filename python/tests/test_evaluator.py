import os
import sys
import math

# パス解決
_project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
_evaluator_dir = os.path.join(_project_root, "evaluator")
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)
if _evaluator_dir not in sys.path:
    sys.path.insert(0, _evaluator_dir)

try:
    from evaluator.analyzer import TradeAnalyzer, TradeRecord, TradeMetrics
    from evaluator.charts import ChartGenerator
    from evaluator.duckdb_backtest import RealtimeRegimeDetector
except ImportError:
    from analyzer import TradeAnalyzer, TradeRecord, TradeMetrics
    from charts import ChartGenerator
    from duckdb_backtest import RealtimeRegimeDetector


def test_trade_metrics_calculation():
    trades = [
        TradeRecord(ticket=1, symbol="USDJPY", action="BUY", lots=0.5, open_price=155.00, close_price=155.30, open_time="2026-08-20 10:00:00", close_time="2026-08-20 10:30:00", profit=15000.0, comment="AutoOrder_FibDow"),
        TradeRecord(ticket=2, symbol="USDJPY", action="SELL", lots=0.5, open_price=155.50, close_price=155.54, open_time="2026-08-20 11:00:00", close_time="2026-08-20 11:15:00", profit=-2000.0, comment="AutoOrder_FibDow"),
        TradeRecord(ticket=3, symbol="USDJPY", action="BUY", lots=0.5, open_price=155.10, close_price=155.60, open_time="2026-08-20 12:00:00", close_time="2026-08-20 12:45:00", profit=25000.0, comment="AutoOrder_FibDow"),
    ]
    
    analyzer = TradeAnalyzer(db_path=":memory:")
    metrics = analyzer.calculate_metrics(trades)
    
    assert metrics is not None
    assert metrics.total_trades == 3
    assert metrics.winning_trades == 2
    assert metrics.losing_trades == 1
    assert abs(metrics.win_rate - 66.7) < 0.1
    assert metrics.total_profit == 38000.0
    assert metrics.gross_profit == 40000.0
    assert metrics.gross_loss == 2000.0
    assert metrics.profit_factor == 20.0
    assert metrics.largest_win == 25000.0
    assert metrics.largest_loss == -2000.0


def test_chart_generator(tmp_path):
    output_dir = str(tmp_path / "reports")
    chart_gen = ChartGenerator(output_dir=output_dir)
    
    trades = [
        TradeRecord(ticket=1, symbol="USDJPY", action="BUY", lots=0.5, open_price=155.00, close_price=155.30, open_time="2026-08-20 10:00:00", close_time="2026-08-20 10:30:00", profit=15000.0, comment="AutoOrder_FibDow"),
        TradeRecord(ticket=2, symbol="USDJPY", action="SELL", lots=0.5, open_price=155.50, close_price=155.54, open_time="2026-08-20 11:00:00", close_time="2026-08-20 11:15:00", profit=-2000.0, comment="AutoOrder_FibDow"),
    ]
    
    metrics = TradeMetrics(
        total_trades=2,
        winning_trades=1,
        losing_trades=1,
        win_rate=50.0,
        total_profit=13000.0,
        gross_profit=15000.0,
        gross_loss=2000.0,
        profit_factor=7.5,
        max_drawdown=2000.0,
        max_drawdown_pct=2.0,
        avg_trade_profit=6500.0,
        largest_win=15000.0,
        largest_loss=-2000.0,
        trades=trades
    )
    
    svg_path = chart_gen.generate_equity_curve(trades, filename="test_equity.svg")
    assert os.path.exists(svg_path)
    with open(svg_path, "r", encoding="utf-8") as f:
        content = f.read()
        assert "<svg" in content

    html_path = chart_gen.generate_html_dashboard(metrics, "Test Evaluation", svg_path, filename="test_dashboard.html")
    assert os.path.exists(html_path)
    with open(html_path, "r", encoding="utf-8") as f:
        html_content = f.read()
        assert "13,000" in html_content
        assert "50.0%" in html_content


def test_duckdb_regime_detector():
    detector = RealtimeRegimeDetector(max_ticks=100)
    for i in range(35):
        detector.push_tick("USDJPY", 158.0 + (i * 0.02), 158.004 + (i * 0.02))
    
    diagnosis = detector.detect_regime("USDJPY")
    assert diagnosis is not None
    assert "regime" in diagnosis
    assert diagnosis["regime"] != "WARMUP_INSUFFICIENT_DATA"
    assert "recommendation" in diagnosis
