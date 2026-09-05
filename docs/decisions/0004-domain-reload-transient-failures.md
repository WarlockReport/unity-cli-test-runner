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

### 追記 (2026-08-21) — 上記Decisionは不十分だったことが判明

その後の実機検証で、上記Decisionの前提（「`ensure-compile-clean.sh` を徹底すればよい」）自体が不十分であることが分かった。
ポーリング中の一時切断1回で即ハング扱いにする過剰検知（本ADRの事例A）に加えて、`recompile_status` が `completed`/`up_to_date` を報告した**直後**に同じ理由（ドメインリロード）でPipelineサーバーが一時的にダウンするケースを観測した。
つまり `recompile_status: completed` は単独では安全な完了シグナルにならず、`ensure-compile-clean.sh` を徹底して呼んでいても先へ進んでしまう（過小検知）レースが起こりうる。

この2つの問題（過剰検知・過小検知）への具体的な対策は
[ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) に切り出した。本ADRの事例A・Bの観測事実そのものは引き続き有効な記録として残すが、対策の実装詳細はADR-0007を参照すること。
### 追記 (2026-09-06) — 0.6での関連する変更

`com.unity.pipeline` 0.6.0-exp.1 に、本ADRが扱う「ドメインリロード窓での一時的失敗」と関連する変更が2つ入った。

1. **busy応答の追加**
   コマンドを実行できない状態を、サーバーが HTTP 503 と構造化エンベロープ
   （`error="Server Busy"` / `status="busy"` / `retryable=true` / `busyReason`）で返すようになった。
   `busyReason` は `"settling"`（エディタ起動直後のインポート・コンパイル中）と
   `"blocked_by_dialog"`（モーダルダイアログがメインスレッドを塞いでいる）。
   本プラグインのカスタムコマンドはすべて `MainThreadRequired = true` なのでどちらにも該当しうる。
   対策は [ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) の追記を参照。

2. **`CommandRegistry` のTypeCache探索復元**（UUM-149991）
   > Fixed `CommandRegistry` staying on reflection-based command discovery after exiting Play Mode
   > without a domain reload; `PipelineServerStartup` now restores TypeCache discovery on `EnteredEditMode`.

   0.5以前は「ドメインリロードを伴わずにPlay Modeを抜けた後、コマンド探索がreflectionベースのまま留まる」状態になりえた。
   PlayModeバッチ実行を多用する本プラグインの利用形態に直接効く修正であり、
   本ADRが記録する一時的失敗の一部（Play Mode終了後にコマンドが見つからない類）は 0.6 で自然に解消している可能性がある。
   ただし本ADR・ADR-0007の対策はいずれも「一時的失敗を寛容に扱う」方向のものであり、この修正によって不要になるものではないため、対策は維持する。
