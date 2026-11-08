#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「1. コンパイル状態の確定」ステップを1コマンドにまとめる。
# console clear → editor status でドメインリロード回数（codeLoadCount）の基準値を取得 → script recompile →
# 回数が基準値より増えて落ち着くまで（またはコンパイルエラーで落ち着くまで）待つ →
# script recompile_status の読み直し（判定）＋ console get（詳細取得）を順に実行し、
# コンパイルが確定していて（Unity側が変更を反映しきっていて）、かつエラーが無いかを確認する。
# com.unity.pipeline 0.10.0-exp.1 以降が前提（editor status の codeLoadCount で完了を判定する。
# コンパイルエラーの判定は script recompile_status の failed/compilationFailed を一次情報とし、
# console get は詳細取得専用にしている）。
#
# 使い方: ensure-compile-clean.sh [ポーリング予算秒数(既定60)]
#
# 注意: 引数のポーリング予算秒数は、基準値を取る前の待ち（ステップ2。エディタ側のコンパイル・リロードが
# すでに走っている場合だけ）と、完了待ち（ステップ4）の両方に個別に適用される。さらに完了待ちは
# 予算超過時に1回だけ自動リカバリ（下記参照）を試みるため、全体の所要時間は最大で「引数の3倍強」に
# なりうる（既定なら最大180秒＋自動リカバリの直接確認分。直接確認はONESHOT_RETRY_BUDGET_SECONDS＝15秒を
# 上限に一時的失敗のみリトライする）。
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  コンパイル確定・エラー無し。テスト対象の解決へ進んでよい
#   1  コンパイルエラーを検出した（詳細は標準出力）。テスト対象の解決へ進まず報告する
#   2  コンパイル・ドメインリロードが予算内に完了しない（リロード回数が増えない、またはエディタが
#      落ち着かない）、またはunity cmd呼び出し自体が（一時的失敗＝Pipeline切断やサーバーbusyのリトライ予算を
#      使い切ってもなお）失敗/タイムアウトした（下記の自動リカバリを試みても解消しなかった
#      場合を含む）。
#      盲目的に再試行せず、スキルの「ハング・タイムアウト時の対応」に従う
#   3  script recompile_status から failed / compilationFailed を取り出せず、エラー有無を確実に
#      判定できなかった。標準出力の生JSONを確認して手動判断する
#      （console get の応答が想定外でも判定自体は script recompile_status で済んでいるため、
#      その場合は exit 3 ではなく exit 1 になる）。
#      また、unity cmd がコマンドまたは引数を見つけられなかった場合、editor status に codeLoadCount が
#      無い場合（プラグイン・UPMパッケージ・com.unity.pipeline の版の組み合わせが揃っていない疑い。
#      標準エラーに診断が出る。再試行せず版を揃えてもらう）もこの終了コードになる
#   4  内部のunity cmd呼び出し（console clear/script recompile/editor statusのいずれか）
#      が失敗/タイムアウトしたが、メインスレッド不要のscript recompile_statusは正常応答した
#      （モーダルダイアログによるメインスレッドブロックの可能性が高い。真のハングではない）。
#      .unity/.prefabファイルをUnity上で開いた状態のまま外部から変更すると、外部変更確認
#      （Reload/Ignore等）のダイアログが表示されこの状態になる。ユーザーにダイアログを閉じて
#      もらうよう依頼する（エディタの再起動は不要）
#
# 注意（実測済み、2026-08-21）:
# - `unity cmd` は `--json` を付けない場合、TSV形式（`Command\tSuccess\tResult\tParameters`）で
#   応答を返す。jqでパースする呼び出しには必ず `--json` を付けること（付け忘れると空文字列に
#   フォールバックし続け、ポーリングが常にタイムアウトする）
# - script recompile_status --json の data.result は 0.8 以降ネイティブなJSONオブジェクト（0.7 以前は
#   JSON文字列として二重エンコードされていた。両方の形を extract_result_payload が受け付ける）。
#   中身は {status, failed, errors, compilationFailed}。フィールドの取り出しは read_result_field が行う
# - editor status --json / console get --json の data.result はネイティブなJSONオブジェクト
#   （二重エンコードされていない）。editor statusは {status, compiling, domainReloadInProgress,
#   playMode, codeLoadCount, ...}、console getは {entries, cursor, session, returned, dropped, reset,
#   counts{...}, groundTruth{...}}
# - script recompile / script recompile_status の data.result に含まれる compilationFailed は、Unityの
#   ネイティブなコンパイル失敗フラグのサンプルが2秒以内のときだけ有効（古ければfalseに倒れる）。
#   サンプリングはメインスレッドで動くため、ダイアログブロック中・ドメインリロード中は止まる
# - com.unity.pipeline 0.6.0-exp.1 以降は、ドメインリロード中の一時的なダウンをサーバーがHTTP 503の
#   busy応答（retryable=true / busyReason=settling|blocked_by_dialog）で返すこともある。
#   _lib.sh の is_transient_failure が切断と busy をまとめて一時的失敗として扱う
#
# 完了判定（実測済み、2026-11-08。Unity 6000.3.25f1 + com.unity.pipeline 0.10.0-exp.1）:
# - script recompile は完了を待たずに {"status":"compiling"} を返す（変更が無ければ up_to_date）。
#   その後 editor status は compiling:true → （リロード中の1〜2秒は接続失敗）→ ready に戻り、
#   ready に戻った時点で codeLoadCount が1増える。回数はリロードをまたいで保持される。
#   コメントだけの変更でもリロードが起き、回数は増える
# - そのため「回数が基準値より増え、compiling/domainReloadInProgress が両方false」を1回確かめれば
#   リロードを越えたと言える（安定確認を2回重ねる必要は無い）
# - コンパイルエラーのときはリロードが起きず、回数は増えない。script recompile_status が
#   status:"completed"・failed:true を返す。一方 compilationFailed（Unity のネイティブなフラグ）は、エラーを
#   直したコンパイルが終わってもリロードで消えるまで true のまま返る（Pipeline 0.10 のソースのコメントで確認）。
#   コンパイル完了からリロード開始までの隙間でこれを拾って「直したのにエラー」と報告しないよう、完了待ちで
#   エラーと見なすのは editor status が落ち着いていて回数が基準値のまま、かつ status が completed / failed で
#   failed:true のときに限る（script recompile は status を同期で triggered に書き直すので、これは必ず今回の結果）
# - Auto Refresh などでエディタ側のコンパイル・リロードがすでに走っているときに基準値を取ると、
#   その進行中のリロードで回数が増えただけで「今回のリロードが終わった」と取り違える。基準値は
#   compiling/domainReloadInProgress が両方falseのときに取る。script recompile が up_to_date でも、
#   エディタ側で別のコンパイルが進んでいれば完了待ちに合流する
#
# 自動リカバリ（実測済み、2026-08-22）:
# - 実運用で、完了待ちが予算超過して exit 2 になった直後にコントローラーが
#   `unity cmd editor status` を直接叩くと実はreadyだった（＝一時切断が予算を使い切った後に
#   ちょうど解消していた）というケースが6回中2回観測された。これはドメインリロードの想定
#   継続時間（1〜2秒）を超える、より長い一時切断が起きうることを示している
# - このケースをコントローラーへの報告・再ディスパッチという往復に頼らずスクリプト内で
#   自己解決させるため、完了待ちは予算超過時に (a) editor status を直接確認し（この確認自体が
#   一時的失敗に当たって誤判定しないよう、他の単発コマンドと同じ run_unity_cmd_resilient で
#   一時的失敗のみ最大15秒リトライする）、(b) readyが裏取りできた場合に限り、同じ完了待ちを
#   新しい予算で1回だけやり直す。裏取りできない場合（本当にまだreadyでない場合）は即座に
#   exit 2 とし、盲目的に待ち時間を延ばすことはしない

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

POLL_BUDGET_SECONDS="${1:-60}"
POLL_INTERVAL_SECONDS=1
CLI_TIMEOUT=30
ONESHOT_RETRY_BUDGET_SECONDS=15

# 完了待ちの基準にするドメインリロード回数（ステップ2で取得する）。
BASELINE_CODE_LOAD_COUNT=""

# editor status を直接確認する。予算超過後の自動リカバリを試みてよいかどうかの
# 裏取りにのみ使う。この確認自体がたまたま一時的失敗のタイミングに重なって「未回復」と
# 誤判定しないよう、run_unity_cmd_resilient で一時的失敗のみ有限予算（15秒）リトライする
# （盲目的な待機延長ではなく、他の単発コマンドと同じ既存の確認済みイディオム）。
is_editor_ready_now() {
  local raw rc
  raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" editor status --json)" && rc=0 || rc=$?
  exit_on_version_mismatch "$rc" "$raw"
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  local compiling domain_reload
  compiling="$(echo "$raw" | jq -r '.data.result.compiling' 2>/dev/null || true)"
  domain_reload="$(echo "$raw" | jq -r '.data.result.domainReloadInProgress' 2>/dev/null || true)"
  [ "$compiling" = "false" ] && [ "$domain_reload" = "false" ]
}

# editor status の応答から codeLoadCount を読む。整数なら標準出力に出して 0、そうでなければ 1。
read_code_load_count() {
  local raw="$1" count
  count="$(echo "$raw" | jq -r '.data.result.codeLoadCount | if type == "number" and . == floor then tostring else empty end' 2>/dev/null || true)"
  [ -n "$count" ] || return 1
  echo "$count"
}

# codeLoadCount が無い（0.10 未満の Pipeline）ときの診断を出して exit 3 する（戻らない）。
exit_on_missing_code_load_count() {
  local raw="$1"
  echo "editor status の応答に codeLoadCount（ドメインリロードの回数）がありませんでした。com.unity.pipeline が 0.10.0-exp.1 より古い可能性が高く、プラグイン・UPMパッケージ（com.warlockreport.unity-cli-test-runner）・com.unity.pipeline の版の組み合わせが揃っていません。" >&2
  echo "  リトライでは解消しません。README の「版番号と対応する com.unity.pipeline」の表で、3つの版を揃えてもらってください。" >&2
  echo "$raw"
  exit 3
}

# editor status を1回読み、結果をグローバル変数へ入れる。
#   ES_RAW / ES_COMPILING / ES_DOMAIN_RELOAD / ES_COUNT
# 戻り値: 0=読めた / 1=一時的失敗（ドメインリロード中の切断・busy。呼び出し元は待ち続けてよい） /
#         2=非一時的な理由で失敗した / 3=ダイアログブロックの可能性が高い
# コマンドまたは引数が見つからない応答、codeLoadCount の無い応答は版のずれとして exit 3 する（戻らない）。
read_editor_status_once() {
  ES_RAW=""; ES_COMPILING=""; ES_DOMAIN_RELOAD=""; ES_COUNT=""
  if run_unity_cmd_capture editor status --json --timeout "$CLI_TIMEOUT"; then
    ES_RAW="$UNITY_CMD_OUT"
    ES_COMPILING="$(echo "$ES_RAW" | jq -r '.data.result.compiling' 2>/dev/null || true)"
    ES_DOMAIN_RELOAD="$(echo "$ES_RAW" | jq -r '.data.result.domainReloadInProgress' 2>/dev/null || true)"
    ES_COUNT="$(read_code_load_count "$ES_RAW")" || exit_on_missing_code_load_count "$ES_RAW"
    return 0
  fi
  if is_command_not_found "$UNITY_CMD_DIAG"; then
    exit_on_version_mismatch 3 "$UNITY_CMD_OUT"
  fi
  if is_busy_blocked_by_dialog "$UNITY_CMD_DIAG"; then
    # is_transient_failure より先に判定する。busyReason=blocked_by_dialog は
    # is_transient_busy にも一致してしまい、そちらを先に見るとリトライを続けて
    # 予算を使い切るまでダイアログブロックと確定できない（0.6以降でこの応答が
    # 有効な環境向けの早期検知）。
    echo "editor status がダイアログブロックのbusy応答（busyReason=blocked_by_dialog）を返しました。モーダルダイアログによるメインスレッドブロックの可能性が高いです（ハングではありません）。" >&2
    return 3
  fi
  if is_transient_failure "$UNITY_CMD_DIAG"; then
    ES_RAW="$UNITY_CMD_DIAG"
    echo "  一時的失敗を検知（ドメインリロード中、またはサーバーbusy）。待ち続けます。" >&2
    return 1
  fi
  if is_blocked_by_dialog "$CLI_TIMEOUT"; then
    # busy応答が無効な版（Unity 6000.3.14f1等）向けのタイムアウトベースの判別。
    echo "editor status が失敗/タイムアウトしましたが、メインスレッド不要の script recompile_status は正常応答しました。モーダルダイアログによるメインスレッドブロックの可能性が高いです（ハングではありません）。" >&2
    return 3
  fi
  echo "editor status が失敗/タイムアウトしました。" >&2
  report_unity_cmd_failure "$UNITY_CMD_OUT" "$UNITY_CMD_RC"
  return 2
}

# 直前に読んだ editor status で、コンパイルもドメインリロードも走っていないか。
is_editor_settled() {
  [ "$ES_COMPILING" = "false" ] && [ "$ES_DOMAIN_RELOAD" = "false" ]
}

# read_editor_status_once の戻り値 2/3 を、終了コード 2/4 に変換して終える（戻らない）。
exit_on_editor_status_failure() {
  case "$1" in
    3) report_dialog_block_and_exit ;;
    *)
      echo "ハング・タイムアウト時の対応に従ってください。" >&2
      exit 2
      ;;
  esac
}

# [2/5] エディタが落ち着いている（compiling/domainReloadInProgress が両方false）ときの codeLoadCount を
# BASELINE_CODE_LOAD_COUNT に入れる。エディタ側のコンパイル・リロードがすでに走っていれば、落ち着くまで待つ。
take_baseline_code_load_count() {
  local budget="$1" start="$SECONDS" rc
  while :; do
    read_editor_status_once && rc=0 || rc=$?
    case "$rc" in
      0)
        if is_editor_settled; then
          BASELINE_CODE_LOAD_COUNT="$ES_COUNT"
          return 0
        fi
        echo "  エディタ側のコンパイル・ドメインリロードが進行中です（codeLoadCount=${ES_COUNT}）。落ち着くまで待ってから基準値を取ります。" >&2
        ;;
      1) ;;
      *) exit_on_editor_status_failure "$rc" ;;
    esac
    if [ $((SECONDS - start)) -ge "$budget" ]; then
      echo "editor status が${budget}秒以内に落ち着かず（compiling/domainReloadInProgress が false にならない）、基準値を取れませんでした。ハング・タイムアウト時の対応に従ってください。" >&2
      exit 2
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

# [4/5] コンパイル・ドメインリロードの完了を待つ。
# 戻り値: 0=終端（回数が基準値より増えて落ち着いた、または回数据え置きで落ち着き
#           script recompile_status が failed/compilationFailed を報告した。エラーの有無はステップ5で判定する） /
#         1=予算超過（自動リカバリの余地あり） /
#         2=unity cmd呼び出し自体が非一時的な理由で失敗した（リカバリの余地なし） /
#         3=ダイアログブロックの可能性が高い（真のハングとは区別して報告する）
# 基準値はグローバルの BASELINE_CODE_LOAD_COUNT を使う（retry_once_if_recovered に予算だけ渡して呼べる形）。
poll_compile_done() {
  local budget="$1" start="$SECONDS" rc failed recompile_state last_state=""
  while :; do
    read_editor_status_once && rc=0 || rc=$?
    case "$rc" in
      0)
        if is_editor_settled; then
          if [ "$ES_COUNT" -gt "$BASELINE_CODE_LOAD_COUNT" ]; then
            echo "  ドメインリロードの完了を確認しました（codeLoadCount ${BASELINE_CODE_LOAD_COUNT} → ${ES_COUNT}）。" >&2
            return 0
          fi
          # 回数が据え置きのまま落ち着いている。コンパイルエラーならリロードは起きないので、
          # ここで script recompile_status を見る（メインスレッド不要）。エラーとみなすのは、今回の
          # コンパイルが書いた結果（status が completed / failed で failed==true）に限る。
          # script recompile はステータスを同期で triggered に書き直してからコンパイルを始めるので、
          # この組み合わせは必ず今回のコンパイルの結果になる。一方 compilationFailed は Unity の
          # ネイティブなフラグで、エラーを直したコンパイルが終わってもリロードで消えるまでの間は true の
          # まま返る。コンパイル完了からリロード開始までの隙間でこれを拾うと、直したのにエラーと
          # 報告してしまうため、ここでは見ない（最終判定はリロード後のステップ5で行う）
          if run_unity_cmd_capture script recompile_status --json --timeout "$CLI_TIMEOUT"; then
            failed="$(read_result_field "$UNITY_CMD_OUT" failed)"
            recompile_state="$(read_result_field "$UNITY_CMD_OUT" status)"
            if [ "$failed" = "true" ] && { [ "$recompile_state" = "completed" ] || [ "$recompile_state" = "failed" ]; }; then
              echo "  ドメインリロードが起きないまま落ち着き、script recompile_status がコンパイルエラーを報告しました。" >&2
              return 0
            fi
            last_state="回数据え置き（codeLoadCount=${ES_COUNT}）・script recompile_status=${recompile_state:-不明}"
          elif is_transient_failure "$UNITY_CMD_DIAG"; then
            echo "  一時的失敗を検知（ドメインリロード中、またはサーバーbusy）。待ち続けます。" >&2
          else
            if is_command_not_found "$UNITY_CMD_DIAG"; then
              exit_on_version_mismatch 3 "$UNITY_CMD_OUT"
            fi
            echo "script recompile_status が失敗/タイムアウトしました。" >&2
            report_unity_cmd_failure "$UNITY_CMD_OUT" "$UNITY_CMD_RC"
            return 2
          fi
        else
          last_state="compiling=${ES_COMPILING} domainReloadInProgress=${ES_DOMAIN_RELOAD}（codeLoadCount=${ES_COUNT}）"
        fi
        ;;
      1) last_state="一時的失敗が継続（Pipeline切断、またはサーバーbusy）" ;;
      *) return "$rc" ;;
    esac
    if [ $((SECONDS - start)) -ge "$budget" ]; then
      echo "コンパイル・ドメインリロードが${budget}秒以内に完了しませんでした（基準値 codeLoadCount=${BASELINE_CODE_LOAD_COUNT}、最終状態: ${last_state:-不明}）。" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL_SECONDS"
  done
}

# 予算超過後の1回限りの自動リカバリ。$2にはリカバリ対象のポーリング関数名を渡す（poll_compile_done）。
# 戻り値: 0=リカバリ後に成功 / 1=失敗（回復していない。真のハングの可能性） /
#         2=失敗、かつメインスレッド不要のscript recompile_statusは正常応答した
#           （モーダルダイアログによるメインスレッドブロックの可能性が高い）
retry_once_if_recovered() {
  local label="$1"
  local poll_fn="$2"
  local budget="$3"

  echo "  予算超過。editor statusを直接確認し、回復していれば1回だけ自動リカバリします。" >&2
  if ! is_editor_ready_now; then
    if is_blocked_by_dialog "$CLI_TIMEOUT"; then
      echo "  直接確認でも回復していませんでしたが、メインスレッド不要の script recompile_status は正常応答しました。モーダルダイアログによるメインスレッドブロックの可能性が高いです（ハングではありません）。" >&2
      return 2
    fi
    echo "  直接確認でも回復していませんでした。自動リカバリは行わず、ハング・タイムアウト時の対応に従ってください。" >&2
    return 1
  fi

  echo "  editor statusはreadyでした。予算をリセットして${label}を1回だけやり直します（自動リカバリ）。" >&2
  local retry_rc
  if "$poll_fn" "$budget"; then
    return 0
  else
    retry_rc=$?
  fi
  if [ "$retry_rc" -eq 3 ]; then
    # やり直し中に改めてダイアログブロックを検知したケース。
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

# script recompile / script recompile_status の `.data.result` から1フィールドを読む。
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

# コンパイルエラーが確定した時点で、console get から詳細を取得して exit 1 する（戻らない）。
#   $1 … 判定の根拠にした生JSON（console get が取れなかった場合はこちらを報告に回す）
#   $2 … 判定の根拠を1行で表したラベル
# 判定の一次情報は script recompile_status なので、console get の取得に失敗しても、entries が空でも、
# 判定は覆さない。sticky なコンパイルエラーは console clear で消えず、
# backfill のタイミング次第で詳細が欠けることがあるため、ここで成功に倒すと誤報告になる。
report_compile_failure_and_exit() {
  local evidence_raw="$1" evidence_label="$2"
  echo "コンパイルエラーを検出しました（${evidence_label}）。console get から詳細を取得します。" >&2

  local console_raw entry_count
  if console_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" console get --level error --tail 20 --json)"; then
    entry_count="$(echo "$console_raw" | jq -r 'if (.data.result.entries | type) == "array" then (.data.result.entries | length) else "unknown" end' 2>/dev/null || true)"
    if [ "$entry_count" = "0" ]; then
      echo "  console get のエラーエントリは0件でした（sticky/backfillの都合で詳細が欠けることがあります）。判定は script recompile_status に基づくため、成功にはしません。" >&2
    fi
    echo "コンパイルエラーを検出しました（${evidence_label}）。テスト対象の解決へ進まず、以下を報告してください:"
    echo "$console_raw"
  else
    echo "  console get からの詳細取得に失敗しました。判定は script recompile_status に基づくため覆りません。" >&2
    echo "コンパイルエラーを検出しました（${evidence_label}）。console get からの詳細取得には失敗したため、判定の根拠となった応答をそのまま報告してください:"
    echo "$evidence_raw"
  fi
  exit 1
}

echo "[1/5] console clear" >&2
clear_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" console clear)" && rc=0 || rc=$?
exit_on_version_mismatch "$rc" "$clear_raw"
if [ "$rc" -ne 0 ]; then
  if is_blocked_by_dialog "$CLI_TIMEOUT"; then
    report_dialog_block_and_exit
  fi
  echo "console clear が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  report_unity_cmd_failure "$clear_raw"
  exit 2
fi

echo "[2/5] editor status でドメインリロード回数（codeLoadCount）の基準値を取得" >&2
take_baseline_code_load_count "$POLL_BUDGET_SECONDS"
echo "  基準値 codeLoadCount=${BASELINE_CODE_LOAD_COUNT}" >&2

echo "[3/5] script recompile" >&2
# --json を必ず付ける（付けないとTSV形式で返り、status を jq で読めない）。
# コンパイルエラーが残っている状態では status:"failed" を返すことがある（0.7 で確認）。この場合は
# 変更が無くコンパイルも走らないため、待っても状態は変わらない。待つ意味が無いので、そのまま詳細取得へ飛ばす。
recompile_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" script recompile --json)" && rc=0 || rc=$?
exit_on_version_mismatch "$rc" "$recompile_raw"
if [ "$rc" -ne 0 ]; then
  if is_blocked_by_dialog "$CLI_TIMEOUT"; then
    report_dialog_block_and_exit
  fi
  echo "script recompile が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  report_unity_cmd_failure "$recompile_raw"
  exit 2
fi

recompile_status="$(read_result_field "$recompile_raw" status)"
need_wait=1
case "$recompile_status" in
  failed)
    echo "script recompile が status:\"failed\" を返しました（コンパイルエラーが残っています）。ポーリングを飛ばして詳細取得へ進みます。" >&2
    report_compile_failure_and_exit "$recompile_raw" 'script recompile: status="failed"'
    ;;
  up_to_date)
    # 変更が無くリロードは起きない。ただしエディタ側で別のコンパイル（Auto Refresh 等）が進んでいれば、
    # その完了を待たずに exit 0 を返さないよう、editor status を1回だけ確かめる
    read_editor_status_once && rc=0 || rc=$?
    case "$rc" in
      0)
        if is_editor_settled; then
          need_wait=0
        else
          echo "  script recompile は up_to_date でしたが、エディタ側のコンパイル・ドメインリロードが進行中です。完了を待ちます。" >&2
        fi
        ;;
      1) echo "  script recompile は up_to_date でしたが、editor status が一時的失敗を返しました。完了を待ちます。" >&2 ;;
      *) exit_on_editor_status_failure "$rc" ;;
    esac
    ;;
esac

if [ "$need_wait" -eq 1 ]; then
  echo "[4/5] コンパイル・ドメインリロードの完了待ち（codeLoadCount が基準値 ${BASELINE_CODE_LOAD_COUNT} より増えるまで。予算 ${POLL_BUDGET_SECONDS}秒）" >&2
  if poll_compile_done "$POLL_BUDGET_SECONDS"; then
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
      if retry_once_if_recovered "完了待ち" poll_compile_done "$POLL_BUDGET_SECONDS"; then
        : # 成功。判定へ進む
      else
        recovery_rc=$?
        if [ "$recovery_rc" -eq 2 ]; then
          report_dialog_block_and_exit
        fi
        exit 2
      fi
      ;;
  esac
else
  echo "[4/5] 変更なし（up_to_date）・エディタも落ち着いているため完了待ちは省略" >&2
fi

echo "[5/5] script recompile_status を読み直してコンパイルエラーの有無を判定" >&2
# 判定の一次情報は script recompile_status（0.7 で compilationFailed が追加された）。console get は
# 詳細取得専用にする。compilationFailed はネイティブフラグのサンプルが2秒以内で
# なければ false に倒れる仕様のため、完了を確認した直後のこのタイミングで読み直すのが最も信頼できる。
# ここでの失敗に is_blocked_by_dialog を挟まないのは、その判別の probe が script recompile_status
# 自身だから（メインスレッド不要なのでダイアログでは塞がれず、失敗＝真のハングに寄る）。
status_raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" script recompile_status --json)" && rc=0 || rc=$?
exit_on_version_mismatch "$rc" "$status_raw"
if [ "$rc" -ne 0 ]; then
  echo "script recompile_status が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
  report_unity_cmd_failure "$status_raw"
  exit 2
fi

failed="$(read_result_field "$status_raw" failed)"
compilation_failed="$(read_result_field "$status_raw" compilationFailed)"

# どちらか一方でも真偽値として読めれば判定できる。両方読めない場合だけ判定不能とする。
if ! [[ "$failed" =~ ^(true|false)$ ]] && ! [[ "$compilation_failed" =~ ^(true|false)$ ]]; then
  echo "script recompile_status から failed / compilationFailed を取り出せず、コンパイルエラーの有無を判定できませんでした。以下の生JSONを確認してください:" >&2
  echo "$status_raw"
  exit 3
fi

if [ "$failed" = "true" ] || [ "$compilation_failed" = "true" ]; then
  report_compile_failure_and_exit "$status_raw" "script recompile_status: failed=${failed:-n/a} compilationFailed=${compilation_failed:-n/a}"
fi

echo "コンパイル確定・エラー無し。テスト対象の解決へ進んでよい。" >&2
exit 0
