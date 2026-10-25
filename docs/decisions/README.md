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
| [0014](0014-mechanical-report-derivation.md) | テスト結果報告の機械導出化（サブエージェントの二重報告・楽観的幻覚への対策） | Accepted (2026-09-21) |
| [0015](0015-pipeline-0.7-only.md) | `com.unity.pipeline` 0.7.0-exp.1 への一本化とコンパイルエラー判定の一次情報の移動 | Accepted (2026-09-21) |
| [0016](0016-pipeline-0.8-only.md) | `com.unity.pipeline` 0.8.0-exp.1 への一本化と `*_status` のネイティブJSON化への追従 | Accepted (2026-10-04) |
| [0017](0017-skill-script-path-via-claude-skill-dir.md) | スキルのスクリプト参照を `${CLAUDE_SKILL_DIR}` 起点の絶対パス表記にする | Accepted (2026-10-04) |
| [0018](0018-move-plugin-to-subdirectory.md) | Claude Code プラグイン本体を `claude-plugin/` サブディレクトリへ移す | Accepted (2026-10-15) |
| [0019](0019-in-repo-test-project-and-e2e.md) | リポジトリ内に検証用 Unity プロジェクト（TestProject）と E2E 照合スクリプトを置く | Accepted (2026-10-15) |
| [0020](0020-exact-fullname-execution-via-batch.md) | 単一テスト・クラスの実行を、完全一致のバッチ実行に切り替える | Accepted (2026-10-15) |
| [0021](0021-stale-plugin-get-console-logs-report.md) | 「ensure-compile-clean.sh が get_console_logs を呼んで exit 2 で止まる」報告への対応 | Accepted (2026-10-15) |
| [0022](0022-playmode-filter-clue-check-testname-only.md) | PlayMode 実行の filter 文字列の整合性チェックを `testName` 指定時だけに限る | Accepted (2026-10-17) |
| [0023](0023-report-unity-cmd-failure-response.md) | `unity cmd` が一時的でない理由で失敗したとき、その応答を標準エラーに出す | Accepted (2026-10-17) |
| [0024](0024-version-aligned-with-pipeline.md) | プラグインと Unity 側パッケージの版番号を揃え、`com.unity.pipeline` の版に合わせる | Accepted (2026-10-24) |
| [0025](0025-pipeline-0.9-only.md) | `com.unity.pipeline` 0.9.x への一本化、コマンドのグループ化への追従と対象 Unity の限定 | Accepted (2026-10-24) |
| [0026](0026-parameterized-testcase-by-method-fullname.md) | 引数付きケースはメソッドの FullName でバッチ実行し、ケースの FullName は実行前に拒否する | Accepted (2026-10-25) |
