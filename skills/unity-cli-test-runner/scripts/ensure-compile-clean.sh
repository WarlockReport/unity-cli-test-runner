#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「1. コンパイル状態の確定」ステップを1コマンドにまとめる。
# clear_console → recompile → recompile_status ポーリング → get_console_logs(error) を順に実行し、
# コンパイルが確定していて（Unity側が変更を反映しきっていて）、かつエラーが無いかを確認する。
#
# 使い方: ensure-compile-clean.sh [ポーリング予算秒数(既定60)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  コンパイル確定・エラー無し。テスト対象の解決へ進んでよい
#   1  コンパイルエラーを検出した（詳細は標準出力）。テスト対象の解決へ進まず報告する
#   2  recompile_statusがcompleted/up_to_dateにならない、またはunity cmd呼び出し自体が
#      失敗/タイムアウトした。盲目的に再試行せず、スキルの「ハング・タイムアウト時の対応」に従う
#   3  get_console_logsの返り値の形式が想定と異なり、エラー有無を確実に判定できなかった。
#      標準出力の生JSONを確認して手動判断する
#
# 注意: recompile_status/get_console_logsの正確なJSONフィールド名は設計時点で未検証。
# 複数の候補フィールド名を試すフォールバックを入れているが、実地検証で実際の形式が判明したら
# このスクリプトのjqフィルタを確定値に更新すること。

set -euo pipefail

POLL_BUDGET_SECONDS="${1:-60}"
POLL_INTERVAL_SECONDS=3
CLI_TIMEOUT=30

run_unity_cmd() {
  unity cmd "$@" --timeout "$CLI_TIMEOUT"
}

echo "[1/4] clear_console" >&2
if ! run_unity_cmd clear_console >/dev/null; then
  echo "clear_console が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

echo "[2/4] recompile" >&2
if ! run_unity_cmd recompile >/dev/null; then
  echo "recompile が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

echo "[3/4] recompile_status をポーリング（予算 ${POLL_BUDGET_SECONDS}秒）" >&2
elapsed=0
status=""
while [ "$elapsed" -lt "$POLL_BUDGET_SECONDS" ]; do
  if ! raw="$(run_unity_cmd recompile_status)"; then
    echo "recompile_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
  fi

  status="$(echo "$raw" | jq -r '.status // .recompileStatus // .state // empty' 2>/dev/null || true)"
  if [ -z "$status" ]; then
    for candidate in up_to_date completed triggered compiling idle; do
      if echo "$raw" | grep -q "$candidate"; then
        status="$candidate"
        break
      fi
    done
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
    echo "recompile_statusが${POLL_BUDGET_SECONDS}秒以内にcompleted/up_to_dateになりませんでした（最終状態: ${status:-不明}）。ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
    ;;
esac

echo "[4/4] get_console_logs --severity error" >&2
if ! logs_raw="$(run_unity_cmd get_console_logs --severity error --limit 20)"; then
  echo "get_console_logs が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

error_count="$(echo "$logs_raw" | jq -r 'if (.logs // .entries // .results) == null then "unknown" else (.logs // .entries // .results | length) end' 2>/dev/null || true)"

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
