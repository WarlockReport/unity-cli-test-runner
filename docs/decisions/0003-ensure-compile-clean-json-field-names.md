# ADR-0003: ensure-compile-clean.shのJSONフィールド名の実機未検証

## Status

Resolved (2026-08-21) — [ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) で確定値に更新済み

## Context

`recompile_status`/`get_console_logs` の正確なJSONフィールド名は、
スクリプト設計時点では**実地未検証**だった（スクリプト自身の分岐ロジック・フォールバックはモックによるテストで確認済み）。

## Decision

複数の候補フィールド名を試すフォールバックを `scripts/ensure-compile-clean.sh` に入れているため通常は動作するはずだが、
確定値への更新は後続作業として残す。

## Consequences

別マシンでの初回実行時に実際のフィールド名・応答時間を確認し、
想定と異なれば `scripts/ensure-compile-clean.sh` 内のjqフィルタ・タイムアウト目安値を確定値に更新すること。

### 追記 (2026-08-21)

実機検証により以下が判明し、フォールバック実装は確定値ベースの実装に置き換えられた（詳細は
[ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) を参照）。

- `recompile_status --json` の `data.result` は `test_status`/`batch_test_status` と同様、JSON文字列として二重エンコードされている。
  `jq '.data.result | fromjson | .status'` で取り出す（旧実装の `.status // .recompileStatus // .state` 等の候補フィールド名フォールバックは誤りで、常に空になっていた）
- `get_console_logs --json` の `data.result` はネイティブなJSONオブジェクト（`{total, returned, logs: [...]}`）
- より重大な問題として、`recompile_status`/`get_console_logs` の呼び出しに `--json` フラグ自体が付いておらず、
  TSV形式の応答をjqでパースしようとして常に失敗していた（＝コンパイルエラー検知が実質機能せず、exit 1ではなくexit 3に落ちていた）。`--json` を追加して解消した