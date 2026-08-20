# 🚀 Rakuten MT4 AI Quant Trading Pipeline (2026)

[![Rust](https://img.shields.io/badge/Rust-1.80+-orange.svg?logo=rust&logoColor=white)](https://www.rust-lang.org/)
[![MQL4](https://img.shields.io/badge/MetaTrader_4-MQL4_EA-blue.svg?logo=metaquotes&logoColor=white)](https://www.metatrader4.com/)
[![Python](https://img.shields.io/badge/Python-3.12+-3776AB.svg?logo=python&logoColor=white)](https://www.python.org/)
[![DuckDB](https://img.shields.io/badge/DuckDB-OLAP_Engine-FFF000.svg?logo=duckdb&logoColor=black)](https://duckdb.org/)
[![Gemini 3.6](https://img.shields.io/badge/Gemini_3.6-Multimodal_Quant_AI-8E75C2.svg?logo=google&logoColor=white)](https://ai.google.dev/)
[![Hardware](https://img.shields.io/badge/GPU-RTX_3050_Ti_DirectML-76B900.svg?logo=nvidia&logoColor=white)](https://www.nvidia.com/)
[![Dashboard](https://img.shields.io/badge/Live_Dashboard-GitHub_Pages-00F5FF.svg?logo=githubpages&logoColor=black)](https://yamatotakeru616.github.io/rakutenfx/)
[![CI](https://github.com/yamatotakeru616/rakutenfx/actions/workflows/ci.yml/badge.svg)](https://github.com/yamatotakeru616/rakutenfx/actions/workflows/ci.yml)

> 🌐 **[リアルタイム AIクオンツ ライブダッシュボードはこちら (GitHub Pages)](https://yamatotakeru616.github.io/rakutenfx/)**

楽天MT4 / デモ口座を起点とした、**Rust超高速シグナルエンジン ⇄ MQL4可視化・発注 ⇄ DuckDBインメモリOLAPバックテスト ⇄ RTX 3050Ti 画像埋め込みAIキルスイッチ ⇄ Gemini 3.6自律クオンツチューナー** を一気通貫で統合した次世代自動売買システムです。

---

## 🏛️ 全体アーキテクチャと自律連携フロー

```mermaid
flowchart TD
    subgraph Market ["📊 楽天FX / MT4 (MQL4 EA)"]
        MT4[RakutenTradeAgent.mq4]
        HUD["プロ仕様リアルタイムHUD常時表示<br/>(Regime / Kill-Switch / Risk)"]
        Overlay["フィボナッチ帯・ダウライン・矢印自動描画"]
        Screenshot["WindowScreenShot()<br/>エントリー時チャート自動撮影"]
        MT4 --- HUD
        MT4 --- Overlay
        MT4 --- Screenshot
    end

    subgraph RustEngine ["⚡ Rust Ultra-Fast Gateway (Port 5555)"]
        Server[Gateway TCP Server]
        BarGen["M1/M5 インメモリバー生成器<br/>(BarGenerator)"]
        DowDetector["確定足ダウ理論トレンド転換検知<br/>(戻り高値ブレイク判定)"]
        Sizing["極小SL逆算ロットサイジング<br/>(固定2,000円リスク)"]
        Server --> BarGen --> DowDetector --> Sizing
    end

    subgraph PythonAI ["🧠 Python 3.12 ＆ Local AI / OLAP (Port 5556)"]
        IPC[IPC Server: ipc_server.py]
        KillSwitch["RTX 3050Ti 画像埋め込み検索<br/>(AIキルスイッチ: embedding_search.py)"]
        DuckDB["DuckDB 0.00ms OLAPバックテスト ＆<br/>リアルタイムレジーム検知 (duckdb_backtest.py)"]
        GeminiTuner["週次 Gemini 3.6 自律チューナー<br/>(config.toml 自動最適化)"]
        Dashboard["マルチモーダルHTMLダッシュボード<br/>(artifacts/reports/dashboard.html)"]
        IPC --- KillSwitch
        IPC --- DuckDB
        IPC --- GeminiTuner
        IPC --- Dashboard
    end

    MT4 <-->|1. 毎ティック送信 ＆ シグナル受信 (TCP)| Server
    Server <-->|2. シグナル承認/拒絶キルスイッチ (Local IPC)| IPC
    Screenshot -.->|3. チャート画像連携| KillSwitch
    Screenshot -.->|4. マルチモーダル診断| Dashboard
```

---

## 📐 コア戦略：フィボナッチ × ダウ理論「極小損切り（Micro-SL）」手法

詳細は [フィボナッチ手法.md](フィボナッチ手法.md) を参照。

### 🌟 哲学：なぜ「極小損切り × 爆発的リワード」が実現するのか
上位足（1時間足）のフィボナッチ反発候補（**38.2% / 50.0% / 61.8%**）に価格が到達した際、**先回り指値（逆張り）を一切せず**、下位足（1分足）に切り替えて**直近戻り高値を確定足で上抜けるダウ理論トレンド転換**を待ちます。

### 📊 損切り幅とリターンの比較（USD/JPY 許容損失2,000円固定時）

| 手法・エントリー | 損切り幅 (SL) | ロット数 (Lot) | 獲得利幅 (TP: 30pips) | 獲得利益額 | リスクリワード (RR) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| 従来の先回り指値 | 20.0 pips | 0.10 Lot (1万通貨) | +30.0 pips | +3,000 円 | 1 : 1.5 |
| **本手法（下位足ダウ転換）** | **4.0 pips** | **0.50 Lot (5万通貨)** | **+30.0 pips** | **+15,000 円** | **1 : 7.5** |

$$\text{Lot Size} = \frac{\text{許容損失額 (2,000円)}}{\text{SL幅 (pips)} \times \text{1pipあたり価値 (1,000円/Lot)}}$$

損切り幅を4pipsに絞ることでロットを5倍に引き上げ、**リスク（2,000円）は変えずに利益を5倍（15,000円）に増幅**します。

---

## 🛠️ 各モジュールの特徴

### 1. Rust Gateway (`crates/gateway`)
- **超低遅延非同期処理**: Tokio による非同期TCPソケット通信。
- **インメモリバー合成 (`bar_generator.rs`)**: ティック列からリアルタイムにM1バーを合成し、終値確定時の戻り高値ブレイク（ダウ転換）を自律判定。
- **動的ポジションサイジング (`strategy.rs`)**: SLまでの距離からミリ秒で発注Lot数を逆算。
- **AIインターロッククライアント (`ai_client.rs`)**: 発注直前にPython AIキルスイッチへ問い合わせ、安全性を検証。

### 2. MQL4 EA (`mql4/RakutenTradeAgent.mq4`)
- **プロ仕様HUD常時表示**: チャート画面左上に相場レジーム、AIキルスイッチ状態、リスク額をネオンカラーでリアルタイム描画。
- **フィボナッチ＆ダウ自動描画**: FR 38.2%/50.0%/61.8%ラインと直近サポレジを自動オーバーレイ。
- **エントリー時自動スクリーンショット**: 約定瞬間のチャート画像を `MQL4/Files/trades/ticket_XXXXX.png` に自動保存。

### 3. DuckDB ミリ秒OLAPエンジン (`python/evaluator/duckdb_backtest.py`)
- **0.00ms ベクトル化スキャン**: 数百万行の過去バーからフィボナッチ押し目＆ダウブレイクアウトセットアップをミリ秒以下で集計。
- **リアルタイムレジーム検知 (`RealtimeRegimeDetector`)**: 最新1,000ティックの統計分布から `STRONG_TREND_BULL` / `HIGH_VOLATILITY_EXPANSION` 等をリアルタイム判定。

### 4. RTX 3050Ti 画像埋め込みAIキルスイッチ (`python/evaluator/embedding_search.py`)
- **潜在特徴量抽出**: MobileNetV3 / DirectML / numpy によるチャート画像ベクトル化。
- **コサイン類似度照合**: 現在のチャートが過去の「ダマシ・負けパターン」と類似度85%以上の場合は即座に発注を強制遮断（`REJECT_KILL_SWITCH`）。

### 5. 週次 Gemini 3.6 自律チューナー (`python/evaluator/auto_tuner.py`)
- 過去1週間の取引実績をGemini 3.6がクオンツ診断し、次週の最適スイング期間・RSI閾値・極小SL下限を算出して `config.toml` を自動書き換え。

### 6. マルチモーダルHTMLダッシュボード (`python/evaluator/charts.py`)
- 資産推移曲線（Cumulative Equity）、トレードKPI、Gemini AI診断レポート、各トレードのチャート画像を一覧表示するダークテーマダッシュボード（`artifacts/reports/dashboard.html`）を自動生成。

---

## 📁 ディレクトリ構成

```text
.
├── config.toml                       # システム統合・最適化設定ファイル
├── フィボナッチ手法.md               # トレード手法完全攻略マニュアル
├── 今後の開発予定.md                 # 開発フェーズ＆マイルストーン
├── crates/
│   └── gateway/                      # Rust 超高速 Gateway
│       ├── Cargo.toml
│       └── src/
│           ├── main.rs
│           ├── server.rs             # MT4 TCP サーバー
│           ├── strategy.rs           # シグナル＆極小SLサイジング
│           ├── bar_generator.rs      # M1バー合成 ＆ ダウ転換検知
│           ├── ai_client.rs          # AIキルスイッチ IPCクライアント
│           ├── indicators.rs         # フィボナッチ/ATR/SMA/RSI
│           ├── emulator.rs           # シナリオ波形エミュレータ
│           ├── db.rs                 # SQLite WAL永続化
│           └── models.rs
├── mql4/
│   └── RakutenTradeAgent.mq4         # MT4 EA (HUD・描画・自動撮影)
├── python/
│   └── evaluator/                    # AIクオンツ・OLAP基盤
│       ├── ipc_server.py             # Rust-Python間 IPCサーバー (Port 5556)
│       ├── embedding_search.py       # RTX 3050Ti 画像キルスイッチ
│       ├── duckdb_backtest.py        # DuckDB ミリ秒OLAP ＆ レジーム検知
│       ├── auto_tuner.py             # 週次 Gemini 3.6 自律チューナー
│       ├── ai_agent.py               # Gemini マルチモーダル画像診断
│       ├── charts.py                 # HTMLダッシュボード生成
│       ├── analyzer.py               # トレード統計集計
│       ├── notifier.py               # Discord 通知エンジン
│       └── main.py
└── .github/
    └── workflows/
        └── ci.yml                    # GitHub Actions CI (Rust & Python)
```

---

## ⚡ クイックスタート

### 1. 前提環境
- **OS**: Windows 11 (推奨)
- **Rust**: 1.80+ (`cargo test --workspace`)
- **Python**: 3.12+ (`pip install -r python/evaluator/requirements.txt duckdb numpy pillow`)
- **MT4**: 楽天MT4 / 各種MT4デモ口座

### 2. Rust Gateway のビルド＆起動
```powershell
# テストの実行
cargo test --workspace

# サーバー起動
cargo run --bin gateway -- serve
```

### 3. Python AIキルスイッチ IPCサーバーの起動
```powershell
python python/evaluator/ipc_server.py
```

### 4. 週次 Gemini 自律パラメータチューニングの実行
```powershell
python python/evaluator/auto_tuner.py
```

### 5. MT4 EA の設定
1. `mql4/RakutenTradeAgent.mq4` を MT4 の `MQL4/Experts/` フォルダへ配置しコンパイル。
2. MT4 の「ツール」➔「オプション」➔「エキスパートアドバイザ」で **「DLLの使用を許可する」** にチェック。
3. チャート（USDJPY M5/M15等）に適用すると、HUDダッシュボードとフィボナッチ帯が自動描画されます。

---

## 📜 ライセンス
MIT License - Copyright (c) 2026 yamatotakeru616
