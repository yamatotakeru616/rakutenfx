---
name: mt4-trading-pipeline
description: 楽天MT4デモトレード、リアルタイム価格取得、Rust製シグナル・永続化ゲートウェイ、Python/Gemini取引評価Agent、Discord通知のパイプライン設計・運用スキル
---

# MT4 Trading Pipeline Skill

本スキルは、楽天MT4（デモ口座）を活用した自動売買・リアルタイムデータ連携・ログ永続化・AI評価パイプラインの標準仕様と運用手順を定めます。

---

## 1. システム全体構成

```text
[楽天MT4 / EA (MQL4)]
       ↕ (TCP / ZeroMQ JSON通信)
[Rust Gateway & Signal Engine] ── (WAL Mode Write) ──> [SQLite: trade_pipeline.db]
                                                               │
                                                       (SQL Read / Batch)
                                                               ↓
                                                [Python 評価 & AI Agent]
                                                               ↓
                                                   [Discord Webhook 通知]
```

---

## 2. 通信プロトコル仕様 (JSON over TCP/ZeroMQ)

### 2.1 ティックデータ送信 (MT4 -> Rust)

```json
{
  "type": "TICK",
  "symbol": "USDJPY",
  "bid": 155.320,
  "ask": 155.324,
  "time": "2026-08-19 17:30:00",
  "volume": 12
}
```

### 2.2 売買シグナル返送 (Rust -> MT4)

```json
{
  "type": "SIGNAL",
  "action": "BUY",
  "symbol": "USDJPY",
  "lot": 0.1,
  "stop_loss_pips": 20.0,
  "take_profit_pips": 40.0,
  "reason": "SMA_GOLDEN_CROSS + RSI_OVERSOLD"
}
```

### 2.3 約定・決済ログ送信 (MT4 -> Rust)

```json
{
  "type": "TRADE_LOG",
  "ticket": 12345678,
  "symbol": "USDJPY",
  "action": "BUY",
  "lots": 0.1,
  "open_price": 155.324,
  "close_price": 155.724,
  "open_time": "2026-08-19 17:30:05",
  "close_time": "2026-08-19 18:15:20",
  "profit": 4000.0,
  "comment": "AutoTrade_Signal_01"
}
```

---

## 3. SQLite データベーススキーマ (`trade_pipeline.db`)

- **`ticks`**: 受信した全ティック価格データ（日時、シンボル、Bid、Ask、出来高）
- **`signals`**: 生成された売買シグナル履歴（日時、シンボル、アクション、ロット、SL/TP、判定根拠）
- **`trades`**: 約定・決済されたトレードログ（チケット番号、損益、オープン/クローズ日時・価格）

---

## 4. 各コンポーネントの責務と運用

1. **`crates/gateway` (Rust)**:
   - 高速TCP/ZeroMQソケット待受（ノンブロッキング）
   - テクニカル指標（SMA, EMA, RSI, ATR）のインメモリ計算
   - リスク管理（最大ポジション数制限、急変動時のエントリー制限）
   - SQLiteへの高速非同期バッチ書き込み
   - 仮想MT4エミュレータ（オフライン検証用）
2. **`mql4/RakutenTradeAgent.mq4`**:
   - 楽天MT4チャートにアタッチして動作
   - `OnTick()` でティック送信 ＆ シグナル受信
   - `OrderSend()` / `OrderClose()` によるデモ口座発注
3. **`python/evaluator` (Python + Gemini API)**:
   - 勝率、プロフィットファクター(PF)、最大ドローダウン(MaxDD)、期待値計算
   - 収益曲線 (Equity Curve) チャートの画像生成 (`charts.py`)
   - Gemini API によるトレード勝因・敗因分析レポート生成
   - Discord Webhook によるリッチEmbed・チャート画像通知
