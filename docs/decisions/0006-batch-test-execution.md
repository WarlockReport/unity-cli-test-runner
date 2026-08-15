# ADR-0006: 複数テスト一括実行のバッチ化

## Status

Accepted (2026-08-13)

## Context

以下3点の残課題があった。

1. 複数のテストを連続で実行する場合、対象ごとにコンパイル確認からやり直す非効率があった
2. Unity CLIの `run_tests` は複数クラスにまたがる完全名の一括実行に対応できない（`--filter_type testName` へのカンマ区切りは部分一致ロジックの都合で静かに0件空振りする）
3. `unity status` によるエディタ起動チェックが自然文の手順のみだった

## Decision

1. スキルのワークフローを「1回の呼び出し＝対象リスト」前提へ再構成し、コンパイル 確認・起動確認を呼び出し内で1回化した
2. Unity側に `run_tests_batch_editmode`/`run_tests_batch_playmode` というPipelineカスタムコマンドを新設した。 
  実例として、同一プロジェクト内の既存Pipelineカスタムコマンド実装を雛形にした
3. `check-editor-ready.sh` としてスクリプト化した

## Consequences

本設計のバッチ化により、複数テスト対象1件ごとにサブエージェントを呼び直す頻度は下がる。
「サブエージェントのネスト呼び出しで完了通知が親に届かない問題」自体への対応は、[ADR-0005](0005-subagent-nested-invocation-completion-routing.md)を参照。