# ADR-0003: ensure-compile-clean.shのJSONフィールド名の実機未検証

## Status

Accepted（実機確認待ちの申し送り）

## Context

`recompile_status`/`get_console_logs` の正確なJSONフィールド名は、
スクリプト設計時点では**実地未検証**だった（スクリプト自身の分岐ロジック・フォールバックはモックによるテストで確認済み）。

## Decision

複数の候補フィールド名を試すフォールバックを `scripts/ensure-compile-clean.sh` に入れているため通常は動作するはずだが、
確定値への更新は後続作業として残す。

## Consequences

別マシンでの初回実行時に実際のフィールド名・応答時間を確認し、
想定と異なれば `scripts/ensure-compile-clean.sh` 内のjqフィルタ・タイムアウト目安値を確定値に更新すること。