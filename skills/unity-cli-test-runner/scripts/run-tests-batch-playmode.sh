#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「PlayModeバッチテスト実行」を1コマンドにまとめる。
# run-playmode-test.sh の複数FullName版。batch_test_status ベースライン取得 →
# run_tests_batch_playmode --async_tests（コマンドレベル失敗も検知）→
# batch_test_status ポーリング → 完了確認 → ベースライン比較（同一full_names連続実行時の
# stale検知）→ 結果に指定full_namesそれぞれの手がかりが含まれるかの簡易整合性チェック、を
# 順に実行する。全体の構造は run-playmode-test.sh と同一で、呼び出すコマンド名とポーリング先
# のみ run_tests_batch_playmode / batch_test_status に差し替えている。
#
# 使い方: run-tests-batch-playmode.sh <カンマ区切りFullName> [timeout(既定120)] [ポーリング予算秒数(既定90)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  結果確定（PASS/FAILは問わない）。標準出力のJSON（batch_test_status由来の中身オブジェクト。
#      status/duration/summary/results を含む）を読み、通常の結果報告に進んでよい
#   2  ハング・タイムアウト（ポーリング予算超過、`unity cmd`呼び出し自体の失敗を含む）、または
#      run_tests_batch_playmode がUnity側で受理されなかった場合
#   3  完了は検知したが結果がstaleと疑われる（ベースライン完全一致、またはfull_namesのいずれかの
#      手がかりが結果に見当たらない）

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "使い方: run-tests-batch-playmode.sh <カンマ区切りFullName> [timeout(既定120)] [ポーリング予算秒数(既定90)]" >&2
  exit 2
fi

FULL_NAMES="$1"
CLI_TIMEOUT="${2:-120}"
POLL_BUDGET_SECONDS="${3:-90}"
POLL_INTERVAL_SECONDS=3

run_unity_cmd() {
  unity cmd "$@" --timeout "$CLI_TIMEOUT"
}

extract_status() {
  local raw="$1"
  echo "$raw" | jq -r '(.data.result | fromjson | .status) // empty' 2>/dev/null || true
}

echo "[1/4] batch_test_status でベースラインを取得（同一full_names連続実行時のstale検知用）" >&2
BASELINE=""
if base_raw="$(run_unity_cmd batch_test_status --json)"; then
  BASELINE="$base_raw"
else
  echo "ベースライン取得(batch_test_status)に失敗しました。セッション内で一度もバッチテストを実行していない場合など正常系の可能性があるため、ベースライン無しのまま続行します。" >&2
  BASELINE=""
fi

echo "[2/4] run_tests_batch_playmode --full_names ${FULL_NAMES} --async_tests true" >&2
if ! RUN_TESTS_RAW="$(run_unity_cmd run_tests_batch_playmode --full_names "$FULL_NAMES" --async_tests true --json)"; then
  echo "run_tests_batch_playmode のunity cmd呼び出し自体が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

RUN_TESTS_SUCCESS="$(echo "$RUN_TESTS_RAW" | jq -r '.data.result.success // empty' 2>/dev/null || true)"
if [ "$RUN_TESTS_SUCCESS" != "true" ]; then
  RUN_TESTS_ERROR="$(echo "$RUN_TESTS_RAW" | jq -r '.data.result.Error // .data.result.error // "(no error message)"' 2>/dev/null || echo "(no error message)")"
  echo "run_tests_batch_playmode がUnity側で受理されませんでした（.data.result.success が true ではありません）: ${RUN_TESTS_ERROR}" >&2
  exit 2
fi

echo "[3/4] batch_test_status をポーリング（予算 ${POLL_BUDGET_SECONDS}秒）" >&2
elapsed=0
status=""
raw=""
while [ "$elapsed" -lt "$POLL_BUDGET_SECONDS" ]; do
  if ! raw="$(run_unity_cmd batch_test_status --json)"; then
    echo "batch_test_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
  fi

  status="$(extract_status "$raw")"

  case "$status" in
    completed|finished|idle)
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
  completed|finished|idle)
    ;;
  *)
    echo "batch_test_statusが${POLL_BUDGET_SECONDS}秒以内に完了状態になりませんでした（最終状態: ${status:-不明}）。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
    ;;
esac

echo "[4/4] 結果の整合性チェック（ベースライン比較・各full_nameの手がかり確認）" >&2

if [ -n "$BASELINE" ] && [ "$raw" = "$BASELINE" ]; then
  echo "batch_test_statusの結果がrun_tests_batch_playmode発行前のベースラインと完全一致しました。新しい実行結果を確認できませんでした（stale結果の疑い）。" >&2
  echo "$raw" | jq '.data.result | fromjson' 2>/dev/null || echo "$raw"
  exit 3
fi

IFS=',' read -ra NAMES <<< "$FULL_NAMES"
for name in "${NAMES[@]}"; do
  trimmed="$(echo "$name" | sed 's/^ *//; s/ *$//')"
  if ! echo "$raw" | grep -qF "$trimmed"; then
    echo "batch_test_statusの結果に完全名「${trimmed}」の手がかりが見当たりません（取り違えの疑い）。" >&2
    echo "$raw" | jq '.data.result | fromjson' 2>/dev/null || echo "$raw"
    exit 3
  fi
done

echo "$raw" | jq '.data.result | fromjson'
exit 0
