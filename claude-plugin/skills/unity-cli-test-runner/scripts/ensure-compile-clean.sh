#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「1. コンパイル状態の確定」ステップを1コマンドにまとめる。
# clear_console → recompile → recompile_status ポーリング → editor_status によるドメインリロード
# 完了の安定確認 → recompile_status の読み直し（判定）＋ console（詳細取得）を順に実行し、
# コンパイルが確定していて（Unity側が変更を反映しきっていて）、かつエラーが無いかを確認する。
# com.unity.pipeline 0.8.0-exp.1 以降が前提（コンパイルエラーの判定は recompile_status の
# failed/compilationFailed を一次情報とし、console は詳細取得専用にしている）。
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
#   3  recompile_status から failed / compilationFailed を取り出せず、エラー有無を確実に
#      判定できなかった。標準出力の生JSONを確認して手動判断する
#      （console の応答が想定外でも判定自体は recompile_status で済んでいるため、
#      その場合は exit 3 ではなく exit 1 になる）
#   4  内部のunity cmd呼び出し（clear_console/recompile/editor_statusのいずれか）
#      が失敗/タイムアウトしたが、メインスレッド不要のrecompile_statusは正常応答した
#      （モーダルダイアログによるメインスレッドブロックの可能性が高い。真のハングではない）。
#      .unity/.prefabファイルをUnity上で開いた状態のまま外部から変更すると、外部変更確認
#      （Reload/Ignore等）のダイアログが表示されこの状態になる。ユーザーにダイアログを閉じて
#      もらうよう依頼する（エディタの再起動は不要）
#
# 注意（実測済み、2026-08-21）:
# - `unity cmd` は `--json` を付けない場合、TSV形式（`Command\tSuccess\tResult\tParameters`）で
#   応答を返す。jqでパースする呼び出しには必ず `--json` を付けること（付け忘れると空文字列に
#   フォールバックし続け、ポーリングが常にタイムアウトする）
# - recompile_status --json の data.result は 0.8 以降ネイティブなJSONオブジェクト（0.7 以前は
#   JSON文字列として二重エンコードされていた。両方の形を extract_result_payload が受け付ける）。
#   中身は {status, failed, errors, compilationFailed} で、statusは
#   triggered/compiling/completed/up_to_date/failed を取る（failedはコンパイルエラーが
#   残っている場合。このスクリプトはポーリングの終端として扱い、エラー有無の判定は
#   ステップ5に一本化している）。フィールドの取り出しは read_result_field が行う
# - editor_status --json / console --json の data.result はネイティブなJSONオブジェクト
#   （二重エンコードされていない）。editor_statusは {status, compiling, domainReloadInProgress,
#   playMode, ...}、consoleは {entries, cursor, session, returned, dropped, reset,
#   counts{...}, groundTruth{...}}
# - recompile / recompile_status の data.result に含まれる compilationFailed は、Unityの
#   ネイティブなコンパイル失敗フラグのサンプルが2秒以内のときだけ有効（古ければfalseに倒れる）。
#   サンプリングはメインスレッドで動くため、ダイアログブロック中・ドメインリロード中は止まる
# - コンパイル完了直後、ドメインリロード（アセンブリの再読み込み）の間の1〜2秒、Unity側の
#   Pipelineサーバーが一時的にダウンし、recompile_statusが completed/up_to_date を報告した
#   直後にすら unity cmd 呼び出しが失敗しうる。そのため recompile_status が完了状態を報告した
#   だけでは「確定」とみなさず、editor_status の compiling/domainReloadInProgress が両方falseで
#   2回連続安定するまで確認してから終了する
# - com.unity.pipeline 0.6.0-exp.1 以降は、同じ状況をサーバーがHTTP 503のbusy応答
#   （retryable=true / busyReason=settling|blocked_by_dialog）で返すこともある。
#   _lib.sh の is_transient_failure が両方をまとめて一時的失敗として扱う
#
# 自動リカバリ（実測済み、2026-08-22）:
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
      status="$(read_result_field "$raw" status)"
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
      # failed も終端状態として扱う。0.7 は recompile が status:"failed" を返した後の
      # recompile_status でもこの値を返しうる。ここでは完了か否かだけを判定し、
      # コンパイルエラーの有無の判定はステップ5に一本化する（この関数で exit 1 に
      # 分岐させると、ドメインリロード完了の安定確認を飛ばすことになるため）。
      completed|up_to_date|failed)
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
# SETTLE_REQUIRED_COUNT回連続で確認する。
# 戻り値: 0=成功 / 1=予算超過（自動リカバリの余地あり） /
#         2=unity cmd呼び出し自体が非一時的な理由で失敗した（リカバリの余地なし） /
#         3=editor_statusが失敗し、かつメインスレッド不要のrecompile_statusは正常応答した
#           （モーダルダイアログによるメインスレッドブロックの可能性が高い。真のハングとは
#           区別して報告する）
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
    elif is_busy_blocked_by_dialog "$UNITY_CMD_DIAG"; then
      # is_transient_failure より先に判定する。busyReason=blocked_by_dialog は
      # is_transient_busy にも一致してしまい、そちらを先に見るとリトライを続けて
      # 予算を使い切るまでダイアログブロックと確定できない（0.6以降でこの応答が
      # 有効な環境向けの早期検知）。
      echo "editor_status がダイアログブロックのbusy応答（busyReason=blocked_by_dialog）を返しました。モーダルダイアログによるメインスレッドブロックの可能性が高いです（ハングではありません）。" >&2
      return 3
    elif is_transient_failure "$UNITY_CMD_DIAG"; then
      # まさにドメインリロード中、またはサーバーがbusy（0.6以降、settlingのみ）なので
      # 不安定とみなし、連続カウントをリセットして続行する
      raw="$UNITY_CMD_DIAG"
      echo "  一時的失敗を検知（ドメインリロード中、またはサーバーbusy）。安定確認カウントをリセットして継続。" >&2
      compiling="true"
      domain_reload="true"
    elif is_blocked_by_dialog "$CLI_TIMEOUT"; then
      # busy応答が無効な版（Unity 6000.3.14f1等）向けのタイムアウトベースの判別。
      echo "editor_status が失敗/タイムアウトしましたが、メインスレッド不要の recompile_status は正常応答しました。モーダルダイアログによるメインスレッドブロックの可能性が高いです（ハングではありません）。" >&2
      return 3
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
# 戻り値: 0=リカバリ後に成功 / 1=失敗（回復していない。真のハングの可能性） /
#         2=失敗、かつメインスレッド不要のrecompile_statusは正常応答した
#           （モーダルダイアログによるメインスレッドブロックの可能性が高い）
retry_once_if_recovered() {
  local label="$1"
  local poll_fn="$2"
  local budget="$3"

  echo "  予算超過。editor_statusを直接確認し、回復していれば1回だけ自動リカバリします。" >&2
  if ! is_editor_ready_now; then
    if is_blocked_by_dialog "$CLI_TIMEOUT"; then
      echo "  直接確認でも回復していませんでしたが、メインスレッド不要の recompile_status は正常応答しました。モーダルダイアログによるメインスレッドブロックの可能性が高いです（ハングではありません）。" >&2
      return 2
    fi
    echo "  直接確認でも回復していませんでした。自動リカバリは行わず、ハング・タイムアウト時の対応に従ってください。" >&2
    return 1
  fi

  echo "  editor_statusはreadyでした。予算をリセットして${label}を1回だけやり直します（自動リカバリ）。" >&2
  local retry_rc
  if "$poll_fn" "$budget"; then
    return 0
  else
    retry_rc=$?
  fi
  if [ "$retry_rc" -eq 3 ]; then
    # poll_editor_status_settle がやり直し中に改めてダイアログブロックを検知したケース。
    # 真のハングではないので、この情報を握り潰さず呼び出し元へ伝える。
    return 2
  fi
  echo "  自動リカバリ（${label}のやり直し）も失敗しました。ハング・タイムアウト時の対応に従ってください。" >&2
  return 1
}

# ダイアログブロック検知時の統一メッセージを出してexit 4する。
report_dialog_block_and_exit() {
  echo "モーダルダイアログが開いている可能性が高いです（ハングではありません）。Unityエディタを確認し、開いているダイアログを閉じてください（Reload/Ignore等の外部変更確認ダイアログの可能性が高いです。.unity/.prefabファイルをUnity上で開いた状態のまま外部から変更するとこの状態になります）。エディタの再起動は不要です。" >&2
  exit 4
}

# recompile / recompile_status の `.data.result` から1フィールドを読む。
# 中身の取り出し（二重エンコード文字列／ネイティブJSONの両対応）は extract_result_payload（_lib.sh）が行う。
# jq の `//` はfalseも「無い」と扱ってしまい failed=false を空文字列に潰すので、
# 存在確認には has() を使う（jq 1.7.1 で実測）。
# 取り出せない場合は空文字列を返し、呼び出し元が「判定不能」として扱えるようにする。
read_result_field() {
  local raw="$1" field="$2" payload
  payload="$(extract_result_payload "$raw")" || return 0
  echo "$payload" | jq -r --arg f "$field" '
    if type == "object" and has($f) then .[$f] else empty end
  ' 2>/dev/null || true
}

# コンパイルエラーが確定した時点で、console から詳細を取得して exit 1 する（戻らない）。
#   $1 … 判定の根拠にした生JSON（console が取れなかった場合はこちらを報告に回す）
#   $2 … 判定の根拠を1行で表したラベル
# 判定の一次情報は recompile_status なので、console の取得に失敗しても、entries が空でも、
# 判定は覆さない。sticky なコンパイルエラーは clear_console で消えず、
# backfill のタイミング次第で詳細が欠けることがあるため、ここで成功に倒すと誤報告になる。
report_compile_failure_and_exit() {
  local evidence_raw="$1" evidence_label="$2"
  echo "コンパイルエラーを検出しました（${evidence_label}）。console から詳細を取得します。" >&2

  local console_raw entry_count
  if console_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" console --level error --tail 20 --json)"; then
    entry_count="$(echo "$console_raw" | jq -r 'if (.data.result.entries | type) == "array" then (.data.result.entries | length) else "unknown" end' 2>/dev/null || true)"
    if [ "$entry_count" = "0" ]; then
      echo "  console のエラーエントリは0件でした（sticky/backfillの都合で詳細が欠けることがあります）。判定は recompile_status に基づくため、成功にはしません。" >&2
    fi
    echo "コンパイルエラーを検出しました（${evidence_label}）。テスト対象の解決へ進まず、以下を報告してください:"
    echo "$console_raw"
  else
    echo "  console からの詳細取得に失敗しました。判定は recompile_status に基づくため覆りません。" >&2
    echo "コンパイルエラーを検出しました（${evidence_label}）。console からの詳細取得には失敗したため、判定の根拠となった応答をそのまま報告してください:"
    echo "$evidence_raw"
  fi
  exit 1
}

echo "[1/5] clear_console" >&2
if ! run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" clear_console >/dev/null; then
  if is_blocked_by_dialog "$CLI_TIMEOUT"; then
    report_dialog_block_and_exit
  fi
  echo "clear_console が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

echo "[2/5] recompile" >&2
# --json を必ず付ける（付けないとTSV形式で返り、status を jq で読めない）。
# 0.7 の recompile は、コンパイルエラーが残っている状態では status:"failed" を返す
# （0.6 では同じ状況で up_to_date を返し、エラーの記録が消えていた）。この場合は
# 変更が無くコンパイルも走らないため、ポーリングしても状態は変わらない。待つ意味が
# 無いので、そのまま詳細取得へ飛ばす。
if ! recompile_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" recompile --json)"; then
  if is_blocked_by_dialog "$CLI_TIMEOUT"; then
    report_dialog_block_and_exit
  fi
  echo "recompile が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

if [ "$(read_result_field "$recompile_raw" status)" = "failed" ]; then
  echo "recompile が status:\"failed\" を返しました（コンパイルエラーが残っています）。ポーリングを飛ばして詳細取得へ進みます。" >&2
  report_compile_failure_and_exit "$recompile_raw" 'recompile: status="failed"'
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
    if retry_once_if_recovered "recompile_statusポーリング" poll_recompile_status "$POLL_BUDGET_SECONDS"; then
      : # 成功。テスト対象の解決へ進む
    else
      recovery_rc=$?
      if [ "$recovery_rc" -eq 2 ]; then
        report_dialog_block_and_exit
      fi
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
  3)
    report_dialog_block_and_exit
    ;;
  *)
    if retry_once_if_recovered "editor_status安定確認" poll_editor_status_settle "$POLL_BUDGET_SECONDS"; then
      : # 成功。結果報告へ進む
    else
      recovery_rc=$?
      if [ "$recovery_rc" -eq 2 ]; then
        report_dialog_block_and_exit
      fi
      exit 2
    fi
    ;;
esac

echo "[5/5] recompile_status を読み直してコンパイルエラーの有無を判定" >&2
# 判定の一次情報は recompile_status（0.7 で compilationFailed が追加された）。console は
# 詳細取得専用にする。compilationFailed はネイティブフラグのサンプルが2秒以内で
# なければ false に倒れる仕様のため、ドメインリロード完了を確認した直後のこのタイミングで
# 読み直すのが最も信頼できる。
# ここでの失敗に is_blocked_by_dialog を挟まないのは、その判別の probe が recompile_status
# 自身だから（メインスレッド不要なのでダイアログでは塞がれず、失敗＝真のハングに寄る）。
if ! status_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" recompile_status --json)"; then
  echo "recompile_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

failed="$(read_result_field "$status_raw" failed)"
compilation_failed="$(read_result_field "$status_raw" compilationFailed)"

# どちらか一方でも真偽値として読めれば判定できる。両方読めない場合だけ判定不能とする。
if ! [[ "$failed" =~ ^(true|false)$ ]] && ! [[ "$compilation_failed" =~ ^(true|false)$ ]]; then
  echo "recompile_status から failed / compilationFailed を取り出せず、コンパイルエラーの有無を判定できませんでした。以下の生JSONを確認してください:" >&2
  echo "$status_raw"
  exit 3
fi

if [ "$failed" = "true" ] || [ "$compilation_failed" = "true" ]; then
  report_compile_failure_and_exit "$status_raw" "recompile_status: failed=${failed:-n/a} compilationFailed=${compilation_failed:-n/a}"
fi

echo "コンパイル確定・エラー無し。テスト対象の解決へ進んでよい。" >&2
exit 0
