# ADR-0009: テスト起動呼び出し自体への単発リトライ導入（起動直後の瞬断で毎回2倍コストになる問題の解消）

## Status

Accepted (2026-08-22)

## Context

[ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) で、`recompile_status`/`test_status`/`batch_test_status` などの**ポーリングループ内**で発生する、
ドメインリロード起因の一時的なPipeline切断（`No Unity Editor instances found with reachable Pipeline servers.`）への対策（`is_transient_pipeline_unreachable` による寛容な継続）を導入した。

しかし実利用で、テストを**起動する最初の1発呼び出し**自体がこの瞬断に当たり、そのままハング・タイムアウト扱いとして呼び出し元（コントローラー）に返ってしまう事例が発生した。
ポーリングループとは異なり、起動呼び出しは1回叩いて成否を見るだけの箇所であり、ADR-0007の対策範囲外だった。

具体的には以下の4箇所が、瞬断1回で即座に失敗する構造になっていた:

1. `run-playmode-test.sh` [2/4] `run_tests --mode PlayMode --async_tests` の起動呼び出し（raw `unity cmd`、リトライなし）
2. `run-tests-batch-playmode.sh` [2/4] `run_tests_batch_playmode` の起動呼び出し（同上）
3. SKILL.md 手順5の EditMode（単一/クラス/アセンブリ）実行 — そもそもスクリプト経由ではなく、コントローラー/エージェントが `unity cmd run_tests --mode EditMode ...` を**直接**呼んでいた（リトライ皆無）
4. SKILL.md 手順5の EditMode バッチ実行 — 同様に `unity cmd run_tests_batch_editmode ...` を直接呼んでいた（リトライ皆無）

この構造では、コード修正直後（コンパイル完了直後のドメインリロード窓）にテスト実行を呼ぶと、
瞬断1回だけで「ハング・タイムアウト時の対応」（ユーザーへのモーダルダイアログ確認依頼→状況確認→再開）に入ってしまう。
実際の原因は1〜2秒で自然に解消する一時的な切断であるにもかかわらず、この確認・再開のやり取りがまるごと発生するため、テスト実行1回あたりのトークンコストが実質2倍になっていた（実測で65k+68kトークン相当の事例を観測）。

## Decision

### 1. 起動呼び出しの一発リトライ化

上記4箇所すべてを、`_lib.sh` の `run_unity_cmd_resilient()`（transient unreachable時のみ有限予算でリトライする、既存の単発コマンド用ヘルパー。
`ensure-compile-clean.sh`/`check-editor-ready.sh` の各種呼び出しで既に使われている）経由に統一した。リトライ予算は既存の慣習に合わせ15秒（`ONESHOT_RETRY_BUDGET_SECONDS=15`）。

- `run-playmode-test.sh`/`run-tests-batch-playmode.sh`: 該当の起動呼び出しを `run_unity_cmd`（raw）から `run_unity_cmd_resilient` に置き換え
- EditMode（単一・バッチとも）は、そもそも起動呼び出しを直接叩く既存スクリプトが無かったため、新規に `scripts/run-editmode-test.sh`／`scripts/run-tests-batch-editmode.sh` を追加した。
  EditModeの `run_tests`/`run_tests_batch_editmode` は同期応答（ポーリング不要）のため、PlayMode版のような多段ポーリング構造は持たず、`run_unity_cmd_resilient` 経由の起動呼び出し1回で完結するシンプルな構成にした

### 2. SKILL.mdの更新

手順5のEditMode実行を、直接の `unity cmd` 呼び出しから上記2スクリプト経由に差し替えた。
禁止事項にも、PlayMode側に既にある「スクリプトを介さず直接呼ばない」という禁止を、EditMode側にも対称に追加した（実装主体をLLMのその場の判断に委ねず、スクリプトに一本化することで再発を防ぐという、このリポジトリで一貫している設計方針に合わせた）。

## Consequences

- テスト起動直後の瞬断1回では、もはやユーザーへの状況確認・再開のやり取りを挟まない（リトライ予算15秒以内に復帰すれば自動的に成功として扱われる）。
  これにより、当該パターンで発生していたトークンコストの倍化を解消できる見込み
- EditMode実行がスクリプト経由に一本化されたことで、PlayMode/バッチ双方と実行経路の構造が揃い、
  今後同種の耐障害性対策を入れる際の変更箇所が予測しやすくなった
- 実機での確認は完了した（2026-08-22）。修正版を、`.claude-plugin/marketplace.json` の名前衝突を利用してこのリポジトリのローカルパスをソースとするマーケットプレイスとして一時的に登録し直し（GitHubへのpush・mainへのマージなしで、作業ツリーの未コミット変更を含めてインストールできることを確認済み）、プラグインを再インストールした状態で、検証用の別Unityプロジェクトに対して、意図的に1件failするよう仕込んだテストクラスを `unity-test-runner` サブエージェント経由で実行した。
  修正前（旧コミット24ff97f、ADR-0007以前の版）では起動呼び出しの`get_console_logs`がネットワークエラーで即座に失敗し「ハング・タイムアウト時の対応」に入ったのに対し、修正後（本ADR適用版）はコンパイル確定からテスト実行・結果報告まで一度も止まらずに完走し、意図した1件のFailを通常の結果として正しく報告できた。ドメインリロード瞬断そのものを踏んだかは確定できないが、少なくとも新しい実行経路（`run-editmode-test.sh`含む）が正常系で問題なく動作することは確認できた
- 万一15秒のリトライ予算内に復帰しない場合（＝本当のハング）は、従来通り「ハング・タイムアウト時の対応」に進む。
  この場合のコスト構造は変わらない（そもそも瞬断ではなく本当の異常なので、状況確認が必要なこと自体は妥当）
