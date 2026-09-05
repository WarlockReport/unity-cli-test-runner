# ADR-0007: ドメインリロード窓での過剰検知・過小検知への対策と`--json`未指定バグの修正

## Status

Accepted (2026-08-21)

## Context

[ADR-0004](0004-domain-reload-transient-failures.md) で観測した「ドメインリロード中にPipelineサーバーが一時的にダウンする」事象について、
実測を重ねた結果、性質の異なる2つのバグが絡んでいることが分かった。

### (a) 過剰検知

`recompile_status`/`test_status`/`batch_test_status` 等のポーリング中、
ドメインリロードの約1〜2秒間だけPipelineサーバーが一時的にダウンし、`unity cmd` が以下のエラーで失敗する。

```
COMMAND_FAILED: "No Unity Editor instances found with reachable Pipeline servers."
```

修正前の各ポーリングループは、この失敗を1回検知しただけで即座にハング扱い（`exit 2`）していた。
実際にはリロード完了とともに自動的に復帰するため、これは誤検知である。

### (b) 過小検知

別の実測では、`recompile_status` が `completed` を報告した**直後**に、(a)と同じ理由でPipelineサーバーが一時的にダウンする順序を観測した。
つまり「`recompile_status: completed`」は単独では安全な完了シグナルにならず、その直後にまだドメインリロードが続いている場合がある。
これが「ポーリングが完了扱いになりテスト対象の解決へ先に進んでしまう」という、[ADR-0004](0004-domain-reload-transient-failures.md)の事例Aだけでは説明しきれなかった不具合の正体である。

(a)と(b)は同根（ドメインリロードによる一時切断）だが、対策の向きが逆（(a)は寛容に・(b)は厳格に）なので、別々に手当てする必要がある。

### 副次的に発見した独立のバグ: `--json` フラグの付け忘れ

上記の調査中、`ensure-compile-clean.sh` の `recompile_status`/`get_console_logs` 呼び出しに `--json` フラグが付いていないことが判明した。
`unity cmd` は `--json` を付けない場合TSV形式（`Command\tSuccess\tResult\tParameters`）で応答するため、jqによるパースが常に失敗し、コンパイルエラーがあっても `exit 1`（エラー検出）ではなく `exit 3`（判定不能）に落ちていた。
つまり、このスキルの「1. コンパイル状態の確定」ステップは、そもそもコンパイルエラー検知という本来の目的を実質果たしていなかった。
これは[ADR-0003](0003-ensure-compile-clean-json-field-names.md)で申し送りとなっていたJSONフィールド名の実機未検証事項とも直結する発見だった。

## Decision

### 1. 共有ヘルパー `scripts/_lib.sh` を新設

`is_transient_pipeline_unreachable()` で上記エラーメッセージの判定を1箇所に集約し、
`ensure-compile-clean.sh`/`run-playmode-test.sh`/`run-tests-batch-playmode.sh`/`check-editor-ready.sh`
の4スクリプトから共有する（改修前は同種のポーリングロジックを各スクリプトが個別に持っていた）。
単発コマンド用に `run_unity_cmd_resilient()`（transient unreachable時のみ有限予算でリトライする）も同ファイルに切り出した。

### 2. `ensure-compile-clean.sh`

- **(a)対策**: ポーリング中に transient unreachable を検知しても即 `exit 2` せず、ドメインリロード中とみなしてポーリングを継続する（経過秒数はbudgetから消費するため、budget超過まで unreachable が続けば従来通り `exit 2` ＝本当のハングとして扱われる）
- **(b)対策**: `recompile_status` が `completed`/`up_to_date` になっても即成功にせず、`editor_status` の `compiling==false && domainReloadInProgress==false` が**2回連続**で確認できてから `exit 0` とする新設のステップ「[4/5] editor_status でドメインリロード完了の安定確認」）。1回だけの確認では(b)のレースを再現しうるため2回連続を要件にした
- `--json` 未指定バグを修正し、`recompile_status --json` の `data.result` が `test_status`/`batch_test_status` と同様に二重エンコードされたJSON文字列であることを踏まえ `jq '.data.result | fromjson | .status'` で確定的に取り出すよう変更（複数候補フィールド名を試すフォールバックは撤去。詳細は[ADR-0003](0003-ensure-compile-clean-json-field-names.md)追記を参照）
- 上記変更により `exit 2` の意味が「budget全体を通じて到達不能だった」に変わるため、SKILL.mdの該当箇所も合わせて更新した

### 3. `run-playmode-test.sh` / `run-tests-batch-playmode.sh`

(a)対策のみ適用した（`test_status`/`batch_test_status` ポーリングに同じtransient-tolerantロジック）。
(b)の「completed直後にリロード」レースは、テスト実行自体が数秒以上かかり、リロードはPlayMode突入直後（テスト完了よりかなり前）に起きるため再現条件が薄いと判断し、今回はスコープ外とした。

### 4. `check-editor-ready.sh`

Step 0の1回きりの呼び出しにも、`run_unity_cmd_resilient()` による短い有限回数のリトライ（transient unreachable時のみ、予算15秒）を追加した。改修前は「起動していない」という誤解を招く文言のまま即 `exit 2` していた。

### 5. SKILL.md

既知の罠に `No Unity Editor instances found with reachable Pipeline servers` の実例と意味（一時的なドメインリロードの副作用であり「未起動」ではない）、および `recompile_status --json` の二重エンコード仕様を追記した。

## Consequences

- `ensure-compile-clean.sh` の最大所要時間は、recompile_statusポーリング（ステップ3）とeditor_statusによる安定確認（ステップ4）にそれぞれ独立してpoll budgetが適用されるため、
  指定したポーリング予算秒数の最大2倍になりうる（既定なら最大120秒）。これはUnityエディタが本当にハングしている場合の検知時間が伸びるトレードオフだが、誤検知（正常なドメインリロードをハングと誤判定する）を防ぐために許容する
- `run-playmode-test.sh`/`run-tests-batch-playmode.sh` に(b)相当の対策を入れていないため、理論上は同種のレースが起こりうる。再現・問題が確認された場合は改めてADRを起票して対策する
- 実装後の検証は、実際に強制リコンパイル（ダミー`.cs`ファイルの作成→即削除）を発生させ、ドメインリロードの窓をまたいでも `ensure-compile-clean.sh` が `exit 0` に到達することを実行ログで確認する形で行った（旧プロジェクト環境での実施）

### 追記 (2026-09-06) — 0.6のbusy応答を一時的失敗として扱うようにした

`com.unity.pipeline` 0.6.0-exp.1 は、コマンドを実行できない状態を HTTP 503 と構造化エンベロープ
（`error="Server Busy"` / `status="busy"` / `retryable=true` / `busyReason="settling"|"blocked_by_dialog"`）で返すようになった
（[ADR-0004](0004-domain-reload-transient-failures.md) の追記を参照）。

本ADRが導入した一時的失敗の判定は `No Unity Editor instances found with reachable Pipeline servers` の文字列一致のみで、
このbusy応答を一時的失敗として認識できなかった。そのため `_lib.sh` を以下のように拡張した。

- `is_transient_busy()` を追加。サーバーが返す構造化フィールド（`"retryable":true` / `"status":"busy"`）と、
  CLIが本文へ埋め込むメッセージ（`503 Service Unavailable` / `Server Busy`）の両方を拾う。
  既存の400応答で、CLIが `"Pipeline server returned 400 Bad Request: <error>. <errorDetails>"` の形で
  サーバーの error/errorDetails を本文に埋め込むことを実測で確認しているため、両面から拾う設計にした
- `is_transient_failure()` を追加（`is_transient_pipeline_unreachable` または `is_transient_busy`）。
  `run_unity_cmd_resilient` と `ensure-compile-clean.sh` の2つのポーリング関数、
  `run-playmode-test.sh` / `run-tests-batch-playmode.sh` のポーリングループの判定をこれに差し替えた
- `run_unity_cmd_capture()` を追加。一時的失敗のメッセージが標準出力・標準エラーのどちらに出るかは
  CLIの版・失敗種別に依存するため、判定には両方を結合した `UNITY_CMD_DIAG` を使い、
  呼び出し元がjqでパースする値は標準出力だけの `UNITY_CMD_OUT` に保つ。
  従来の `raw="$(run_unity_cmd ...)"` というコマンド置換の形では、サブシェル内で設定した変数が親に伝わらないため、
  ポーリング側の呼び出し形を明示的に書き換えている。
  なお改修前は標準エラーがそのまま端末へ素通りしていたため、`run_unity_cmd_capture` でも
  判定に使った後で `cat "$err_file" >&2` して素通りを維持している。
  これを怠ると、標準出力が空で標準エラーにだけ理由が出る失敗（CLIとサーバーの版不整合などがこの形になる）で
  「失敗しました」以外の手がかりが消える

`blocked_by_dialog` は、ユーザーがダイアログを閉じるまで解消しない。
本ADRの設計（有限予算内でのみリトライし、超過したら盲目的に待たず呼び出し元へ委譲する）はこのケースにもそのまま当てはまり、
予算を使い切って失敗し、そのときエラー本文がダイアログの存在を伝えるのが正しい振る舞いである。

**未検証**: `unity` CLI（1.0.0-beta.6）が503応答を具体的にどう整形するかは、0.6環境での実機確認が必要である。
上記の検出は構造化フィールドとメッセージ本文の両方を拾う設計にしてあるが、実機で確認するまで確定ではない。
