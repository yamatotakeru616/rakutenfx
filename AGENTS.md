# ユーザー憲法（Constitution & Operational Directives）- Go言語移行版

本ファイルは「楽天FX攻略20260819」プロジェクトにおける開発環境、技術選定方針、およびシステム構築における思考・行動規範を定義した最高位の基本仕様書です。

---

## 1. ユーザー環境 & 実行基盤

- **メイン環境**: Google AI Studio BUILD, Antigravity IDE
- **ハードウェア環境**: Windows 11 / NVIDIA GeForce RTX 3050 Ti (VRAM 4GB)
- **プログラム主要言語**: **Go (Golang 1.22+)** による超高速・省メモリ・単一バイナリ設計
- **フレームワーク / DB**: Gin / SQLite (`modernc.org/sqlite` によるCGOレス設計)
- **デプロイメント**: `//go:embed` を用いた完全単一バイナリ & Docker (Scratch/Distroless)

---

## 2. 思考・対話規範（ゴッドモード & スカウト）

### 🔍 スカウトによる徹底調査
- 表面的な情報で満足せず、Go標準ライブラリ、Gin公式、`modernc.org/sqlite`の内部挙動まで徹底調査する。

### 📊 情報の厳密な三層分離
- **【事実 (Fact)】**: Python依存環境（PyTorch/DuckDB等）はメモリ消費量が数百MBに達するが、Go+SQLiteコンパイル済みバイナリは起動時メモリ約15MB~30MBで動作する。
- **【推測 (Inference)】**: CGOレスの `modernc.org/sqlite` を採用することで、Windows/Linux間でのクロスコンパイルの手間が完全に撤廃される **[要確認]**。
- **【意見 (Opinion)】**: フロントエンド資産を `//go:embed` でバイナリに焼き付けることで、デプロイ手順が単一ファイルの配置のみとなり、Windowsタスクスケジューラでの自動起動におけるパス解決トラブルを壊滅させることができる。

### 🎯 本質的な深掘り（なぜ？×3回）
- **1. なぜPythonからGoに移行するのか？**
  - Pythonスクリプト起動のオーバーヘッドとメモリ圧迫（RTX 3050 Ti VRAM/RAMの制約）を解消し、応答速度をミリ秒以下にするため。
- **2. なぜCGOを使わない `modernc.org/sqlite` なのか？**
  - GCCなどのCコンパイラ依存を排除し、`GOOS=windows` や `GOOS=linux` のクロスコンパイルを純粋なGoツールチェーンのみで簡潔に行うため。
- **3. なぜ `//go:embed` による単一バイナリ化を行うのか？**
  - 静的ファイルの参照切れ事故を防ぎ、単一エグゼクティブファイルを置くだけでWeb UIとAPIサーバーが完結する自己完結型運用を実現するため。

---

## 3. Goアーキテクチャ設計原則 (Clean Architecture)

```
cmd/
  server/
    main.go              # エントリーポイント (go:embed 統合)
internal/
  domain/                # エンティティ・ドメインモデル (Trade, Regime, Signal)
  usecase/               # ビジネスロジック (AI評価インターフェース, シグナル処理)
  infrastructure/
    persistence/         # SQLiteリポジトリ実装 (modernc.org/sqlite)
    gateway/             # Rust TCP Gateway通信クライアント
  handler/
    http/                # Gin REST API ハンドラー & リアルタイムルーティング
web/
  static/                # HTML/CSS/JS/PWAアセット (go:embed 対象)
```

---

## 4. 自己採点とブラッシュアップ

- **自己採点**: **92 / 100 点**
- **理由**: CGOフリーなSQLite選定と Gin + `go:embed` による単一バイナリ構想は完璧だが、Pythonで実施していたGPU依存処理（PyTorch画像解析など）との境界設計（外部プロセス連携または軽量Go推論エンジン化）について追加検証が必要なため。

### 💡 具体的な改善案3つ
1. **SQLite WALモード ＆ 接続プール最適化**: `modernc.org/sqlite` 接続時に WAL (Write-Ahead Logging) モードを有効化し、高頻度書き込み時のロック競合を回避する。
2. **ONNX Runtime (Go binding) または HTTP IPC によるAI推論分離**: Pythonの画像判定が必要な場合、Go側からgRPC/HTTP経由で軽量呼び出しを行う非同期キルスイッチ構成の確立。
3. **Gin Gzipミドルウェア ＆ WebFSキャッシング**: `go:embed` で埋め込んだ静的コンテンツに対して Gin の gzip 圧縮と Cache-Control ヘッダー付与を行い、Web UI表示速度を最速化する。