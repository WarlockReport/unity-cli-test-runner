# ADR-0031: テスト結果を camelCase の 1 形式に揃え、EditMode も非同期実行で読む

## Status

Accepted (2026-11-13)

## Context

`com.unity.pipeline` 1.0.0-pre.1 で `test run` / `test status` の応答のキーが camelCase（`summary.total`、`results[].fullName`）になった。
これまでスクリプトは 3 つの形を読み分けていた（EditMode の `test run` 直呼び出しは `Summary.Total`・`Results[].FullName` の PascalCase、
PlayMode の `test status` は `summary` が小文字で `results[]` だけ PascalCase、自前コマンドは PascalCase）。

あわせて `unity` CLI 1.0 では（[ADR-0030](0030-cli-1.0-result-only-output.md)）:

- 同期の `test run` は結果を 1 行 1 テストのストリームで出し、**summary を返さない**。テストが失敗すると終了コード 6
- `test run --async-tests` + `test status` なら、EditMode でも PlayMode と同じ
  `{status, duration, summary:{total,passed,failed,skipped,inconclusive}, results:[{fullName,status,duration,message,stackTrace}]}` の
  1 オブジェクトが返る（失敗テストがあっても message・stackTrace まで揃う。終了コードは 6）
- 一致 0 件は、`--async-tests` の起動は受理され（終了コード 0）、`test status` が「0 件で完了」を終了コード 2 と `No selected tests found.` で返す
- 1.0.0-pre.1 の changelog: 取り消された実行の `test status` は終了コード 130

検討した案:

| 案 | 内容 | 結論 |
| --- | --- | --- |
| 1 | EditMode も async + `test status` で読み、自前コマンドの応答も同じ camelCase にする | **採用**。読む形が 1 種類になり、summary は Pipeline が数えた本物 |
| 2 | EditMode は同期 `test run` のまま、ストリームから summary を数える | 不採用。自前で数えた summary との突き合わせは必ず一致し、`summarize-test-result.sh` の件数の食い違い検知（MISMATCH）が意味を失う。途中で切れたストリームも検知できない |

## Decision

1. **Pipeline 本体のテストは EditMode も `test run --async-tests` で起動し、`test status` をポーリングして読む**。
   `run-editmode-test.sh` / `run-playmode-test.sh` の本体を `_lib.sh` の `run_pipeline_test_async` に共通化した
   （ベースライン比較による stale 検知・`testName` の手がかり確認も共通。比較は `jq -cS` で正規化した中身同士で行う）
2. **自前コマンド（`wr.testrunner`）の応答を camelCase にする**（UPM パッケージ 1.0.0 の破壊的変更）。C# のモデルに
   `[JsonProperty("summary")]` 等を付けた。同期の EditMode コマンドは `status: "completed"` を足し、スクリプトが読む部分
   （`status`・`summary`・`results[]`）は `test status` と同形にする。EditMode はドメインリロードをまたがないので、自前の EditMode
   コマンドは同期のまま（非同期にしてもランナーとステータスファイルが増えるだけで得が無い）
3. **終了コードの扱い**:
   - 失敗テストを含む完了（終了コード 6）は結果確定（exit 0）
   - 一致 0 件は `run-editmode-test.sh` / `run-playmode-test.sh` とも **exit 1**（新設。標準出力は空で、件数を作らない）。
     「0 件で完了」が前回の結果（ベースライン）と同一のときは、同じ filter で続けて 0 件になったのか、直した filter の実行が
     まだ反映されていないのかを区別できないので、さらに 2 回ポーリングしてから 0 件と確定する（数秒遅れるだけ）
   - 起動後にベースラインと異なる応答（running 等）を一度でも観測したら、その後の完了は前回と同一でも今回の結果とみなす
     （全件スキップ等で duration まで前回と同じになる実行を、予算を使い切ってから stale と誤判定しないため。自前の PlayMode も同じ）
   - summary を持たない終端状態（`test status` / `batch_test_status` の `error`・`failed`・`cancelled`、終了コード 130）は、
     ポーリング予算を待たずに **即 exit 2**（`status` と `message` を標準エラーへ）
   - ポーリング中に終了コード 0 で中身を読めない応答（空・途中で切れた JSON）は、書きかけとみなして待つ（予算超過なら exit 2）
   - 自前コマンドの `success:false`（終了コード 6）は「Unity 側で受理されなかった」として exit 2。`run-tests-batch-editmode.sh` も
     `success` を確かめるようにした（従来は確かめておらず、実行のタイムアウトを結果確定と報告しうる状態だった）
4. **新しいプラグインと旧版 UPM パッケージ（PascalCase の応答）の組み合わせは、版のずれとして exit 3**。両方の形を読むことはしない
   （1.0 専用の方針。読み違えた件数を報告するより止める方が安全）。旧版が書いた PascalCase のステータスファイルが Temp/ に残っていても、
   UPM 側の `batch_test_status` は `status: "malformed"` を返す
5. `summarize-test-result.sh` は camelCase の 1 形式（`.summary`・`.duration`・`.results[].fullName/status/message/stackTrace`）だけを読む。
   旧形式（`.data` のエンベロープ、PascalCase のキー）は件数を推測せず exit 3（`SOURCE` 行だけ）

## Consequences

- すべてのテスト実行スクリプトの出力が同じ形になり、SKILL.md の「キーの大文字小文字の混在」の注意が不要になった
- `run-editmode-test.sh` / `run-playmode-test.sh` の終了コード表に 1（一致 0 件）が加わった。これまでは 0 件の結果を exit 0 で返していた
- `unity cmd wr.testrunner ...` を直接叩いていた利用者は、応答のキーの変更に追従する必要がある
- 変化を一度も観測しないまま前回と同一の完了が続く場合だけを stale（exit 3）とする。0 件の場合はその代わりに猶予の後 exit 1

### 実地検証（2026-11-13、TestProject、Unity 6000.3.25f1 + `com.unity.pipeline` 1.0.0 + `unity` CLI 1.0.0）

- `run-editmode-test.sh`（失敗 1・スキップ 1 を含むクラス）→ 0、summary 5/3/1/1。同じ指定の連続実行も 0。アセンブリ指定 → 0（17 件）
- `run-playmode-test.sh`（失敗 1 を含むクラス）→ 0、summary 3/2/1
- 一致 0 件: EditMode・PlayMode とも → 1、標準出力は空。EditMode の連続 2 回とも 1
- `run-tests-batch-editmode.sh` → 0（5/3/1/1）、`run-tests-batch-playmode.sh` → 0（3/2/1）・連続実行も 0、
  `run-tests-filtered-editmode.sh` → 0（12 件）、`run-tests-filtered-playmode.sh` → 0（4 件）。存在しない名前のバッチ EditMode → 0（標準エラーに案内）
- `e2e/run-all.sh`: 一致 58 件 / 不一致 0 件。`e2e/run-all.sh --pipeline 1.0.0`: 一致 58 件 / 不一致 0 件、後片付け成功
  （0.10 時点の 59 件から 1 件減ったのは、カンマ区切りの testName の罠の照合が「0 件の SUMMARY」から「終了コード 1」の 1 件になったため）
