# ADR-0029: ドメインリロード回数（`codeLoadCount`）によるコンパイル完了の判定

## Status

Accepted (2026-11-08)

## Context

`ensure-compile-clean.sh` は、`script recompile` の後に `script recompile_status` を 3 秒間隔でポーリングし、続けて
`editor status` の `compiling` / `domainReloadInProgress` が 2 回連続で false になるまで（3 秒間隔）待っていた
（[ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) の (b) 対策。`recompile_status` が完了を報告した後、
リロードが始まる前の一瞬を「落ち着いた」と取り違えるレースを、2 回連続の確認で避けていた）。誤判定は起きていなかったが、
待ち時間がかさんでいた。

`com.unity.pipeline` 0.10.0-exp.1 で `editor status` の `.data.result` に `codeLoadCount`（整数）と `autoRefresh`（文字列）が加わった。
TestProject（Unity 6000.3.25f1、`unity` CLI 1.0.0-beta.13）で実測した。

- コードを変更して `script recompile` した前後の `editor status`（0.5 秒間隔）:
  変更前 ready / 回数 1 → recompile 直後 compiling:true / 回数 1 → +1 秒 接続失敗（リロード中の一時切断）→
  +2 秒 ready / 回数 **2** → 以後 ready / 2
- `codeLoadCount` はリロードをまたいで保持され、**リロードが終わって ready に戻った時点で 1 増える**
- `script recompile` は完了を待たずに `{"status":"compiling","message":"Recompilation started. Poll script recompile_status until completed."}`
  を返す。変更が無ければ `{"status":"up_to_date"}`
- コンパイルエラーのときはリロードが起きず、回数は増えない。`script recompile_status` が `completed, failed:true, compilationFailed:true` を返す
- **コメントだけの変更でもリロードは起き、回数は増える**（コメント 1 行追加で 3 → 4。2026-11-08 実測）。
  「コンパイルは成功したがリロードが起きない」場合は観測されなかったため、回数が増えないまま成功とみなす逃げ道は作らない
- リロード中の一時切断は、0.10 + CLI 1.0.0-beta.13 では `Failed to execute command 'editor': Invalid response format from Pipeline server`
  （終了コード 6）としても現れる（2026-11-08 実測）。1 秒間隔のポーリングではこの窓に当たりやすく、実装中の実地検証で
  これを一時的失敗として扱っていなかったために終了コード 2 になる事例を確認した
- 旧実装の所要時間（各 1 回）: 変更なし 7.0 秒 / 変更あり 11.1 秒（実際のコンパイル約 3 秒）/ コンパイルエラー 7.7 秒

## Decision

`ensure-compile-clean.sh` の流れを次にする（ポーリング間隔 1 秒、予算の既定 60 秒と自動リカバリは維持）。

1. `console clear`
2. `editor status` で `codeLoadCount` の基準値を取る。整数で取れなければ版の組み合わせのずれとして終了コード 3
   （0.9 以前向けの代替判定は持たない）。`compiling` か `domainReloadInProgress` が true（Auto Refresh などでエディタ側の
   コンパイル・リロードがすでに走っている）なら、両方 false になるまで待ってから取り直す。リロードの最中に基準値を取ると、
   その進行中のリロードで回数が増えただけで「今回のリロードが終わった」と取り違えるため
3. `script recompile`。`failed` は従来どおり詳細取得へ。`up_to_date` は `editor status` を 1 回読み、落ち着いていれば完了待ちを
   省く（落ち着いていなければ 4 へ合流）。それ以外は 4 へ
4. 完了待ち。`editor status` で「回数が基準値より増え、`compiling` / `domainReloadInProgress` が両方 false」を 1 回確かめたら完了
   （2 回連続の確認はしない。回数はリロードが終わった時点で増えるので、回数が増えたこと自体がリロードを越えた証拠になり、
ADR-0007 の (b) のレース〔リロード前の一瞬を落ち着いたと取り違える〕は起きない）。回数据え置きのまま落ち着いているときだけ
   `script recompile_status` を読み、`failed` / `compilationFailed` が true なら終端（コンパイルエラー。リロードは起きない）。
   前回のコンパイルエラーの結果が `script recompile_status` に残っていても、エディタが落ち着いていて回数据え置きの
   ときに限るので、新しいコンパイルの途中でそれを拾わない。一時的失敗は吸収し、ダイアログ判定（終了コード 4）は従来どおり
5. 予算超過時は従来の自動リカバリ（`editor status` で ready を裏取りできた場合に限り 1 回だけやり直す）
6. `script recompile_status` を読み直して判定し、エラーなら `console get` で詳細を出す（従来どおり）

あわせて `_lib.sh` の一時的失敗の定義に `Invalid response format from Pipeline server` を加える。

## Consequences

- 1 回のポーリングで `editor status` と（回数据え置きで落ち着いているときだけ）`script recompile_status` を叩くので、
  Pipeline への呼び出し頻度は 3 秒に 1 回から 1 秒に 1〜2 回に増える。ローカルホスト宛てで実害は小さいと判断した
- 全体の最大所要時間は「予算の 4 倍強」から「3 倍強」（基準値待ち＋完了待ち＋自動リカバリ 1 回）になる
- `codeLoadCount` の無い Pipeline では動かない（ADR-0028 で 0.10 専用にした）

### 所要時間の比較（実測）

TestProject（Unity 6000.3.25f1 + 0.10.0-exp.1）で、検証用の `.cs` を 1 本置いて `ensure-compile-clean.sh` を実行した（2026-11-08）。
「修正直後」は、コンパイルエラーで exit 1 を返した直後にエラーを直して実行した場合（前回のエラーの結果を拾わないことの確認）。

| 場合 | 旧実装（各 1 回） | 新実装 1 回目 | 2 回目 | 3 回目 | 終了コード |
| --- | --- | --- | --- | --- | --- |
| 変更なし（up_to_date） | 7.0 秒 | 3.5 秒 | 3.5 秒 | 3.5 秒 | 0 |
| 変更あり | 11.1 秒 | 5.5 秒 | 5.6 秒 | 5.5 秒 | 0 |
| コンパイルエラー | 7.7 秒 | 4.8 秒 | 4.8 秒 | 4.8 秒 | 1 |
| エラーの修正直後 | — | 5.5 秒 | 5.4 秒 | 5.5 秒 | 0 |

- 変更ありで exit 0 が返った直後の `editor status` は毎回 ready で、`codeLoadCount` は実行前より 1 増えていた
- 変更なしの 3.5 秒の内訳は、`console clear`・`editor status`（基準値）・`script recompile`・`editor status`（確認）・
  `script recompile_status`（判定）の 5 回の呼び出し（1 回あたり 0.7 秒前後）

### その他の実地検証（2026-11-08）

- **Auto Refresh 有効**: `.cs` を書き換えた直後に実行（3 回）、書き換え後にエディタを前面化して Auto Refresh を起こした直後に実行
  （3 回）、先に `script recompile` を投げてエディタ側のコンパイルを走らせた直後に実行（3 回）。いずれも exit 0 で、
  exit 0 直後の `editor status` は ready、回数は書き換え・コンパイルによるリロード分まで増えていた。最後の形では、
  スクリプトは進行中のリロードが終わってから基準値を取り（基準値＝実行前の回数＋1）、`script recompile` が `up_to_date` を
  返して完了待ちを省いた。Auto Refresh とスクリプトの `script recompile` が重なった場合は 1 回のリロードにまとまった
- **ダイアログブロック**: シーンを dirty にして保存確認ダイアログを開いたまま実行すると、`console clear` が 30 秒で
  タイムアウトした後、exit 4 とダイアログを閉じる案内を返した（31.4 秒）
- **版のずれ**: Pipeline を 0.9.1-exp.1 に戻すと exit 3（`editor status` に `codeLoadCount` が無い）
