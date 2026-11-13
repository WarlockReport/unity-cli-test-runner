#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「PlayModeバッチテスト実行」を1コマンドにまとめる。
# run-playmode-test.sh の複数FullName版。wr.testrunner batch_test_status ベースライン取得 →
# wr.testrunner run_tests_batch_playmode --async-tests（コマンドレベル失敗も検知）→
# wr.testrunner batch_test_status ポーリング → 完了確認 → ベースライン比較（同一full-names連続実行時の
# stale検知）→ 結果に指定full-namesそれぞれの手がかりが含まれるかの簡易整合性チェック、を
# 順に実行する。全体の構造は run-playmode-test.sh と同一で、呼び出すコマンド名とポーリング先
# のみ wr.testrunner run_tests_batch_playmode / wr.testrunner batch_test_status に差し替えている。
#
# 使い方: run-tests-batch-playmode.sh <カンマ区切りFullName> [timeout(既定120)] [ポーリング予算秒数(既定90)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  結果確定（PASS/FAILは問わない）。標準出力のJSON（wr.testrunner batch_test_status由来の中身オブジェクト。
#      status/duration/summary/results を含む）を読み、通常の結果報告に進んでよい
#   1  引数付きケースの FullName（括弧を含む名前。例: Ns.Class.Method(First,2)）が指定された。実行はしない。
#      名前の中のカンマで区切りが割れるため。引数部分を外したメソッドの FullName を重複を除いて渡し直す
#      （そのメソッドの全ケースが実行される）
#   2  ハング・タイムアウト（ポーリング予算超過、`unity cmd`呼び出し自体の失敗を含む）、
#      wr.testrunner run_tests_batch_playmode がUnity側で受理されなかった場合、結果を持たない終端状態
#      （error / cancelled）、またはモーダルダイアログ
#   3  完了は検知したが結果がstaleと疑われる（ベースライン完全一致、またはfull-namesのいずれかの
#      手がかりが結果に見当たらない）。
#      また、版の組み合わせのずれ（コマンドまたは引数が見つからない、unity CLI が古い、UPM パッケージが旧版で
#      応答が PascalCase。標準エラーに診断が出る。再試行せず版を揃えてもらう）もこの終了コードになる
#
# 注意: PlayMode突入直後はドメインリロードが発生し、その1〜2秒間 unity cmd が一時的に失敗することが
# 実測で確認されている（_lib.sh参照）。wr.testrunner batch_test_statusポーリング中にこれを検知した場合は
# ハング扱いにせずポーリングを継続する。また、wr.testrunner run_tests_batch_playmode の起動呼び出し
# 自体がこの瞬断に当たることもあるため、こちらは run_unity_cmd_resilient（有限予算の
# 単発リトライ）で吸収する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if [ "$#" -lt 1 ]; then
  echo "使い方: run-tests-batch-playmode.sh <カンマ区切りFullName> [timeout(既定120)] [ポーリング予算秒数(既定90)]" >&2
  exit 2
fi

FULL_NAMES="$1"
exit_on_parameterized_case_names "$FULL_NAMES" "run-tests-batch-playmode.sh"
CLI_TIMEOUT="${2:-120}"
POLL_BUDGET_SECONDS="${3:-90}"
ONESHOT_RETRY_BUDGET_SECONDS=15

echo "[1/4] wr.testrunner batch_test_status でベースラインを取得（同一full-names連続実行時のstale検知用）" >&2
BASELINE="$(read_own_batch_baseline "$CLI_TIMEOUT")"
[ -n "$BASELINE" ] || echo "  ベースラインを取得できませんでした（セッション内で一度もバッチテストを実行していない場合など正常系の可能性があります）。ベースライン無しで続行します。" >&2

echo "[2/4] wr.testrunner run_tests_batch_playmode --full-names ${FULL_NAMES} --async-tests true" >&2
RUN_TESTS_RAW="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" wr.testrunner run_tests_batch_playmode --full-names "$FULL_NAMES" --async-tests true --json)" && rc=0 || rc=$?
accept_own_playmode_start "$rc" "$RUN_TESTS_RAW" run-tests-batch-playmode.sh "wr.testrunner run_tests_batch_playmode"

echo "[3/4] wr.testrunner batch_test_status をポーリング（予算 ${POLL_BUDGET_SECONDS}秒）" >&2
poll_own_batch_status "$CLI_TIMEOUT" "$POLL_BUDGET_SECONDS" "$BASELINE" run-tests-batch-playmode.sh

echo "[4/4] 結果の整合性チェック（ベースライン比較・各full_nameの手がかり確認）" >&2
if [ -n "$BASELINE" ] && [ "$OWN_STATUS_NORMALIZED" = "$BASELINE" ]; then
  echo "wr.testrunner batch_test_statusの結果がwr.testrunner run_tests_batch_playmode発行前のベースラインと完全一致しました。新しい実行結果を確認できませんでした（stale結果の疑い）。" >&2
  printf '%s\n' "$OWN_STATUS_PAYLOAD"
  exit 3
fi

IFS=',' read -ra NAMES <<< "$FULL_NAMES"
for name in "${NAMES[@]}"; do
  trimmed="$(echo "$name" | sed 's/^ *//; s/ *$//')"
  if ! printf '%s' "$OWN_STATUS_PAYLOAD" | grep -qF "$trimmed"; then
    echo "wr.testrunner batch_test_statusの結果に完全名「${trimmed}」の手がかりが見当たりません（取り違えの疑い）。" >&2
    printf '%s\n' "$OWN_STATUS_PAYLOAD"
    exit 3
  fi
done

printf '%s\n' "$OWN_STATUS_PAYLOAD"
exit 0
