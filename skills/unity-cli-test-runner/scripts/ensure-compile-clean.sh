#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「1. コンパイル状態の確定」ステップを1コマンドにまとめる。
# clear_console → recompile → recompile_status ポーリング → editor_status によるドメインリロード
# 完了の安定確認 → get_console_logs(error) を順に実行し、コンパイルが確定していて（Unity側が
# 変更を反映しきっていて）、かつエラーが無いかを確認する。
#
# 使い方: ensure-compile-clean.sh [ポーリング予算秒数(既定60)]
#
# 注意: 引数のポーリング予算秒数は、recompile_statusポーリング（ステップ3）と
# editor_statusによる安定確認（ステップ4）の両方に個別に適用される（elapsedはステップごとに
# リセットされる）。そのため、両ステップが共に予算いっぱいまでかかった場合、この関数全体の
# 所要時間は最大で「引数の2倍」になりうる（既定なら最大120秒）。
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  コンパイル確定・エラー無し。テスト対象の解決へ進んでよい
#   1  コンパイルエラーを検出した（詳細は標準出力）。テスト対象の解決へ進まず報告する
#   2  recompile_statusがcompleted/up_to_dateにならない、ドメインリロードが安定して完了しない、
#      またはunity cmd呼び出し自体が（一時的なPipeline切断のリトライ予算を使い切ってもなお）
#      失敗/タイムアウトした。盲目的に再試行せず、スキルの「ハング・タイムアウト時の対応」に従う
#   3  get_console_logsの返り値の形式が想定と異なり、エラー有無を確実に判定できなかった。
#      標準出力の生JSONを確認して手動判断する
#
# 注意（実測済み、2026-08-21）:
# - `unity cmd` は `--json` を付けない場合、TSV形式（`Command\tSuccess\tResult\tParameters`）で
#   応答を返す。jqでパースする呼び出しには必ず `--json` を付けること（付け忘れると空文字列に
#   フォールバックし続け、ポーリングが常にタイムアウトする）
# - recompile_status --json の data.result は他コマンド（run_tests/list_tests）と異なり
#   JSON文字列として二重エンコードされている（test_statusと同じ形）。中身は
#   {status, failed, errors} で、statusは triggered/compiling/completed/up_to_date を取る。
#   `jq '.data.result | fromjson | .status'` で取り出す
# - editor_status --json / get_console_logs --json の data.result はネイティブなJSONオブジェクト
#   （二重エンコードされていない）。editor_statusは {status, compiling, domainReloadInProgress,
#   playMode, ...}、get_console_logsは {total, returned, logs: [...]}
# - コンパイル完了直後、ドメインリロード（アセンブリの再読み込み）の間の1〜2秒、Unity側の
#   Pipelineサーバーが一時的にダウンし、recompile_statusが completed/up_to_date を報告した
#   直後にすら unity cmd 呼び出しが失敗しうる。そのため recompile_status が完了状態を報告した
#   だけでは「確定」とみなさず、editor_status の compiling/domainReloadInProgress が両方falseで
#   2回連続安定するまで確認してから終了する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

POLL_BUDGET_SECONDS="${1:-60}"
POLL_INTERVAL_SECONDS=3
CLI_TIMEOUT=30
ONESHOT_RETRY_BUDGET_SECONDS=15
SETTLE_REQUIRED_COUNT=2

run_unity_cmd() {
  unity cmd "$@" --timeout "$CLI_TIMEOUT"
}

echo "[1/5] clear_console" >&2
if ! run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" clear_console >/dev/null; then
  echo "clear_console が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

echo "[2/5] recompile" >&2
if ! run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" recompile >/dev/null; then
  echo "recompile が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

echo "[3/5] recompile_status をポーリング（予算 ${POLL_BUDGET_SECONDS}秒）" >&2
elapsed=0
status=""
while [ "$elapsed" -lt "$POLL_BUDGET_SECONDS" ]; do
  if raw="$(run_unity_cmd recompile_status --json)"; then
    status="$(echo "$raw" | jq -r '.data.result | fromjson | .status' 2>/dev/null || true)"
  elif is_transient_pipeline_unreachable "$raw"; then
    # ドメインリロード中の一時的な切断とみなし、ハング扱いにせずポーリングを続行する
    # （経過秒数はbudgetから消費されるため、切断が本当に続けば下のbudget超過チェックで
    # 通常通りexit 2になる）
    echo "  Pipeline一時切断を検知（ドメインリロード中の可能性）。ポーリング継続。" >&2
    status=""
  else
    echo "recompile_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
  fi

  case "$status" in
    completed|up_to_date)
      break
      ;;
  esac

  sleep "$POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
done

case "$status" in
  completed|up_to_date)
    ;;
  *)
    if is_transient_pipeline_unreachable "${raw:-}"; then
      echo "recompile_statusが${POLL_BUDGET_SECONDS}秒以内にcompleted/up_to_dateになりませんでした。Pipeline切断がbudget全体を通じて解消しませんでした（一時的なドメインリロードではなく、エディタが本当に落ちている可能性）。ハング・タイムアウト時の対応に従ってください。" >&2
    else
      echo "recompile_statusが${POLL_BUDGET_SECONDS}秒以内にcompleted/up_to_dateになりませんでした（最終状態: ${status:-不明}）。ハング・タイムアウト時の対応に従ってください。" >&2
    fi
    exit 2
    ;;
esac

echo "[4/5] editor_status でドメインリロード完了の安定確認（${SETTLE_REQUIRED_COUNT}回連続）" >&2
settled_count=0
elapsed=0
while [ "$elapsed" -lt "$POLL_BUDGET_SECONDS" ]; do
  if raw="$(run_unity_cmd editor_status --json)"; then
    compiling="$(echo "$raw" | jq -r '.data.result.compiling' 2>/dev/null || true)"
    domain_reload="$(echo "$raw" | jq -r '.data.result.domainReloadInProgress' 2>/dev/null || true)"
  elif is_transient_pipeline_unreachable "$raw"; then
    # まさにドメインリロード中なので不安定とみなし、連続カウントをリセットして続行する
    echo "  Pipeline一時切断を検知（ドメインリロード中の可能性）。安定確認カウントをリセットして継続。" >&2
    compiling="true"
    domain_reload="true"
  else
    echo "editor_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
  fi

  if [ "$compiling" = "false" ] && [ "$domain_reload" = "false" ]; then
    settled_count=$((settled_count + 1))
    if [ "$settled_count" -ge "$SETTLE_REQUIRED_COUNT" ]; then
      break
    fi
  else
    settled_count=0
  fi

  sleep "$POLL_INTERVAL_SECONDS"
  elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
done

if [ "$settled_count" -lt "$SETTLE_REQUIRED_COUNT" ]; then
  if is_transient_pipeline_unreachable "${raw:-}"; then
    echo "editor_statusのcompiling/domainReloadInProgressが${POLL_BUDGET_SECONDS}秒以内に安定してfalseになりませんでした。Pipeline切断がbudget全体を通じて解消しませんでした（一時的なドメインリロードではなく、エディタが本当に落ちている可能性）。ハング・タイムアウト時の対応に従ってください。" >&2
  else
    echo "editor_statusのcompiling/domainReloadInProgressが${POLL_BUDGET_SECONDS}秒以内に安定してfalseになりませんでした。ハング・タイムアウト時の対応に従ってください。" >&2
  fi
  exit 2
fi

echo "[5/5] get_console_logs --severity error" >&2
if ! logs_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" get_console_logs --severity error --limit 20 --json)"; then
  echo "get_console_logs が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

error_count="$(echo "$logs_raw" | jq -r 'if .data.result.logs == null then "unknown" else (.data.result.logs | length) end' 2>/dev/null || true)"

if ! [[ "$error_count" =~ ^[0-9]+$ ]]; then
  echo "get_console_logsの返り値の形式が想定と異なり、エラー有無を判定できませんでした。以下の生JSONを確認してください:" >&2
  echo "$logs_raw"
  exit 3
fi

if [ "$error_count" -gt 0 ]; then
  echo "コンパイルエラーを${error_count}件検出しました。テスト対象の解決へ進まず、以下を報告してください:"
  echo "$logs_raw"
  exit 1
fi

echo "コンパイル確定・エラー無し。テスト対象の解決へ進んでよい。" >&2
exit 0
