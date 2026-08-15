# unity-cli-test-runner Architecture Decision Records

このディレクトリには unity-cli-test-runner 開発における意思決定・調査経緯を 記録するArchitecture Decision Record (ADR) 群を格納する。

## 一覧

| # | タイトル | Status |
|---|---|---|
| [0001](0001-migrate-from-unity-mcp-to-cli.md) | Unity MCP経由からCLI経由への移行 | Accepted |
| [0002](0002-playmode-invalidoperationexception-accumulation.md) | PlayModeのInvalidOperationException累積 | Resolved (2026-08-13) |
| [0003](0003-ensure-compile-clean-json-field-names.md) | ensure-compile-clean.shのJSONフィールド名の実機未検証 | Accepted（実機確認待ちの申し送り） |
| [0004](0004-domain-reload-transient-failures.md) | ドメインリロード未完了時の一時的失敗（接続断・list_tests 0件） | Accepted |
| [0005](0005-subagent-nested-invocation-completion-routing.md) | サブエージェントのネスト呼び出しで完了通知が親に届かない問題 | Resolved (2026-08-15) |
| [0006](0006-batch-test-execution.md) | 複数テスト一括実行のバッチ化 | Accepted (2026-08-13) |