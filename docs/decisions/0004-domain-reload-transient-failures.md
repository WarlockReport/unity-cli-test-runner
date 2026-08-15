# ADR-0004: ドメインリロード未完了時の一時的失敗（接続断・list_tests 0件）

## Status

Accepted

## Context

前提: [ADR-0001](0001-migrate-from-unity-mcp-to-cli.md) によりCLI経由に移行済み。

### 事例A: 「No Unity Editor instances found with reachable Pipeline servers」の一時的な接続断

実装エージェントで複数回発生した。
いずれも `.cs` ファイル編集直後（コンパイル/ドメインリロード中と思われるタイミング）にunity-test-runnerを呼んで起きており、
コントローラー側で少し待ってから `unity cmd editor_status` を叩くと ready に戻っていて、再試行で解決した。

SKILL.mdの「コンパイル状態の確定」（`ensure-compile-clean.sh` でコンパイル確定してからテスト対象解決へ進む手順）が 徹底されていれば避けられた可能性がある。
実装エージェント側がこの手順をどこまで踏んでいたかは**不明**。

### 事例B: list_testsが一時的に0件ヒット

ドメインリロード未完了のタイミングで `list_tests` を呼んで0件になり、再試行で解決した。

事例Aと同梱で、コンパイル確定ステップの徹底不足の可能性がある。

## Decision

両事例とも根本原因は同一（ドメインリロード/コンパイル未完了のタイミングでの呼び出し）と考えられるため、
`ensure-compile-clean.sh` でコンパイル確定してからテスト対象解決・実行に進む手順（SKILL.mdの「コンパイル状態の確定」）を徹底する。

## Consequences

フィールド名・タイムアウト値の実機未検証事項については
[ADR-0003](0003-ensure-compile-clean-json-field-names.md) を参照。