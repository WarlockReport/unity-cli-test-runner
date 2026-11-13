# ADR-0032: ドメインリロード中の `PIPELINE_UNREACHABLE`（終了コード 12）を一時的切断として扱う

## Status

Accepted (2026-11-13)

## Context

v1.0.0 を導入した利用プロジェクト（Unity 6000.3.25f1、`unity` CLI 1.0.0、`com.unity.pipeline` 1.0.0、macOS）から報告があった。
実際に再コンパイルが走った 5 回すべてで、`ensure-compile-clean.sh` が完了待ち（`[4/5]`）の途中に exit 2（ハング扱い）で止まった。
どの回も、直後の `editor status` は `ready`（`codeLoadCount` +1）、`script recompile_status` は `failed:false` で、
数秒後にはエディタが戻り、コンパイルも成功していた。導入直後の動作確認は変更が無く再コンパイルが走らない状態で行ったため、見つからなかった。

失敗した `editor status` の応答は終了コード 12 で、標準出力は次の形だった。

```json
{"success":false,"command":"command","data":{"candidates":[{"project":"<名前>","projectPath":"<パス>","pid":12345}]},
 "errors":[{"code":"PIPELINE_UNREACHABLE","message":"Found a running Unity Editor with the Pipeline package installed, but its Pipeline server isn't reachable: ... This can happen if the Editor just started, a domain reload is in progress, or the Pipeline package is too old. ..."}],"warnings":[]}
```

ADR-0030 は終了コード 12 を `EDITOR_NOT_RUNNING`（`No Pipeline instance found for project`）としてだけ実測しており、
`_lib.sh` の `is_transient_pipeline_unreachable` もそのコード・文言しか照合していなかった。1 回の失敗例では、既知の一時的失敗で
「待ち続けます」と表示された後に `PIPELINE_UNREACHABLE` が出ており、1 回のリロード中に両方が順に出ることもある。

TestProject（Unity 6000.3.25f1 + CLI 1.0.0 + Pipeline 1.0.0）では、再コンパイル中の `editor status` を 0.1〜0.2 秒間隔で 4 回観測したが、
出たのは `EDITOR_NOT_RUNNING`（12）と切断（6）だけで、`PIPELINE_UNREACHABLE` は再現しなかった（2026-11-13）。
プロジェクトの規模によってリロードの各段階の長さが変わり、サーバーが落ちてからプロセスの登録が消えるまでの間に当たるかどうかが変わると考えられる。

## Decision

`is_transient_pipeline_unreachable` の照合に、`"code":"PIPELINE_UNREACHABLE"` と文言 `Pipeline server isn't reachable` を追加する。
`run_unity_cmd_resilient`・`ensure-compile-clean.sh` の完了待ち・PlayMode のポーリングは、どれもこの判定を使うので同時に直る。

検討した案:

- **A（採用）: コードと文言を照合に追加する。** 応答の `errors[].code` という構造化された手がかりがあり、照合が正確になる
- **B（不採用）: 終了コード 12 を一律に一時的扱いにする。** 応答に `data.candidates` があることから、CLI はエディタ候補の選択を経て
  終了コード 12 を返している。候補が絞れない等、待っても解消しない 12 まで巻き込むと、予算を使い切ってから exit 2 で止まり、原因が見えにくくなる

## Consequences

- 再コンパイル後のリロード中にこの応答が出ても、スクリプトは待ち続けて結果を返す
- Pipeline が本当に古い、またはサーバーが復帰しない場合は、予算超過の exit 2 になる（応答の本文は標準エラーに残る）
- CLI が別のコード名で同じ状態を返すようになれば、再び照合に足す必要がある。終了コード 12 で未知のコードは一時的扱いにせず即座に失敗するので、
  取りこぼしは「すぐに exit 1/2 で止まり、応答の本文が残る」形で表に出る
- モック CLI に同じ形の応答を返すシナリオを追加し、回帰テストで確かめている
