# WoA Toolbox

Nothing Phone (1)（spacewar / SM7325）の WoA（Windows on ARM）移行・復旧作業を
コマンドラインから GUI に寄せる Flutter デスクトップアプリ。
設計は [DESIGN.md](DESIGN.md) を参照。

## 構成

- `packages/woa_toolbox_core/` — UI 非依存の Dart コア。GPT 解析、デバイス検出
  （adb / fastboot は PATH 前提）、レイアウト判定、バックアップ manifest。
  GUI と MCP サーバーはこのコアだけを操作する。
- `app/` — Flutter GUI（Material 3、WebView なし、Windows / Linux）。
- `.github/workflows/build.yml` — CI: コアのテスト、アプリの analyze/test、
  Windows / Linux ビルド（成果物は Artifacts に上がる）。

## 実装フェーズ（DESIGN.md §10）

- **Phase 1（現在）** — 読み取り専用の基盤: デバイス検出、モード判定、
  GPT 解析（プライマリ/バックアップ分離・CRC 検証・実機セクタサイズ検出）、
  レイアウト表示、ログ。
- Phase 2 — 操作計画（Plan → Preview → Confirm → Execute）と書き込み。
- Phase 3 — MCP（読み取り＋計画 → ローカル IPC 承認 → execute_plan）。

## ローカルでの確認

```sh
cd packages/woa_toolbox_core && dart test
cd app && flutter analyze && flutter test
cd app && flutter build windows --release   # または linux
```
