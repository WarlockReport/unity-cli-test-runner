#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「PlayMode 絞り込み実行」を 1 コマンドにまとめる。
# run-tests-filtered-editmode.sh の PlayMode 版。test list による名前の存在確認 →
# wr.testrunner batch_test_status ベースライン取得 → wr.testrunner run_tests_filtered_playmode --async_tests →
# wr.testrunner batch_test_status ポーリング → 完了確認 → 完了ステータスの requestId と起動応答の RequestId の照合、
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
#      失敗を含む）、または wr.testrunner run_tests_filtered_playmode がUnity側で受理されなかった
#   3  完了は検知したが結果がstaleと疑われる（完了ステータスの requestId が起動応答の RequestId と一致しない）。
#      また、unity cmd がコマンドを見つけられなかった場合・起動応答に RequestId が無い場合（プラグイン・UPMパッケージ・
#      com.unity.pipeline の版の組み合わせが揃っていない疑い。再試行せず版を揃えてもらう）、test list の応答が
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
POLL_INTERVAL_SECONDS=3
ONESHOT_RETRY_BUDGET_SECONDS=15

parse_filtered_args "$SCRIPT_NAME" "$USAGE" "$@"
CLI_TIMEOUT="$SEL_TIMEOUT"
POLL_BUDGET_SECONDS="$SEL_POLL_BUDGET"

run_unity_cmd() {
  unity cmd "$@" --timeout "$CLI_TIMEOUT"
}

# wr.testrunner batch_test_status --json の生レスポンスから、中身の指定キーの文字列を取り出す。
extract_status_field() {
  local raw="$1" key="$2" payload
  payload="$(extract_result_payload "$raw")" || return 0
  printf '%s' "$payload" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
}

echo "[1/5] 絞り込み条件の名前を確認" >&2
exit_on_unknown_selection PlayMode 30 "$SCRIPT_NAME"

echo "[2/5] wr.testrunner batch_test_status でベースラインを取得" >&2
BASELINE=""
if base_raw="$(run_unity_cmd wr.testrunner batch_test_status --json)"; then
  BASELINE="$base_raw"
else
  echo "ベースライン取得(wr.testrunner batch_test_status)に失敗しました。セッション内で一度もバッチテストを実行していない場合など正常系の可能性があるため、ベースライン無しのまま続行します。" >&2
fi

# 指定された絞り込み条件だけをコマンドに渡す（空の引数を渡すと「指定あり」と区別がつかないため）
cmd_args=()
[ -n "$SEL_ASSEMBLY" ] && cmd_args+=(--assembly "$SEL_ASSEMBLY")
[ -n "$SEL_INCLUDE_CATEGORY" ] && cmd_args+=(--include_categories "$SEL_INCLUDE_CATEGORY")
[ -n "$SEL_EXCLUDE_CATEGORY" ] && cmd_args+=(--exclude_categories "$SEL_EXCLUDE_CATEGORY")
[ -n "$SEL_EXCLUDE" ] && cmd_args+=(--exclude_names "$SEL_EXCLUDE")

echo "[3/5] wr.testrunner run_tests_filtered_playmode ${cmd_args[*]} --async_tests true" >&2
RUN_RAW="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" wr.testrunner run_tests_filtered_playmode "${cmd_args[@]}" --async_tests true --json)" && rc=0 || rc=$?
exit_on_version_mismatch "$rc" "$RUN_RAW"
if [ "$rc" -ne 0 ]; then
  echo "wr.testrunner run_tests_filtered_playmode のunity cmd呼び出し自体が失敗/タイムアウトしました（一時的なドメインリロード切断のリトライ予算超過を含む）。ハング・タイムアウト時の対応に従ってください。" >&2
  report_unity_cmd_failure "$RUN_RAW"
  exit 2
fi

if [ "$(printf '%s' "$RUN_RAW" | jq -r '.data.result.success // empty' 2>/dev/null || true)" != "true" ]; then
  error_message="$(printf '%s' "$RUN_RAW" | jq -r '.data.result.Error // .data.result.error // "(no error message)"' 2>/dev/null || echo "(no error message)")"
  echo "wr.testrunner run_tests_filtered_playmode がUnity側で受理されませんでした（.data.result.success が true ではありません）: ${error_message}" >&2
  exit 2
fi

REQUEST_ID="$(printf '%s' "$RUN_RAW" | jq -r '.data.result.RequestId // empty' 2>/dev/null || true)"
if [ -z "$REQUEST_ID" ]; then
  echo "wr.testrunner run_tests_filtered_playmode の応答に RequestId がありません。今回の実行結果を見分けられないため、結果を読みません。" >&2
  echo "  プラグインとUPMパッケージ（com.warlockreport.unity-cli-test-runner）の版の組み合わせが揃っていない可能性があります。" >&2
  report_unity_cmd_failure "$RUN_RAW"
  exit 3
fi

echo "[4/5] wr.testrunner batch_test_status をポーリング（予算 ${POLL_BUDGET_SECONDS}秒）" >&2
elapsed=0
status=""
raw=""
while [ "$elapsed" -lt "$POLL_BUDGET_SECONDS" ]; do
  if run_unity_cmd_capture wr.testrunner batch_test_status --json --timeout "$CLI_TIMEOUT"; then
    raw="$UNITY_CMD_OUT"
  else
    if is_transient_failure "$UNITY_CMD_DIAG"; then
      # PlayMode突入直後のドメインリロードによる一時的な切断、またはサーバーのbusy応答とみなし、
      # ハング扱いにせずポーリングを続行する（経過秒数はbudgetから消費される）
      sleep "$POLL_INTERVAL_SECONDS"
      elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
      continue
    fi
    echo "wr.testrunner batch_test_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
    report_unity_cmd_failure "$UNITY_CMD_OUT" "$UNITY_CMD_RC"
    exit 2
  fi

  status="$(extract_status_field "$raw" status)"
  case "$status" in
    completed|finished|idle)
      # 起動前の結果（ベースライン）を読んでいる間は、新しい結果が書かれるまで待つ
      if [ -n "$BASELINE" ] && [ "$raw" = "$BASELINE" ]; then
        sleep "$POLL_INTERVAL_SECONDS"
        elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
        continue
      fi
      break
      ;;
  esac

  sleep "$POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
done

case "$status" in
  completed|finished|idle) ;;
  *)
    echo "wr.testrunner batch_test_statusが${POLL_BUDGET_SECONDS}秒以内に完了状態になりませんでした（最終状態: ${status:-不明}）。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
    ;;
esac

echo "[5/5] 結果の整合性チェック（requestId の照合）" >&2
result_request_id="$(extract_status_field "$raw" requestId)"
if [ "$result_request_id" != "$REQUEST_ID" ]; then
  echo "wr.testrunner batch_test_statusの結果の requestId（${result_request_id:-なし}）が、今回の起動応答の RequestId（${REQUEST_ID}）と一致しません。別の実行の結果を読んでいる疑いがあります（stale結果の疑い）。" >&2
  extract_result_payload "$raw" || printf '%s\n' "$raw"
  exit 3
fi

if [ "$(extract_status_field "$raw" summary | jq -r '.total // empty' 2>/dev/null || true)" = "0" ]; then
  echo "指定の組み合わせに当たるテストが 0 件でした（名前はすべて実在するが、含める条件と除く条件を合わせると何も残らない）。" >&2
fi

extract_result_payload "$raw" || printf '%s\n' "$raw"
exit 0
