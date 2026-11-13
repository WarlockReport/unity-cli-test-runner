#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「PlayMode 絞り込み実行」を 1 コマンドにまとめる。
# run-tests-filtered-editmode.sh の PlayMode 版。test list による名前の存在確認 →
# wr.testrunner batch_test_status ベースライン取得 → wr.testrunner run_tests_filtered_playmode --async-tests →
# wr.testrunner batch_test_status ポーリング → 完了確認 → 完了ステータスの requestId と起動応答の requestId の照合、
# を順に実行する。全体の構造は run-tests-batch-playmode.sh と同じで、整合性チェックだけが異なる
# （除外で絞り込む実行では「指定した名前が結果に含まれるか」を手がかりにできないため、実行ごとの requestId で
# 前回の実行結果を読んでいないかを確かめる）。
#
# 使い方: run-tests-filtered-playmode.sh [--assembly <アセンブリ名>] [--exclude <カンマ区切りFullName>]
#           [--include-category <カンマ区切り>] [--exclude-category <カンマ区切り>]
#           [--timeout <秒(既定300)>] [--poll-budget <ポーリング予算秒(既定90)>]
#   各オプションの意味は run-tests-filtered-editmode.sh と同じ（省略時の基準は PlayMode の全アセンブリ）
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  結果確定（PASS/FAILは問わない）。標準出力のJSON（wr.testrunner batch_test_status由来の中身オブジェクト。
#      status/duration/summary/results/requestId を含む）を読み、通常の結果報告に進んでよい。
#      指定の組み合わせに当たるテストが 0 件だった場合も 0（標準エラーに 0 件であることを出す）
#   1  実行していない。絞り込み条件が無い、除く名前に引数付きケースの FullName（括弧を含む名前）がある、
#      または指定した名前が test list に見つからない（標準エラーに見つからない名前を列挙する）
#   2  使い方の誤り（未知の引数・値の欠落）、ハング・タイムアウト（ポーリング予算超過、`unity cmd`呼び出し自体の
#      失敗を含む）、wr.testrunner run_tests_filtered_playmode がUnity側で受理されなかった、結果を持たない終端状態
#      （error / cancelled）、またはモーダルダイアログ
#   3  完了は検知したが結果がstaleと疑われる（完了ステータスの requestId が起動応答の requestId と一致しない）。
#      また、版の組み合わせのずれ（コマンドまたは引数が見つからない、unity CLI が古い、UPM パッケージが旧版で応答が
#      PascalCase、起動応答に requestId が無い。再試行せず版を揃えてもらう）、test list の応答が
#      想定外の形の場合もこの終了コードになる
#
# 注意: PlayMode突入直後のドメインリロードで、その1〜2秒間 unity cmd が一時的に失敗する（_lib.sh参照）。
# ポーリング中はこれをハング扱いにせず続行し、起動呼び出しは run_unity_cmd_resilient で吸収する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

SCRIPT_NAME="run-tests-filtered-playmode.sh"
USAGE="${SCRIPT_NAME} [--assembly <名前>] [--exclude <カンマ区切りFullName>] [--include-category <カンマ区切り>] [--exclude-category <カンマ区切り>] [--timeout <秒>] [--poll-budget <秒>]"
ONESHOT_RETRY_BUDGET_SECONDS=15

parse_filtered_args "$SCRIPT_NAME" "$USAGE" "$@"
CLI_TIMEOUT="$SEL_TIMEOUT"
POLL_BUDGET_SECONDS="$SEL_POLL_BUDGET"

echo "[1/5] 絞り込み条件の名前を確認" >&2
exit_on_unknown_selection PlayMode 30 "$SCRIPT_NAME"

echo "[2/5] wr.testrunner batch_test_status でベースラインを取得" >&2
BASELINE="$(read_own_batch_baseline "$CLI_TIMEOUT")"
[ -n "$BASELINE" ] || echo "  ベースラインを取得できませんでした（セッション内で一度もバッチテストを実行していない場合など正常系の可能性があります）。ベースライン無しで続行します。" >&2

# 指定された絞り込み条件だけをコマンドに渡す（空の引数を渡すと「指定あり」と区別がつかないため）
cmd_args=()
[ -n "$SEL_ASSEMBLY" ] && cmd_args+=(--assembly "$SEL_ASSEMBLY")
[ -n "$SEL_INCLUDE_CATEGORY" ] && cmd_args+=(--include-categories "$SEL_INCLUDE_CATEGORY")
[ -n "$SEL_EXCLUDE_CATEGORY" ] && cmd_args+=(--exclude-categories "$SEL_EXCLUDE_CATEGORY")
[ -n "$SEL_EXCLUDE" ] && cmd_args+=(--exclude-names "$SEL_EXCLUDE")

echo "[3/5] wr.testrunner run_tests_filtered_playmode ${cmd_args[*]} --async-tests true" >&2
RUN_RAW="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" wr.testrunner run_tests_filtered_playmode "${cmd_args[@]}" --async-tests true --json)" && rc=0 || rc=$?
accept_own_playmode_start "$rc" "$RUN_RAW" "$SCRIPT_NAME" "wr.testrunner run_tests_filtered_playmode"

REQUEST_ID="$(printf '%s' "$OWN_START_PAYLOAD" | jq -r '.requestId // empty' 2>/dev/null || true)"
if [ -z "$REQUEST_ID" ]; then
  echo "wr.testrunner run_tests_filtered_playmode の応答に requestId がありません。今回の実行結果を見分けられないため、結果を読みません。" >&2
  echo "  プラグインとUPMパッケージ（com.warlockreport.unity-cli-test-runner）の版の組み合わせが揃っていない可能性があります。" >&2
  report_unity_cmd_failure "$RUN_RAW"
  exit 3
fi

echo "[4/5] wr.testrunner batch_test_status をポーリング（予算 ${POLL_BUDGET_SECONDS}秒）" >&2
poll_own_batch_status "$CLI_TIMEOUT" "$POLL_BUDGET_SECONDS" "$BASELINE" "$SCRIPT_NAME"

echo "[5/5] 結果の整合性チェック（requestId の照合）" >&2
result_request_id="$(printf '%s' "$OWN_STATUS_PAYLOAD" | jq -r '.requestId // empty' 2>/dev/null || true)"
if [ "$result_request_id" != "$REQUEST_ID" ]; then
  echo "wr.testrunner batch_test_statusの結果の requestId（${result_request_id:-なし}）が、今回の起動応答の requestId（${REQUEST_ID}）と一致しません。別の実行の結果を読んでいる疑いがあります（stale結果の疑い）。" >&2
  printf '%s\n' "$OWN_STATUS_PAYLOAD"
  exit 3
fi

if [ "$(printf '%s' "$OWN_STATUS_PAYLOAD" | jq -r '.summary.total // empty' 2>/dev/null || true)" = "0" ]; then
  echo "指定の組み合わせに当たるテストが 0 件でした（名前はすべて実在するが、含める条件と除く条件を合わせると何も残らない）。" >&2
fi

printf '%s\n' "$OWN_STATUS_PAYLOAD"
exit 0
