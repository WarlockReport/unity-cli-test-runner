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
# リセットされる）。さらに各ステップは予算超過時に1回だけ自動リカバリ（下記参照）を試みるため、
# この関数全体の所要時間は最大で「引数の4倍強」になりうる（既定なら最大240秒＋自動リカバリの
# 直接確認分。直接確認はONESHOT_RETRY_BUDGET_SECONDS＝15秒を上限に一時的失敗のみリトライするため、
# ステップごとに最大15秒、2ステップ分で最大30秒が追加で上乗せされうる）。
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  コンパイル確定・エラー無し。テスト対象の解決へ進んでよい
#   1  コンパイルエラーを検出した（詳細は標準出力）。テスト対象の解決へ進まず報告する
#   2  recompile_statusがcompleted/up_to_dateにならない、ドメインリロードが安定して完了しない、
#      またはunity cmd呼び出し自体が（一時的失敗＝Pipeline切断やサーバーbusyのリトライ予算を
#      使い切ってもなお）失敗/タイムアウトした（下記の自動リカバリを試みても解消しなかった
#      場合を含む）。
#      盲目的に再試行せず、スキルの「ハング・タイムアウト時の対応」に従う
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
# - com.unity.pipeline 0.6.0-exp.1 以降は、同じ状況をサーバーがHTTP 503のbusy応答
#   （retryable=true / busyReason=settling|blocked_by_dialog）で返すこともある。
#   _lib.sh の is_transient_failure が両方をまとめて一時的失敗として扱う
#
# 自動リカバリ（実測済み、2026-08-22、ADR-0011）:
# - 実運用で、ステップ3/4のポーリングが予算超過して exit 2 になった直後にコントローラーが
#   `unity cmd editor_status` を直接叩くと実はreadyだった（＝一時切断が予算を使い切った後に
#   ちょうど解消していた）というケースが6回中2回観測された。これはドメインリロードの想定
#   継続時間（1〜2秒）を超える、より長い一時切断が起きうることを示している
# - このケースをコントローラーへの報告・再ディスパッチという往復に頼らずスクリプト内で
#   自己解決させるため、各ステップは予算超過時に (a) editor_status を直接確認し（この確認自体が
#   一時的失敗に当たって誤判定しないよう、他の単発コマンドと同じ run_unity_cmd_resilient で
#   一時的失敗のみ最大15秒リトライする）、(b) readyが裏取りできた場合に限り、同じポーリングを
#   新しい予算で1回だけやり直す。裏取りできない場合（本当にまだreadyでない場合）は即座に
#   exit 2 とし、盲目的に待ち時間を延ばすことはしない

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

POLL_BUDGET_SECONDS="${1:-60}"
POLL_INTERVAL_SECONDS=3
CLI_TIMEOUT=30
ONESHOT_RETRY_BUDGET_SECONDS=15
SETTLE_REQUIRED_COUNT=2

# editor_status を直接確認する。予算超過後の自動リカバリを試みてよいかどうかの
# 裏取りにのみ使う。この確認自体がたまたま一時的失敗のタイミングに重なって「未回復」と
# 誤判定しないよう、run_unity_cmd_resilient で一時的失敗のみ有限予算（15秒）リトライする
# （盲目的な待機延長ではなく、他の単発コマンドと同じ既存の確認済みイディオム）。
is_editor_ready_now() {
  local raw
  if ! raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" editor_status --json)"; then
    return 1
  fi
  local compiling domain_reload
  compiling="$(echo "$raw" | jq -r '.data.result.compiling' 2>/dev/null || true)"
  domain_reload="$(echo "$raw" | jq -r '.data.result.domainReloadInProgress' 2>/dev/null || true)"
  [ "$compiling" = "false" ] && [ "$domain_reload" = "false" ]
}

# [3/5] recompile_status をポーリングする。
# 戻り値: 0=completed/up_to_dateになった / 1=予算超過（自動リカバリの余地あり） /
#         2=unity cmd呼び出し自体が非一時的な理由で失敗した（リカバリの余地なし）
poll_recompile_status() {
  local budget="$1"
  local elapsed=0
  local status=""
  local raw=""
  while [ "$elapsed" -lt "$budget" ]; do
    if run_unity_cmd_capture recompile_status --json --timeout "$CLI_TIMEOUT"; then
      raw="$UNITY_CMD_OUT"
      status="$(echo "$raw" | jq -r '.data.result | fromjson | .status' 2>/dev/null || true)"
    elif is_transient_failure "$UNITY_CMD_DIAG"; then
      # ドメインリロード中の一時的な切断、またはサーバーのbusy応答（0.6以降）とみなし、
      # ハング扱いにせずポーリングを続行する（経過秒数はbudgetから消費されるため、
      # 解消しなければ下のbudget超過チェックで通常通り戻り値1になる）
      raw="$UNITY_CMD_DIAG"
      echo "  一時的失敗を検知（ドメインリロード中、またはサーバーbusy）。ポーリング継続。" >&2
      status=""
    else
      echo "recompile_status が失敗/タイムアウトしました。" >&2
      return 2
    fi

    case "$status" in
      completed|up_to_date)
        return 0
        ;;
    esac

    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done

  if is_transient_failure "${raw:-}"; then
    echo "recompile_statusが${budget}秒以内にcompleted/up_to_dateになりませんでした（一時的失敗が継続。Pipeline切断、またはサーバーbusy）。" >&2
  else
    echo "recompile_statusが${budget}秒以内にcompleted/up_to_dateになりませんでした（最終状態: ${status:-不明}）。" >&2
  fi
  return 1
}

# [4/5] editor_status で compiling/domainReloadInProgress が両方falseになるのを
# SETTLE_REQUIRED_COUNT回連続で確認する。戻り値の意味はpoll_recompile_statusと同じ。
poll_editor_status_settle() {
  local budget="$1"
  local settled_count=0
  local elapsed=0
  local raw=""
  local compiling domain_reload
  while [ "$elapsed" -lt "$budget" ]; do
    if run_unity_cmd_capture editor_status --json --timeout "$CLI_TIMEOUT"; then
      raw="$UNITY_CMD_OUT"
      compiling="$(echo "$raw" | jq -r '.data.result.compiling' 2>/dev/null || true)"
      domain_reload="$(echo "$raw" | jq -r '.data.result.domainReloadInProgress' 2>/dev/null || true)"
    elif is_transient_failure "$UNITY_CMD_DIAG"; then
      # まさにドメインリロード中、またはサーバーがbusy（0.6以降）なので不安定とみなし、
      # 連続カウントをリセットして続行する
      raw="$UNITY_CMD_DIAG"
      echo "  一時的失敗を検知（ドメインリロード中、またはサーバーbusy）。安定確認カウントをリセットして継続。" >&2
      compiling="true"
      domain_reload="true"
    else
      echo "editor_status が失敗/タイムアウトしました。" >&2
      return 2
    fi

    if [ "$compiling" = "false" ] && [ "$domain_reload" = "false" ]; then
      settled_count=$((settled_count + 1))
      if [ "$settled_count" -ge "$SETTLE_REQUIRED_COUNT" ]; then
        return 0
      fi
    else
      settled_count=0
    fi

    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
  done

  if is_transient_failure "${raw:-}"; then
    echo "editor_statusのcompiling/domainReloadInProgressが${budget}秒以内に安定してfalseになりませんでした（一時的失敗が継続。Pipeline切断、またはサーバーbusy）。" >&2
  else
    echo "editor_statusのcompiling/domainReloadInProgressが${budget}秒以内に安定してfalseになりませんでした。" >&2
  fi
  return 1
}

# 予算超過後の1回限りの自動リカバリ。$2にはリカバリ対象のポーリング関数名を渡す
# （poll_recompile_status または poll_editor_status_settle）。
# 戻り値: 0=リカバリ後に成功 / 非0=失敗（呼び出し元にはこれ以上の区別は不要なので
# 一律非0を返す。「回復未確認で未実施」と「リカバリを試みたが失敗」の違いは、
# ここで出力するメッセージ自体が示すため、呼び出し元の追加メッセージで矛盾させない
# ようにする）
retry_once_if_recovered() {
  local label="$1"
  local poll_fn="$2"
  local budget="$3"

  echo "  予算超過。editor_statusを直接確認し、回復していれば1回だけ自動リカバリします。" >&2
  if ! is_editor_ready_now; then
    echo "  直接確認でも回復していませんでした。自動リカバリは行わず、ハング・タイムアウト時の対応に従ってください。" >&2
    return 1
  fi

  echo "  editor_statusはreadyでした。予算をリセットして${label}を1回だけやり直します（自動リカバリ）。" >&2
  if "$poll_fn" "$budget"; then
    return 0
  fi
  echo "  自動リカバリ（${label}のやり直し）も失敗しました。ハング・タイムアウト時の対応に従ってください。" >&2
  return 1
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
if poll_recompile_status "$POLL_BUDGET_SECONDS"; then
  step3_rc=0
else
  step3_rc=$?
fi
case "$step3_rc" in
  0) ;;
  2)
    echo "ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
    ;;
  *)
    if ! retry_once_if_recovered "recompile_statusポーリング" poll_recompile_status "$POLL_BUDGET_SECONDS"; then
      exit 2
    fi
    ;;
esac

echo "[4/5] editor_status でドメインリロード完了の安定確認（${SETTLE_REQUIRED_COUNT}回連続）" >&2
if poll_editor_status_settle "$POLL_BUDGET_SECONDS"; then
  step4_rc=0
else
  step4_rc=$?
fi
case "$step4_rc" in
  0) ;;
  2)
    echo "ハング・タイムアウト時の対応に従ってください。" >&2
    exit 2
    ;;
  *)
    if ! retry_once_if_recovered "editor_status安定確認" poll_editor_status_settle "$POLL_BUDGET_SECONDS"; then
      exit 2
    fi
    ;;
esac

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
