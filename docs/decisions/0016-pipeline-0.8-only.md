# ADR-0016: `com.unity.pipeline` 0.8.0-exp.1 への一本化と `*_status` のネイティブJSON化への追従

## Status

Accepted (2026-10-04)

## Context

UPMレジストリの `com.unity.pipeline` の `dist-tags.latest` が `0.8.0-exp.1`（2026-09-22）になった。
0.7 と 0.8 の tarball をUPMレジストリから取得し、ソースを直接 diff して以下を確認した（ADR-0015 と同じ手法、2026-10-04）。

| 確認項目 | 結果 |
|---|---|
| `CliCommandAttribute` / `CliArgAttribute` | `Runtime/Common/`（`Unity.Pipeline`）から `Runtime/Attributes/`（`Unity.Pipeline.Attributes`）へ移動。名前空間 `Unity.Pipeline.Commands` は不変、中身の差はコメントのみ → `TestRunnerCli.asmdef` が `Unity.Pipeline` しか参照していないため**UPMパッケージがコンパイルできなくなる** |
| `*_status` の返り値 | `recompile_status` は `RecompileStatusPayload`、`test_status` 等は `JToken`（`StatusFileReader.Parse`）を返すようになった（CHANGELOG: "The nine `*_status` commands return their payload as real JSON"）。コマンドごとの修正で、サーバーの直列化は不変 → `fromjson` 前提の `run-playmode-test.sh` が status を読めず、**毎回ポーリング予算超過（exit 2）になる** |
| `string` を返すカスタムコマンド | 従来どおり二重エンコードされる → 自前の `batch_test_status` は何もしなければ二重エンコードのまま |
| `RecompileStatusPayload` のキー | `status`/`failed`/`errors`/`compilationFailed`。0.7 と同じ |
| 本体の `TestExecutionResponse` / `TestResult` / `TestSummary` | 0.8 でも internal → ADR-0012 のベンダリングは引き続き必要 |
| `CommandExecutionResponse` / `BaseResponse` | public のまま |
| `BasePipelineServer` | `127.0.0.1` のみにバインドし、それ以外の Host は拒否するようになった。`blocked_by_dialog` 周りに実質的な変更は無い → ADR-0013 の非対称判別は引き続き必要 |

## Decision

- **0.8 一本化する。0.7 以前は非対応・未検証とする**（ADR-0015 と同じ判断。Pipeline 自体が experimental であり、多版サポートはコストに見合わない）
- `TestRunnerCli.asmdef` の `references` に `Unity.Pipeline.Attributes` を追加する
- **自前の `batch_test_status` も `JToken` を返す形に変え、0.8 本体の `*_status` と揃える**。`test_status` はネイティブ、`batch_test_status` は二重エンコード、という非対称を残さないため。パース規則は本体の `StatusFileReader.Parse` に合わせる（`DateParseHandling.None`、文書の後ろの残骸を不正とみなす、空・パース不能は例外にせず `{"status":"malformed","raw":...}`）
- **スクリプトの `.data.result` の取り出しは、文字列/オブジェクトの両形式に対応させる**（`_lib.sh` の `extract_result_payload` に集約）。Pipeline の版を両対応にするためではなく、プラグインとUPMパッケージが別々に更新されるため（新しいプラグイン + 旧版のUPMパッケージでは `batch_test_status` が二重エンコードのまま返る）
- `malformed` は終端ではない状態として扱い、ポーリングを続ける（直らなければ既存のポーリング予算超過 exit 2 に落ちる）
- **`versionDefines` の expression は空のまま据え置く**。0.7 でもコンパイル自体は通るため、わざと無効化して「コマンドが見つからない」という分かりにくい失敗を起こすより、非対応・未検証と文書に明記するほうを選ぶ

## Consequences

- 0.8 の Unity プロジェクトで UPM パッケージが再びコンパイルでき、PlayMode テストの単体・バッチ実行が完走する
- `batch_test_status` の `data.result` の形が変わる。本プラグイン以外から `jq '.data.result | fromjson'` で読んでいた利用者は読み方を変える必要がある
- 0.7 以前の環境でも、現時点ではおそらく動く（asmdef の参照先は 0.7 にも存在し、スクリプトは両形式を読む）が、検証対象外とする
- 実機検証の結果は「実地検証」節に記録する

## 実地検証

（Task 5 で、検証日・環境・結果を記入する）
