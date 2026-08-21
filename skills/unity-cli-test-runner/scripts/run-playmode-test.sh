#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「PlayModeテスト実行」を1コマンドにまとめる。
# test_status ベースライン取得 → run_tests --mode PlayMode --async_tests（コマンドレベル失敗も検知）→
# test_status ポーリング → 完了確認 → ベースライン比較（同一filter連続実行時のstale検知）→
# 結果に指定filterの手がかりが含まれるかの簡易整合性チェック（異なるfilterへの取り違え検知）、を
# 順に実行する。
#
# 使い方: run-playmode-test.sh <filter> <filter_type> [timeout(既定120)] [ポーリング予算秒数(既定90)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  結果確定（PASS/FAILは問わない）。標準出力のJSON（test_status由来の中身オブジェクト。
#      status/duration/summary/results を含む）を読み、通常の結果報告に進んでよい
#   2  ハング・タイムアウト（ポーリング予算超過、`unity cmd`呼び出し自体の失敗を含む）、または
#      run_tests がUnity側で受理されなかった場合（`.data.result.success` が true でない。
#      不正な `--mode` 値など）。スキルの「ハング・タイムアウト時の対応」に従う
#   3  完了は検知したが結果がstaleと疑われる。以下の2パターンがあり、どちらも標準エラー出力の
#      メッセージで区別できる:
#        - test_statusの結果がrun_tests発行前のベースラインと文字列として完全一致（同一filterの
#          連続実行で「前回の完了結果」を取り違えている疑い）。ポーリング中に完了状態かつ
#          ベースラインと一致する応答を受け取った場合は即断せず、ポーリング予算内は完了とみなさず
#          待ち続ける（async_tests発行直後のごく短いレース状態を許容するため）。予算を使い切っても
#          ベースラインと一致したままの場合にのみこのパターンでexit 3となる
#        - test_statusの結果に指定filterの手がかりが見当たらない（異なるfilterへの取り違えの疑い）
#      いずれの場合もUnityコンソールログで InvalidOperationException（TestResultCollector.RunFinished）
#      の有無を確認すること
#
# 注意: test_status --json のレスポンス構造は実地検証済み（2026-08-11）。トップレベルは
#   { success, command, data: { command, parameters, result, target }, errors, warnings }
# の形だが、data.result は他コマンド（run_tests/list_tests）と異なり**JSON文字列として二重
# エンコード**されている点に注意（`jq '.data.result | fromjson'` で中身のオブジェクトを取り出す）。
# 中身のオブジェクトは { status, duration, summary: {total,passed,failed,skipped,inconclusive},
# results: [{FullName,Status,Duration,Message,StackTrace}] } で、summaryとそのキーは小文字、
# results内の各キーはPascalCase（大文字始まり）という混在がある。
# run_tests --json のレスポンスは data.result がネイティブなJSONオブジェクトで、成否は
# data.result.success（真偽値）、失敗時のメッセージは data.result.error に入る
# （トップレベルの .success はCLIコマンドのディスパッチ自体が成功したかを示すのみで、
# 「テストが実際に実行できたか」は示さない）。
#
# 注意: PlayMode突入直後はドメインリロードが発生し、その1〜2秒間 unity cmd が
# "No Unity Editor instances found with reachable Pipeline servers." で失敗することが
# 実測で確認されている（_lib.sh参照）。test_statusポーリング中にこれを検知した場合は
# ハング扱いにせずポーリングを継続する。また、run_tests --async_tests の起動呼び出し
# 自体がこの瞬断に当たることもあるため、こちらは run_unity_cmd_resilient（有限予算の
# 単発リトライ）で吸収する（ADR-0009）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if [ "$#" -lt 2 ]; then
  echo "使い方: run-playmode-test.sh <filter> <filter_type> [timeout(既定120)] [ポーリング予算秒数(既定90)]" >&2
  exit 2
fi

FILTER="$1"
FILTER_TYPE="$2"
CLI_TIMEOUT="${3:-120}"
POLL_BUDGET_SECONDS="${4:-90}"
POLL_INTERVAL_SECONDS=3
ONESHOT_RETRY_BUDGET_SECONDS=15

run_unity_cmd() {
  unity cmd "$@" --timeout "$CLI_TIMEOUT"
}

# test_status --json の生レスポンスから中身のstatus文字列を取り出す。
# data.result はJSON文字列として二重エンコードされているため fromjson で1段階デコードする。
# 構造が想定と異なりjqが失敗/空を返した場合は呼び出し元でgrepフォールバックする。
extract_status() {
  local raw="$1"
  echo "$raw" | jq -r '(.data.result | fromjson | .status) // empty' 2>/dev/null || true
}

echo "[1/4] test_status でベースラインを取得（同一filter連続実行時のstale検知用）" >&2
BASELINE=""
if base_raw="$(run_unity_cmd test_status --json)"; then
  BASELINE="$base_raw"
else
  echo "ベースライン取得(test_status)に失敗しました。セッション内で一度もテストを実行していない場合など正常系の可能性があるため、ベースライン無しのまま続行します。" >&2
  BASELINE=""
fi

echo "[2/4] run_tests --mode PlayMode --filter ${FILTER} --filter_type ${FILTER_TYPE} --async_tests" >&2
if ! RUN_TESTS_RAW="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" run_tests --mode PlayMode --filter "$FILTER" --filter_type "$FILTER_TYPE" --async_tests --json)"; then
  echo "run_tests のunity cmd呼び出し自体が失敗/タイムアウトしました（一時的なドメインリロード切断のリトライ予算超過を含む）。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

RUN_TESTS_SUCCESS="$(echo "$RUN_TESTS_RAW" | jq -r '.data.result.success // empty' 2>/dev/null || true)"
if [ "$RUN_TESTS_SUCCESS" != "true" ]; then
  RUN_TESTS_ERROR="$(echo "$RUN_TESTS_RAW" | jq -r '.data.result.error // "(no error message)"' 2>/dev/null || echo "(no error message)")"
  echo "run_tests がUnity側で受理されませんでした（.data.result.success が true ではありません）: ${RUN_TESTS_ERROR}" >&2
  exit 2
fi

echo "[3/4] test_status をポーリング（予算 ${POLL_BUDGET_SECONDS}秒）" >&2
elapsed=0
status=""
raw=""
while [ "$elapsed" -lt "$POLL_BUDGET_SECONDS" ]; do
  if ! raw="$(run_unity_cmd test_status --json)"; then
    if is_transient_pipeline_unreachable "$raw"; then
      # PlayMode突入直後のドメインリロードによる一時的な切断とみなし、ハング扱いに
      # せずポーリングを続行する（経過秒数はbudgetから消費されるため、切断が本当に
      # 続けば下のbudget超過チェックで通常通りexit 2になる）
      sleep "$POLL_INTERVAL_SECONDS"
      elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
      continue
    fi
    echo "test_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
  fi

  status="$(extract_status "$raw")"
  if [ -z "$status" ]; then
    # 想定外のレスポンス形式に対する保険。主経路はextract_status（jq）であり、
    # ここは通常発火しない
    for candidate in completed finished idle running in_progress; do
      if echo "$raw" | grep -q "$candidate"; then
        status="$candidate"
        break
      fi
    done
  fi

  case "$status" in
    completed|finished|idle)
      if [ -n "$BASELINE" ] && [ "$raw" = "$BASELINE" ]; then
        # 完了状態ではあるが内容がベースラインと同一 = run_tests発行前の古い結果を
        # まだ読んでいる可能性が高い。ここでは完了とみなさずポーリングを継続する
        # （async_tests発行直後、Unity側の状態遷移がtest_statusの応答に反映されるまでの
        # わずかな遅延で発生しうるレース状態への対策。budget内に新しい結果へ更新されれば
        # 下のbreakに進む。更新されないままbudgetを使い切った場合は、ループ終了後の
        # ベースライン比較チェックでexit 3として扱われる）
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
    echo "test_statusが${POLL_BUDGET_SECONDS}秒以内に完了状態になりませんでした（最終状態: ${status:-不明}）。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
    ;;
esac

echo "[4/4] 結果の整合性チェック（ベースライン比較・filter文字列の手がかり確認）" >&2

if [ -n "$BASELINE" ] && [ "$raw" = "$BASELINE" ]; then
  echo "test_statusの結果がrun_tests発行前のベースラインと完全一致しました。新しい実行結果を確認できませんでした（同一filter連続実行時のstale結果の疑い）。" >&2
  echo "Unityコンソールログで InvalidOperationException(TestResultCollector.RunFinished) の有無を確認してください。" >&2
  echo "$raw" | jq '.data.result | fromjson' 2>/dev/null || echo "$raw"
  exit 3
fi

if ! echo "$raw" | grep -qF "$FILTER"; then
  echo "test_statusの結果に指定filter「${FILTER}」の手がかりが見当たりません（異なるfilterへの取り違えの疑い）。" >&2
  echo "Unityコンソールログで InvalidOperationException(TestResultCollector.RunFinished) の有無を確認してください。" >&2
  echo "$raw" | jq '.data.result | fromjson' 2>/dev/null || echo "$raw"
  exit 3
fi

echo "$raw" | jq '.data.result | fromjson'
exit 0
