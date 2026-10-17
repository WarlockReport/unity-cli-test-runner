# ADR-0023: `unity cmd` が一時的でない理由で失敗したとき、その応答を標準エラーに出す

## Status

Accepted (2026-10-17)

## Context

- ADR-0022 の実機検証中、TestProject に対して `run-playmode-test.sh <アセンブリ名> assembly` を実行したところ、1 回だけ exit 2
  （「test_status が失敗/タイムアウトしました」）で終わった。直後に `test_status` を手で叩くと正常な完了結果が返り、同じ実行を
  2 回繰り返しても再現しなかった
- 標準エラーにはスクリプト自身のメッセージしか残っておらず、失敗の理由を辿れなかった
- `run_unity_cmd_capture`（`_lib.sh`）は `unity cmd` の標準エラーを素通りさせるが、`--json` を付けた呼び出しは失敗時も理由
  （`.errors[].message` 等）を標準出力の JSON に載せ、標準エラーが空のことがある。各スクリプトは失敗分岐でその標準出力を
  変数に取り込んだまま捨てていた。`unity cmd` 自体の終了コードも残していなかった
- 同じ形の失敗分岐は、ポーリング（`test_status` / `batch_test_status` / `recompile_status` / `editor_status`）と、
  単発の呼び出し（`run_tests` / `run_tests_batch_*` / `clear_console` / `recompile` / `recompile_status`）の両方にあった

## Decision

- `run_unity_cmd_capture` が `unity cmd` の終了コードを `UNITY_CMD_RC` に残す
- `_lib.sh` に `report_unity_cmd_failure <応答> [終了コード]` を置き、応答（先頭 40 行）と終了コードを標準エラーに出す。
  応答が空なら「空だった（応答前のタイムアウトか CLI 自体の失敗の可能性）」と出す
- 各スクリプトの「失敗/タイムアウトしました」で exit 2（`ensure-compile-clean.sh` の内部関数では return 2）する分岐から呼ぶ。
  ポーリングでは `UNITY_CMD_OUT` と `UNITY_CMD_RC` を、単発の呼び出しでは `run_unity_cmd_resilient` の出力を渡す
- 終了コードの意味と標準出力（生 JSON）の約束は変えない。出力を増やすのは標準エラーだけにする
- モック CLI に、標準出力に失敗の JSON を出して標準エラーは空のまま失敗するシナリオ（`pm-status-error`）を加え、
  `run-playmode-test.sh` / `run-tests-batch-playmode.sh` が exit 2 になり、応答と終了コードを標準エラーに出すことを回帰テストで確かめる

## Consequences

- 一時的でない失敗で止まったとき、`unity cmd` が返した理由と終了コードを、スクリプトの出力だけで辿れるようになる
- 今回の 1 回きりの exit 2 の原因は分かっていない。次に同じ失敗が起きたときに、追加した出力から原因を調べる
- 一時的失敗のリトライ予算を使い切った場合（`run_unity_cmd_resilient` の戻り値 2）は、すでに素通りさせた標準エラーの内容が
  もう一度出る。重複はあるが、失敗の最後の応答を確実に残すことを優先する
