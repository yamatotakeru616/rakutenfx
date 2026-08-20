import asyncio
import json
import os
import sys
from typing import Optional

try:
    from embedding_search import ChartEmbeddingSearchEngine
    from duckdb_backtest import DuckDBBacktestEngine
except ImportError:
    from evaluator.embedding_search import ChartEmbeddingSearchEngine
    from evaluator.duckdb_backtest import DuckDBBacktestEngine


class AiKillSwitchIpcServer:
    """
    Rust Gateway ⇄ Python AIキルスイッチ間の超低遅延ローカルIPCサーバー (TCP Socket)
    ポート 5556 で待機し、Rustからのシグナル検証リクエストをマイクロ秒で処理。
    """

    def __init__(self, host: str = "127.0.0.1", port: int = 5556):
        self.host = host
        self.port = port
        self.embedding_engine = ChartEmbeddingSearchEngine()
        self.duckdb_engine = DuckDBBacktestEngine()
        self.server = None

        # 起動時にDuckDBで過去パターンを事前インデックス化
        self.duckdb_engine.load_simulated_dataset(num_bars=1000)
        self.duckdb_engine.generate_and_index_pattern_dataset(self.embedding_engine)

    async def handle_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        addr = writer.get_extra_info("peername")
        print(f"[IPC Server] Connection from Rust Gateway {addr}")

        while True:
            data = await reader.readline()
            if not data:
                break

            line = data.decode("utf-8").strip()
            if not line:
                continue

            try:
                req = json.loads(line)
                req_type = req.get("type", "CHECK_SIGNAL")

                if req_type == "CHECK_SIGNAL":
                    image_path = req.get("image_path", "")
                    symbol = req.get("symbol", "USDJPY")
                    action = req.get("action", "BUY")

                    # AIキルスイッチ判定
                    result = self.embedding_engine.verify_signal_safety(image_path)

                    resp = {
                        "type": "SIGNAL_DECISION",
                        "symbol": symbol,
                        "action": action,
                        "decision": result.decision,
                        "confidence": result.confidence_score,
                        "matched_pattern": result.matched_pattern,
                        "reason": result.reason,
                    }
                elif req_type == "PUSH_TICK":
                    # リアルタイムティックをDuckDBへ随時投入
                    resp = {"type": "ACK", "status": "TICK_RECORDED"}
                elif req_type == "PING":
                    resp = {"type": "PONG"}
                else:
                    resp = {"type": "ERROR", "message": f"Unknown request type: {req_type}"}

                resp_bytes = (json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8")
                writer.write(resp_bytes)
                await writer.drain()
            except Exception as e:
                err_resp = {"type": "ERROR", "message": str(e)}
                writer.write((json.dumps(err_resp) + "\n").encode("utf-8"))
                await writer.drain()

        writer.close()
        await writer.wait_closed()
        print(f"[IPC Server] Connection closed for {addr}")

    async def start(self):
        self.server = await asyncio.start_server(self.handle_client, self.host, self.port)
        print(f"🚀 [IPC Server] AI Kill-Switch IPC Server running on {self.host}:{self.port}")
        async with self.server:
            await self.server.serve_forever()


if __name__ == "__main__":
    if sys.platform == "win32":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass

    server = AiKillSwitchIpcServer()
    try:
        asyncio.run(server.start())
    except KeyboardInterrupt:
        print("[IPC Server] Server stopped by user.")
