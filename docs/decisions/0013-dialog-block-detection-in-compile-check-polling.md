# ADR-0013: `ensure-compile-clean.sh`へのダイアログブロック判別の移植（`.unity`/`.prefab`外部変更ダイアログによる誤ハング判定の解消）

## Status

Accepted (2026-09-06)

## Context

実運用で以下の事象が報告された。

1. Claude Codeがコード修正の一環で `.unity`（Scene）ファイルを更新した。対象シーンはUnity Editor上で開かれた状態だった
2. Claude Codeが修正確認のため `unity-compile-check` スキル（`ensure-compile-clean.sh`）を実行した
3. Unity側が外部からのシーン変更を検知し、「Reload/Ignore」の外部変更確認モーダルダイアログを表示した
4. Claude Codeがこれを（ダイアログブロックではなく）真のハングと判断し、作業が停止した

モーダルダイアログによるメインスレッドブロックの判別ロジック自体は、ステップ0（`check-editor-ready.sh`）に既に実装済みだった。`editor_status`（MainThreadRequired）が失敗した際、メインスレッド不要の `recompile_status` を1回叩いて生死判定し、応答すれば「Pipelineサーバーは生きていてメインスレッドだけが塞がれている」＝ダイアログブロックと確定する、という仕組みである（2026-09-06実測、SKILL.md記載）。

しかしこの判別ロジックは `check-editor-ready.sh` にしか実装されておらず、`ensure-compile-clean.sh` 内のポーリング関数（`poll_editor_status_settle`、および予算超過後の自動リカバリ判定 `is_editor_ready_now`／`retry_once_if_recovered`）には移植されていなかった。これらの関数は `editor_status` の失敗を `_lib.sh` の `is_transient_failure`（Pipeline到達不能・busy応答のみ）でしか一時的失敗と認識せず、それ以外の失敗（ダイアログブロックを含む）は即座に「非一時的な失敗」として `return 2` していた。呼び出し元も `case "$step_rc" in 2) exit 2 ;;` で分岐しており、SKILL.mdの記載上「`exit 2` はスクリプト内で既に自動リカバリを試みた上での結果なので、呼び出し元は追加確認なしに真のハングとして報告してよい」となっている。そのため、コンパイルチェック実行中に外部変更ダイアログが出ると、報告されたシナリオの通り「ハング」として作業が止まっていた。

この事象は `.unity` だけでなく `.prefab`（Prefabモードで編集中のPrefab）でも起こりうる。Unity Pipelineパッケージの公開ドキュメントを確認したが、開いているPrefabの一覧を取得する既存コマンドは無く、機械的に検知するには本プラグインのUnity側に新規CLIコマンドを実装する必要があり、UPMパッケージのバージョンアップを伴う規模になる。一方で、ダイアログブロックの判別ロジックは原因（シーンかPrefabか）を問わず「メインスレッド必須コマンドが失敗し、メインスレッド不要コマンドは応答する」という症状だけを見て機能するため、対策をこの判別ロジックの移植に絞ることで、新規コマンド実装なしにPrefabのケースも合わせてカバーできると判断した。

## Decision

- `_lib.sh` に、`check-editor-ready.sh` が持っていた判別ロジックをそのまま抽出した共通関数 `is_blocked_by_dialog` を追加した（メインスレッド不要な `recompile_status` を1回叩き、`success:true` が返れば0、そうでなければ1）
- `check-editor-ready.sh` はこの共通関数を呼ぶよう書き換え、ロジックの重複を解消した
- `ensure-compile-clean.sh` の `poll_editor_status_settle`（`editor_status` を使う唯一のポーリング関数。`poll_recompile_status` はメインスレッド不要コマンドのみ使うためダイアログブロックの影響を受けず、変更していない）に、非一時的失敗と判定する直前で `is_blocked_by_dialog` を挟み、ダイアログブロックと確定できれば専用の戻り値 `3` を返すようにした
- `com.unity.pipeline` 0.6以降で `busyReason="blocked_by_dialog"` の503 busy応答が有効な環境向けに、`_lib.sh` に `is_busy_blocked_by_dialog` を追加し、`is_transient_failure` より**先に**判定するようにした。`is_transient_busy` は `retryable:true`/`status:"busy"` の応答全般を一時的失敗として扱うため、これより後に判定すると `blocked_by_dialog` もリトライ対象に含まれてしまい、ポーリング予算を使い切るまで `exit 4` に到達できない（レビューで指摘され、モック検証で実際に予算超過まで待たされることを確認した上で分岐順序を直した）
- 予算超過後の自動リカバリ判定 `retry_once_if_recovered`（内部で `is_editor_ready_now` を使い `editor_status` を直接確認する）にも同様の判別を追加し、専用の戻り値 `2` で区別した。リカバリの再試行（`"$poll_fn" "$budget"` の再実行）が改めて `poll_editor_status_settle` の戻り値 `3` を返した場合も握り潰さず伝播させる
- レビューで指摘され見落としに気づいたが、`ensure-compile-clean.sh` はステップ3・4（`editor_status`/`recompile_status` のポーリング）以外に、ステップ1（`clear_console`）・ステップ2（`recompile`）・ステップ5（`get_console_logs`）でも `run_unity_cmd_resilient` を単発呼び出ししており、これらもメインスレッド必須コマンドと見られるため同様にダイアログでブロックされうる。むしろ「`.unity`編集直後にコンパイルチェックを開始する」という報告シナリオでは、ダイアログが出ている状態で最初に叩かれるのはステップ1の `clear_console` である。この3箇所の失敗時にも `is_blocked_by_dialog` を挟み、確定できれば `report_dialog_block_and_exit` で `exit 4` にするようにした（`is_busy_blocked_by_dialog` の早期判定はポーリングループ専用の最適化であり、単発呼び出しでは `is_blocked_by_dialog` 単体で（busy応答時は`run_unity_cmd_resilient`内部の最大15秒リトライを経て）タイムアウト経路・busy経路の両方を拾えるため、ここでは併用していない）
- スクリプト全体の終了コードとして新たに `exit 4`（ダイアログブロック検知。真のハングではない）を追加した。メッセージ出力は `report_dialog_block_and_exit` に共通化した
- `unity-cli-test-runner`・`unity-compile-check` 両SKILL.mdの終了コード表、「ハング・タイムアウト時の対応」節（`exit 4` はこの節の対象外で、ダイアログを閉じてもらう依頼のみでよい旨）、「既知の罠」節（`.unity`/`.prefab`外部変更ダイアログの発生条件と、原因を問わず検知される仕組み）を更新した
- 発生源の抑制（`.unity`/`.prefab`編集前にUnity上で開かれているか事前確認する等）は、Prefabの機械的検知手段が無いこと、シーンについても「直前に何を編集したか」をスクリプトに渡す手段が無いことから、新規実装は見送り、「既知の罠」への注意書き（対象ファイルがUnity上で開かれていないか意識する）に留めた

## Consequences

- コンパイルチェック実行中に `.unity`/`.prefab` の外部変更ダイアログ（またはその他の要因によるモーダルダイアログ）が表示されても、`ensure-compile-clean.sh` は `exit 2`（真のハング）ではなく `exit 4`（ダイアログブロック）を返すようになり、コントローラーは「Unityエディタを確認してダイアログを閉じてください」と正しく報告できる
- `check-editor-ready.sh` の外部からの挙動（終了コード・メッセージ）は変更していない。内部実装を共通関数の呼び出しに置き換えただけである
- モック `unity` CLI（`unity cmd <subcommand>` の呼び出し形式を模擬し、`editor_status` のみ失敗・`recompile_status` は成功、というシナリオを再現するスクリプト）を用いて以下を確認した:
  - `editor_status` のみ失敗（タイムアウトベース）・`recompile_status` は成功 → `ensure-compile-clean.sh` が `exit 4` を返す
  - `editor_status` が `busyReason="blocked_by_dialog"` の503 busy応答を返す（0.6以降） → 予算超過を待たず即座に `exit 4` を返す（分岐順序修正後）
  - `editor_status` が `busyReason="settling"` の503 busy応答を返す→復帰する → 従来通り一時的失敗としてポーリングを継続し、`exit 0` になる（`blocked_by_dialog`専用の早期判定を追加したことで`settling`の扱いに影響していないことの確認）
  - `editor_status`・`recompile_status` 両方失敗（真のハング） → 従来通り `exit 2` を返す
  - 全コマンド正常応答 → 従来通り `exit 0` を返す（回帰なし）
  - `clear_console`/`get_console_logs` のみ失敗（タイムアウトベース）・`recompile_status` は成功 → `exit 4` を返す（ステップ1・5。まさに報告シナリオの再現）
  - `clear_console` 失敗、`recompile_status` も失敗（真のハング） → 従来通り `exit 2` を返す
  - `check-editor-ready.sh` について、ダイアログブロック（`exit 1`）・ready（`exit 0`）・真のハング（`exit 2`）の3パターンがリファクタ後も変わらないことを確認した
  - 上記はすべてモック`unity` CLIによる検証。実際のUnity Editor・実際のモーダルダイアログを使った実地検証は下記「実地検証」節を参照
- Prefabについて、開いているPrefabの一覧を取得する新規CLIコマンドの実装は行っていない（本ADRの対策範囲外）。将来的にUnity Pipelineパッケージ側で該当コマンドが提供されるか、機械的な発生源抑制が必要になった場合は改めてADRを起票する

## 実地検証 (2026-09-06)

ユーザーが実際にUnity Editor上でモーダルダイアログ（Scene外部変更のReload/Ignore確認ダイアログ）を開いた状態のまま、`unity-cli-test-runner`（Unity 6000.3.14f1・`com.unity.pipeline` 0.6.0-exp.1）に対して以下を実行した。ダイアログを閉じる操作・対象Unityプロジェクト内のファイル操作は一切行っていない。

- `unity status`（メインスレッド不要、ポート一覧のみ）は `state:"ready"` を返す。ダイアログの有無を判定できないことを確認
- `check-editor-ready.sh` を実行 → `exit 1`。「メインスレッドが塞がっています...モーダルダイアログが開いたままになっている可能性が高いです」を出力し、生JSONに `Pipeline command 'editor_status' timed out after 30000ms` を含んでいた（busy応答ではなくタイムアウトベースの判別が実際に機能した。ADR-0004/0007が言う「recent enough trunk build」の busy 検出はこの環境でも有効になっていないことを裏付ける）
- `ensure-compile-clean.sh 30` を実行 → `exit 4`（所要30.5秒）。ステップ1の `clear_console` が30秒でタイムアウトした直後、`is_blocked_by_dialog` が `recompile_status` で生死確認し、「モーダルダイアログが開いている可能性が高いです（ハングではありません）」と判定して終了した

これは、本ADRのレビューで見つかった「ステップ1（`clear_console`）に判別ロジックが抜けていた」穴に対する修正が実機でも機能することの直接証拠になる。この修正が無ければ、この状況は `exit 2`（真のハング）としてユーザーに報告され、最初の問題報告どおり「作業が停止する」症状が再現していたはずである。

`busyReason="blocked_by_dialog"` の503 busy応答（`is_busy_blocked_by_dialog` の経路）は、この環境では busy 検出自体が無効なため今回は再現できていない。同応答が有効な環境での実地検証は別途必要。

## 関連

- [ADR-0004](0004-domain-reload-transient-failures.md) / [ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) — ダイアログブロックの503 busy応答検出（`blocked_by_dialog`）について。本ADRで扱うのは、この busy応答が有効になっていない版（Unity 6000.3.14f1 実測）でのタイムアウトベースの判別
- [ADR-0011](0011-ensure-compile-clean-inline-recovery.md) — 本ADRで変更した `poll_editor_status_settle`/`retry_once_if_recovered` の自動リカバリ機構自体の導入経緯
