# unity-cli-test-runner Architecture Decision Records

このディレクトリには unity-cli-test-runner 開発における意思決定・調査経緯を 記録するArchitecture Decision Record (ADR) 群を格納する。

## 一覧

| # | タイトル | Status |
|---|---|---|
| [0001](0001-migrate-from-unity-mcp-to-cli.md) | Unity MCP経由からCLI経由への移行 | Accepted |
| [0002](0002-playmode-invalidoperationexception-accumulation.md) | PlayModeのInvalidOperationException累積 | Resolved (2026-08-13) |
| [0003](0003-ensure-compile-clean-json-field-names.md) | ensure-compile-clean.shのJSONフィールド名の実機未検証 | Resolved (2026-08-21) |
| [0004](0004-domain-reload-transient-failures.md) | ドメインリロード未完了時の一時的失敗（接続断・list_tests 0件） | Accepted（一部対策はADR-0007へ切り出し） |
| [0005](0005-subagent-nested-invocation-completion-routing.md) | サブエージェントのネスト呼び出しで完了通知が親に届かない問題 | Resolved (2026-08-15) |
| [0006](0006-batch-test-execution.md) | 複数テスト一括実行のバッチ化 | Accepted (2026-08-13) |
| [0007](0007-domain-reload-transient-pipeline-unreachable.md) | ドメインリロード窓での過剰検知・過小検知への対策と`--json`未指定バグの修正 | Accepted (2026-08-21) |
| [0008](0008-mode-verification-even-when-fullname-explicit.md) | FullName明示時もMode裏取りを必須化（EditMode/PlayMode取り違え対策） | Accepted (2026-08-21) |
| [0009](0009-oneshot-retry-for-test-launch-calls.md) | テスト起動呼び出し自体への単発リトライ導入（起動直後の瞬断で毎回2倍コストになる問題の解消） | Accepted (2026-08-22) |
| [0010](0010-class-name-boundary-aware-matching.md) | クラス名解決時の部分一致誤検知（境界を考慮しないgrepによる別クラスの巻き込み） | Accepted (2026-08-22) |
| [0011](0011-ensure-compile-clean-inline-recovery.md) | ensure-compile-clean.shのポーリング予算超過に対するスクリプト内自動リカバリ | Accepted (2026-08-22) |
| [0012](0012-vendor-pipeline-internal-types.md) | `com.unity.pipeline` 0.6での`internal`化に伴う型のベンダリング | Accepted (2026-09-06) |
| [0013](0013-dialog-block-detection-in-compile-check-polling.md) | ensure-compile-clean.shへのダイアログブロック判別の移植（`.unity`/`.prefab`外部変更ダイアログによる誤ハング判定の解消） | Accepted (2026-09-06) |