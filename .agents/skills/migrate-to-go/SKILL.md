---
name: migrate-to-go
description: 既存プロジェクト（Python/TypeScript/JavaScript/PHP等）をGo言語（Golang）の単一バイナリ・超高速・省メモリ設計へ安全に書き換え・移行するための自律開発スキル。
---

# Go言語移行・書き換えスキル (Migrate to Go)

既存のWebアプリケーションやバックエンドサービスを、**Go言語（Golang）の堅牢・高速・単一バイナリ設計**へ安全かつ段階的にリファクタリング・移行するための体系的ガイドラインです。

---

## 🎯 移行の基本方針 & 推奨アーキテクチャ

1. **Goファースト・単一バイナリ化**:
   - フロントエンド静的アセット（HTML/CSS/JS/画像等）は `//go:embed` でGoバイナリに内包。
   - 外部ランタイム（Node.js, Python等）なしで `.exe` 単体（または軽量Docker）で即座に動作する構成にする。
2. **Webフレームワーク & 構成**:
   - 推奨FW: `github.com/gin-gonic/gin`（または標準 `net/http`）
   - 推奨DB: `modernc.org/sqlite`（CGO不要の純Go製SQLite）または `database/sql` / `gorm.io/gorm`
3. **安全な段階的移行**:
   - 既存のAPIインターフェース・エンドポイント・URLルーティング・レスポンス形式（JSON仕様）を完全に維持する。
   - 既存のDBスキーマやデータ定義を壊さず、Go構造体（struct）へマッピングする。

---

## 🗺️ 技術スタックの対応マッピング表

| 移行元 (Source) | 移行先 (Go Equivalent) | 備考 |
| :--- | :--- | :--- |
| **Python FastAPI / Flask** | `gin-gonic/gin` または `net/http` | 高速なJSON APIハンドラーへ変換 |
| **Node.js Express / Fastify** | `gin-gonic/gin` | ミドルウェア構成もGoのGin Handlerへ変換 |
| **SQLAlchemy / Prisma / TypeORM** | `gorm.io/gorm` または `database/sql` / `sqlx` | structタグ `gorm:"..." json:"..."` で定義 |
| **Pydantic / Zod** | Go `struct` + `binding:"required"` | バリデーションタグで安全に型安全化 |
| **dotenv (.env)** | `joho/godotenv` または `os.Getenv` | 設定の外部読み込み |
| **HTML / CSS / JS (フロント)** | `embed.FS` + `r.StaticFS` | 単一バイナリ内にそのままバンドル |

---

## 📋 移行作業の標準フェーズ手順

### フェーズ 1: 現状コードの調査 & Go環境初期化

1. **既存コードの解析**:
   - ルーティング定義、APIエンドポイント一覧、リクエスト/レスポンス型を特定。
   - データベーステーブル定義およびモデルを特定。

2. **Goモジュールの初期化**:

   ```bash
   go mod init <プロジェクト名>
   go get -u github.com/gin-gonic/gin
   go get -u modernc.org/sqlite
   ```

3. **標準ディレクトリ構造の作成**:

   ```text
   ├── cmd/
   │   └── server/
   │       └── main.go       # エントリポイント
   ├── internal/
   │   ├── handler/          # HTTPハンドラー (API)
   │   ├── model/            # データ構造体・エンティティ
   │   ├── repository/       # DBアクセス層
   │   └── service/          # ビジネスロジック
   ├── public/               # HTML/CSS/JS (embed対象)
   ├── data/                 # SQLite DB等のデータ保存先
   ├── go.mod
   └── go.sum
   ```

### フェーズ 2: データモデル & DBアクセス層の実装

- 既存のテーブル構造に合わせて `internal/model/` に Go の `struct` を定義。
- `internal/repository/` に CRUD 操作用の関数を実装。

### フェーズ 3: ハンドラー & ルーティングの移植

- 既存の全エンドポイントを `internal/handler/` に移植。
- リクエストのバインド（`c.ShouldBindJSON(&req)`）とレスポンス返却（`c.JSON(http.StatusOK, res)`）を実装。

### フェーズ 4: 静的アセットの単一バイナリ化 (`//go:embed`)

```go
//go:embed public/*
var staticFS embed.FS

func SetupRouter() *gin.Engine {
    r := gin.Default()
    subFS, _ := fs.Sub(staticFS, "public")
    r.StaticFS("/public", http.FS(subFS))
    // ルートアクセスで index.html を返却
    return r
}
```

### フェーズ 5: ビルド・検証 & ドキュメント更新

- `go build -o <プロジェクト名>.exe ./cmd/server` でビルド確認。
- `go test ./...` で単体テスト実行。
- `AGENTS.md` および `今後の開発予定.md` をGo構成に合わせて最新化。

---

## 🛡️ ユーザー憲法（安全ルール）の遵守

- **Windows環境互換**: パス結合には必ず `filepath.Join` を使用し、スラッシュ直書きを避ける。
- **Git管理**: 移行前・各フェーズ完了ごとに意味のあるコミットを作成する。
- **クリーン設計**: 不要になった移行元の古い一時ファイルは確認の上整理する。
