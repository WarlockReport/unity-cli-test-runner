#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの各スクリプトが共有するヘルパー関数。
# 単体では実行せず、各スクリプトから `source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"` で読み込んで使う。
#
# 一時的失敗（リトライすれば解消しうる失敗）には3種類ある。
#
# 1. Pipelineサーバーへの到達不能
#    ドメインリロード中（コンパイル完了後の数秒間、およびPlayModeへの遷移直後）、Unity側の
#    Pipeline HTTPサーバーが一時的にダウンし、`unity cmd` が以下のエラーメッセージ付きで
#    失敗することが実測で確認されている（リロードは通常1〜2秒で完了し、Pipelineサーバーは
#    自動的に復帰する）:
#      "No Unity Editor instances found with reachable Pipeline servers."
#    com.unity.pipeline 0.9 では、接続先を UNITY_PROJECT_PATH で固定していると、同じ瞬断が
#    "No Pipeline instance found for project: <パス>. Make sure Unity Editor is running ..."
#    （unity cmd の終了コード 6）として現れることを実測で確認した（C# 変更直後の再コンパイル中）。
#    また、com.unity.pipeline 自体の版を差し替えた直後（サーバーの再起動中）は、接続そのものが
#    "Network error: An error occurred while sending the request." で失敗することも確認した。
#    com.unity.pipeline 0.10 + unity CLI 1.0.0-beta.13 では、ドメインリロードで落ちかけているサーバーから
#    応答が途中までしか返らず、"Failed to execute command '<名前>': Invalid response format from Pipeline server"
#    （unity cmd の終了コード 6）で失敗することがある（実地検証済み、2026-11-08。C# 変更直後の再コンパイル中）。
#
# 2. サーバーがbusyを返す（com.unity.pipeline 0.6.0-exp.1 以降）
#    0.6は、コマンドを実行できない状態を HTTP 503 と構造化エンベロープ
#    （error="Server Busy" / status="busy" / retryable=true / busyReason）で返すようになった。
#    busyReasonは "settling"（エディタ起動直後のインポート・コンパイル中）と
#    "blocked_by_dialog"（モーダルダイアログがメインスレッドを塞いでいる）。
#    本スキルのカスタムコマンドはすべて MainThreadRequired = true なのでどちらにも該当しうる。
#
# 3. 同時実行上限の超過（com.unity.pipeline 0.9.0-exp.1 以降）
#    実行待ちのコマンドが上限（100件）を超えると HTTP 429 と error="Too Many Queued Commands"
#    （ジョブの場合は "Too Many Queued Jobs"）を返す。retryable は付かないが、先行するコマンドが
#    捌ければ解消するのでリトライしてよい。
#
# unity CLI 1.0.0 では、CLI 側のエラーは {success:false, data:null, errors:[{code, message}]} の形で標準出力に出て、
# 終了コードでも種類が分かる（実地検証済み、2026-11-13）:
#   ドメインリロード中の切断 … 終了コード 6、"the Editor closed the connection without answering" または
#                              "the Editor closed the connection before the command finished"
#   エディタが見つからない   … 終了コード 12（EDITOR_NOT_RUNNING。リロード中の瞬断でも出る）
# CLI の changelog には、busy（読み込み中・コンパイル中・リロード中・同時実行の上限超過）が終了コード 17（EDITOR_BUSY）、
# モーダルダイアログが終了コード 18（EDITOR_BLOCKED_BY_DIALOG）とある。どちらも未実測。17 は一時的失敗として扱い、
# 18 はリトライしても解消しないので、run_unity_cmd_resilient が専用の戻り値（4）で即座に返す。
#
# 逆に「コマンドまたは引数が見つからない」応答（Command Not Found / No command named ... / has no parameter --...）は一時的失敗ではない。
# プラグイン・UPMパッケージ・com.unity.pipeline の版の組み合わせが揃っていないときに起き、
# リトライしても解消しない（is_command_not_found で判定し、一時的失敗の判定より先に見る）。
#
# いずれも「起動中のエディタが本当に落ちている / 応答しない」場合と区別が付くのは継続時間だけ
# なので、無条件にリトライし続けるのではなく、必ず呼び出し元の予算管理と組み合わせて使う。
# 特に blocked_by_dialog は、ユーザーがダイアログを閉じるまで解消しない（＝予算を使い切って
# 失敗するのが正しい振る舞いで、そのときエラー本文がダイアログの存在を伝える）。

is_transient_pipeline_unreachable() {
  local raw="$1"
  echo "$raw" | grep -qE "No Unity Editor instances found with reachable Pipeline servers|No Pipeline instance found for project|Network error: An error occurred while sending the request|Invalid response format from Pipeline server|the Editor closed the connection|\"code\"[[:space:]]*:[[:space:]]*\"EDITOR_NOT_RUNNING\""
}

# 0.6以降のbusy応答を検出する。`unity` CLIが503応答をどう整形するかは版によって異なりうるため、
# サーバーが返す構造化フィールドと、CLIが本文へ埋め込むメッセージの両方を拾う
# （既存の400応答では CLI が "Pipeline server returned 400 Bad Request: <error>. <errorDetails>"
# の形で error/errorDetails を本文に埋め込むことを実測で確認済み）。
is_transient_busy() {
  local raw="$1"
  echo "$raw" | grep -qE '"retryable"[[:space:]]*:[[:space:]]*true|"status"[[:space:]]*:[[:space:]]*"busy"|503 Service Unavailable|Server Busy|429 Too Many Requests|Too Many Queued (Commands|Jobs)|"code"[[:space:]]*:[[:space:]]*"EDITOR_BUSY"'
}

# 「コマンドまたは引数が見つからない」応答かどうか。0.9 以降は旧名を "No command named '<名前>' is available. ..."
# で拒否し、0.9 未満のサーバーは 2 語のコマンドを "Command Not Found" で拒否する。
# 0.10 以降は引数名を宣言名との完全一致で照合し、名前の合わない引数を "<グループ> has no parameter --<名前>"
# で拒否する（引数名の kebab-case 化をまたいだ版の組み合わせで起きる）。同じ INVALID_COMMAND_ARGS でも
# 値の誤りは版のずれではないため、コード全体ではなく「その名前の引数が無い」ことを示す文言に限って見る。
is_command_not_found() {
  local raw="$1"
  echo "$raw" | grep -qE 'Command Not Found|No command named|has no parameter --'
}

# 標準出力が unity CLI 側のエラー（接続不能・切断・busy 等）のエンベロープかどうか。
# CLI 1.0 は CLI 側のエラーだけを {success:false, data:null, errors:[...]} で出し、コマンドの結果には data キーが無い。
is_cli_error_envelope() {
  printf '%s' "$1" | jq -e 'type == "object" and .success == false and has("data") and .data == null and (.errors | type) == "array"' >/dev/null 2>&1
}

# 標準出力が unity CLI 1.0.0-beta.15 以前のエンベロープ（結果を data.result に包む形）かどうか。
# CLI 1.0 はエンベロープを付けないため、これが見えたら CLI が古い（このプラグインは CLI 1.0 以降が前提）。
is_legacy_cli_envelope() {
  printf '%s' "$1" | jq -e 'type == "object" and (.data | type) == "object" and (.data | has("command"))' >/dev/null 2>&1
}

# 自前コマンドの応答・ステータスが旧版 UPM パッケージ（結果のキーが PascalCase）のものかどうか。
# プラグインと UPM パッケージは別々に更新されるため、新しいプラグインと古い UPM パッケージの組み合わせを
# 黙って読み違えず、版のずれとして止めるために使う。
is_legacy_upm_payload() {
  printf '%s' "$1" | jq -e 'type == "object" and (has("Summary") or has("Results") or has("RequestId") or ((.results // [])[0] | type == "object" and has("FullName")))' >/dev/null 2>&1
}

# 戻り値が 3（版の組み合わせのずれ）なら、診断を標準エラーに、生の応答を標準出力に出して exit 3 する（戻らない）。
# それ以外の戻り値では何もしない。案内文は応答の中身で変える:
#   旧 CLI のエンベロープ             → unity CLI を上げる
#   旧版 UPM パッケージの応答         → UPM パッケージを上げる
#   それ以外（コマンド・引数が無い等） → 3 つの版を揃える
# 使い方: exit_on_version_mismatch <戻り値> <応答>
exit_on_version_mismatch() {
  local rc="$1" raw="$2"
  [ "$rc" = "3" ] || return 0
  if is_legacy_cli_envelope "$raw"; then
    echo "unity CLI の応答が古い形式（結果を data.result に包む形）でした。このプラグインは unity CLI 1.0.0 以降の出力形式を前提にしています。" >&2
    echo "  リトライでは解消しません。unity CLI を 1.0.0 以降に上げてもらってください（unity self-update）。" >&2
  elif is_legacy_upm_payload "$raw"; then
    echo "自前コマンドの応答が旧版の形式（キーが PascalCase）でした。プラグインと UPM パッケージの版が揃っていません。" >&2
    echo "  リトライでは解消しません。UPM パッケージ（com.warlockreport.unity-cli-test-runner）を v1.0.0 以降に上げてもらってください。" >&2
  else
    echo "unity cmd がコマンドまたは引数を見つけられませんでした。プラグイン・UPMパッケージ（com.warlockreport.unity-cli-test-runner）・com.unity.pipeline の版の組み合わせが揃っていない可能性が高いです。" >&2
    echo "  リトライでは解消しません。README の「版番号と対応する com.unity.pipeline」の表で、3つの版を揃えてもらってください。" >&2
  fi
  report_unity_cmd_failure "$raw"
  echo "$raw"
  exit 3
}

# カンマ区切りの FullName 一覧に、引数付きケースの FullName（`(` を含むもの）があれば、
# 診断を標準エラーに出して exit 1 する（戻らない）。含まなければ何もしない。
# NUnit は [TestCase] の FullName に引数をカンマ区切りで入れる（例: Ns.Class.Method(First,2)）ため、
# そのまま渡すと名前の途中で割れ、どのテストにも一致しない断片になる。EditMode ではエラーにならず
# そのケースだけが静かに実行されないため、実行前に止める。メソッドの FullName（引数部分を外した名前）を
# 渡せば、そのメソッドの全ケースが実行される（実地検証済み、2026-10-25）。
# 使い方: exit_on_parameterized_case_names <カンマ区切りFullName> <スクリプト名>
exit_on_parameterized_case_names() {
  local full_names="$1" script_name="$2"
  case "$full_names" in
    *"("*) ;;
    *) return 0 ;;
  esac
  echo "${script_name}: 引数付きケースの FullName（括弧を含む名前）は指定できません。名前の中のカンマで区切りが割れ、そのケースが実行されないためです。" >&2
  echo "  末尾の「(引数)」を外したメソッドの FullName（例: Ns.Class.Method(First,2) → Ns.Class.Method）を、重複を除いて渡してください。そのメソッドの全ケースが実行されます。" >&2
  echo "  指定された値: ${full_names}" >&2
  exit 1
}

# 一時的失敗（＝有限予算内でリトライしてよい失敗）かどうか。
is_transient_failure() {
  local raw="$1"
  is_transient_pipeline_unreachable "$raw" || is_transient_busy "$raw"
}

# 0.6以降のbusy応答のうち、busyReason="blocked_by_dialog"（モーダルダイアログによる
# メインスレッドブロック）を明示的に検出する。is_transient_busy はこれも「リトライしてよい
# 一時的失敗」として扱ってしまうため（実際、リトライしても解消せず予算を浪費するだけになる）、
# ダイアログブロックを早期に確定させたい呼び出し元（poll_editor_status_settle等）は、
# is_transient_failure より先にこちらで判定すること。
is_busy_blocked_by_dialog() {
  local raw="$1"
  echo "$raw" | grep -qE '"busyReason"[[:space:]]*:[[:space:]]*"blocked_by_dialog"'
}

# editor status（MainThreadRequired）等のメインスレッド必須コマンドが失敗/タイムアウトした際、
# モーダルダイアログによるメインスレッドブロックかどうかを判別する。
# メインスレッド不要な script recompile_status を1回叩き、応答すれば「Pipelineサーバー自体は生きて
# いてメインスレッドだけが塞がれている」＝ダイアログブロックと判定する（check-editor-ready.sh
# のステップ0で先に実測・確認済みだったロジックを共通化したもの）。
# 戻り値: 0=ダイアログブロックと判定（script recompile_statusが正常応答した）
#         1=判定つかず（script recompile_statusも失敗。真のハングの可能性が高い）
# プローブ自体が「コマンドが見つからない」で失敗した場合は、ダイアログでもハングでもなく版の組み合わせの
# ずれなので、exit_on_version_mismatch で終える（戻らない）。0.9 未満のサーバーでは、同名のフラットな
# コマンドがある `console clear` 等が引数エラーで失敗し、ここで初めて版のずれが分かることがある。
is_blocked_by_dialog() {
  local timeout="$1"
  if run_unity_cmd_capture script recompile_status --json --timeout "$timeout" >/dev/null 2>&1; then
    printf '%s' "$UNITY_CMD_OUT" | jq -e '.status | type == "string"' >/dev/null 2>&1
    return
  fi
  if is_command_not_found "$UNITY_CMD_DIAG"; then
    exit_on_version_mismatch 3 "$UNITY_CMD_OUT"
  fi
  return 1
}

# `unity cmd` を1回実行し、結果を4つのグローバル変数へ入れる。
#   UNITY_CMD_OUT  … 標準出力のみ（jqでパースするのはこちら）
#   UNITY_CMD_ERR  … 標準エラーのみ（CLI 1.0 では Pipeline 側のエラーの理由がここに平文で出る）
#   UNITY_CMD_DIAG … 標準出力＋標準エラー（is_transient_failure に渡すのはこちら）
#   UNITY_CMD_RC   … `unity cmd` 自体の終了コード（失敗時の診断出力に使う）
# 一時的失敗のメッセージが標準出力・標準エラーのどちらに出るかはCLIの版・失敗種別に依存するため、
# 判定には両方を結合したものを使い、呼び出し元がパースする値は標準出力だけに保つ。
# 戻り値は `unity cmd` 自体の終了コード。
UNITY_CMD_OUT=""
UNITY_CMD_ERR=""
UNITY_CMD_DIAG=""
UNITY_CMD_RC=0
run_unity_cmd_capture() {
  local err_file rc
  err_file="$(mktemp)"
  UNITY_CMD_OUT="$(unity cmd "$@" 2>"$err_file")" && rc=0 || rc=$?
  UNITY_CMD_RC="$rc"
  UNITY_CMD_ERR="$(cat "$err_file")"
  UNITY_CMD_DIAG="${UNITY_CMD_OUT}
${UNITY_CMD_ERR}"
  # 改修前の `raw="$(unity cmd ...)"` という形では標準エラーはそのまま端末へ素通りしていた。
  # ここで握り潰すと、標準出力が空で標準エラーにだけ理由が出る失敗（CLIとサーバーの
  # 版不整合などがこの形になる）で「失敗しました」以外の手がかりが消えるため、素通りさせる。
  cat "$err_file" >&2
  rm -f "$err_file"
  return "$rc"
}

# `unity cmd` が一時的でない理由で失敗したとき、その応答を標準エラーへ出す。
# `--json` を付けた呼び出しは失敗時も理由（`.errors[].message` 等）を標準出力のJSONに載せ、標準エラーは
# 空のことがある。呼び出し元はその標準出力を変数に取り込んだまま捨てるため、ここで出さないと
# 「失敗/タイムアウトしました」以外の手がかりが残らない（実機で、PlayModeのポーリング中に test status が
# 一度だけこの形で失敗し、理由を辿れなかった事例がある）。標準エラーの内容は run_unity_cmd_capture が
# すでに素通りさせているので、ここでは扱わない。
# 使い方: report_unity_cmd_failure <応答（標準出力）> [unity cmd の終了コード]
report_unity_cmd_failure() {
  local out="$1" rc="${2:-}"
  local rc_note=""
  [ -n "$rc" ] && rc_note="（unity cmd 終了コード ${rc}）"
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    echo "  unity cmd の応答は空でした${rc_note}。応答前のタイムアウト、またはCLI自体の失敗の可能性があります。" >&2
    return 0
  fi
  echo "  unity cmd の応答${rc_note}（先頭40行）:" >&2
  printf '%s\n' "$out" | head -n 40 | sed 's/^/    /' >&2
}

# ポーリングループを持たない単発コマンド用。一時的失敗の場合のみ
# 有限のリトライ予算内でリトライし、それ以外の失敗は即座に呼び出し元へ返す。
# 標準出力に生JSONを出す。終了コード:
#   0  成功
#   1  一時的ではない失敗（標準出力をそのまま出す。呼び出し元で内容を確認すること）。
#      unity CLI 1.0 は、失敗したテストを含む test status の完了や、自前コマンドの success:false の結果を
#      終了コード 6 で返す。そのときも結果は標準出力に出ているので、呼び出し元は 1 でも中身を読んで判断する
#      （呼び出しは $(...) のサブシェルで行われるため、unity cmd 自体の終了コードは呼び出し元に届かない）
#   2  一時的失敗のままリトライ予算を使い切った（真のハング、またはユーザー操作待ちのダイアログ）
#   3  版の組み合わせのずれ（コマンドまたは引数が見つからない、または unity CLI が古い）。
#      標準出力が空なら標準エラーの理由を出す。exit_on_version_mismatch に渡す
#   4  モーダルダイアログがエディタを塞いでいる（unity CLI の終了コード 18）。リトライしても解消しないので即座に返す
#
# 使い方: run_unity_cmd_resilient <timeout秒> <リトライ予算秒> <unity cmdへの引数...>
run_unity_cmd_resilient() {
  local timeout="$1"
  local retry_budget="$2"
  shift 2

  local retry_interval=1
  local elapsed=0

  while true; do
    if run_unity_cmd_capture "$@" --timeout "$timeout"; then
      echo "$UNITY_CMD_OUT"
      if is_legacy_cli_envelope "$UNITY_CMD_OUT"; then
        return 3
      fi
      return 0
    fi

    if [ "$UNITY_CMD_RC" = "18" ] || echo "$UNITY_CMD_OUT" | grep -qE '"code"[[:space:]]*:[[:space:]]*"EDITOR_BLOCKED_BY_DIALOG"'; then
      echo "$UNITY_CMD_OUT"
      return 4
    fi

    if [ "$UNITY_CMD_RC" = "13" ] || is_command_not_found "$UNITY_CMD_DIAG"; then
      if [ -n "$(printf '%s' "$UNITY_CMD_OUT" | tr -d '[:space:]')" ]; then
        echo "$UNITY_CMD_OUT"
      else
        echo "$UNITY_CMD_ERR"
      fi
      return 3
    fi

    if ! is_transient_failure "$UNITY_CMD_DIAG"; then
      echo "$UNITY_CMD_OUT"
      return 1
    fi

    if [ "$elapsed" -ge "$retry_budget" ]; then
      echo "$UNITY_CMD_DIAG"
      return 2
    fi

    sleep "$retry_interval"
    elapsed=$((elapsed + retry_interval))
  done
}

# `unity cmd ... --json` の標準出力から結果を取り出し、整形したJSONとして標準出力へ出す。
# unity CLI 1.0 は結果だけを出す（エンベロープは無い）ので、標準出力全体が JSON のオブジェクトか配列 1 個なら
# それが結果である。CLI 側のエラーのエンベロープは結果ではないので取り出さない。
# 戻り値: 0=取り出せた / 1=取り出せなかった（空・null・スカラー・パース不能・CLI のエラー。何も出力しない）
extract_result_payload() {
  local raw="$1" payload
  is_cli_error_envelope "$raw" && return 1
  payload="$(printf '%s' "$raw" | jq -c -s '
    if length == 1 and (.[0] | type == "object" or type == "array") then .[0] else error("unexpected result shape") end
  ' 2>/dev/null)" || return 1
  [ -n "$payload" ] || return 1
  printf '%s\n' "$payload" | jq .
}

# カンマ区切りの値を、各要素の前後の空白を除き、空の要素を捨てて、カンマで連結し直す。
# 使い方: normalize_csv <カンマ区切りの値>
normalize_csv() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd ',' - || true
}

# run-tests-filtered-*.sh の名前付き引数を解析し、次のグローバル変数を設定する。
#   SEL_ASSEMBLY / SEL_EXCLUDE / SEL_INCLUDE_CATEGORY / SEL_EXCLUDE_CATEGORY（カンマ区切りは normalize_csv 済み）
#   SEL_TIMEOUT（既定300。主な用途がアセンブリ規模の実行のため）/ SEL_POLL_BUDGET（既定90。PlayMode のみ使う）
# 未知のオプション・値の欠落は使い方の誤りとして exit 2、絞り込み条件が 1 つも無ければ exit 1、
# 除く名前に引数付きケースの FullName（括弧を含む名前）があれば exit 1（いずれも戻らない）。
# 使い方: parse_filtered_args <スクリプト名> <使い方の文字列> "$@"
parse_filtered_args() {
  local script_name="$1" usage="$2"
  shift 2
  SEL_ASSEMBLY=""
  SEL_EXCLUDE=""
  SEL_INCLUDE_CATEGORY=""
  SEL_EXCLUDE_CATEGORY=""
  SEL_TIMEOUT=300
  SEL_POLL_BUDGET=90

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --assembly|--exclude|--include-category|--exclude-category|--timeout|--poll-budget)
        if [ "$#" -lt 2 ]; then
          echo "${script_name}: $1 に値がありません。" >&2
          echo "使い方: ${usage}" >&2
          exit 2
        fi
        case "$1" in
          --assembly) SEL_ASSEMBLY="$(printf '%s' "$2" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" ;;
          --exclude) SEL_EXCLUDE="$(normalize_csv "$2")" ;;
          --include-category) SEL_INCLUDE_CATEGORY="$(normalize_csv "$2")" ;;
          --exclude-category) SEL_EXCLUDE_CATEGORY="$(normalize_csv "$2")" ;;
          --timeout) SEL_TIMEOUT="$2" ;;
          --poll-budget) SEL_POLL_BUDGET="$2" ;;
        esac
        shift 2
        ;;
      *)
        echo "${script_name}: 未知の引数です: $1" >&2
        echo "使い方: ${usage}" >&2
        exit 2
        ;;
    esac
  done

  if [ -z "${SEL_ASSEMBLY}${SEL_EXCLUDE}${SEL_INCLUDE_CATEGORY}${SEL_EXCLUDE_CATEGORY}" ]; then
    echo "${script_name}: 絞り込み条件がありません。--assembly / --exclude / --include-category / --exclude-category のいずれかを指定してください。" >&2
    echo "  アセンブリの全件を流すだけなら run-editmode-test.sh / run-playmode-test.sh の assembly 指定を使ってください。" >&2
    exit 1
  fi

  exit_on_parameterized_case_names "$SEL_EXCLUDE" "$script_name"
}

# parse_filtered_args で設定した絞り込み条件の名前が、test list に実在するかを確かめる。
# 綴りを誤った名前で実行すると、除いたつもりのテストが黙って流れる（または含めたつもりで 0 件になる）ため、
# 1 つでも見つからなければ実行せずに止める。照合の規則は Unity 側の照合に合わせる:
#   アセンブリ … 完全一致、大文字小文字を区別しない
#   除く名前   … 基準のアセンブリ内のテストの FullName と完全一致するか、名前の直後が「.」か「(」で続く
#               （クラス・メソッド・名前空間の完全名。「(」は test list が引数付きケースを Method(1,2) の名前で返すため。
#                境界の文字を必須にして、FooTest で FooTestExtra を見つけたことにしない）
#   カテゴリ   … 基準のアセンブリ内のテストの Categories と完全一致（大文字小文字を区別する）
# 見つからない名前を標準エラーに列挙して exit 1、test list の呼び出し自体の失敗は exit 2、版ずれは exit 3（いずれも戻らない）。
# 使い方: exit_on_unknown_selection <EditMode|PlayMode> <timeout秒> <スクリプト名>
exit_on_unknown_selection() {
  local mode="$1" timeout="$2" script_name="$3" raw rc missing

  echo "test list --mode ${mode} で絞り込み条件の名前が実在するかを確認" >&2
  raw="$(run_unity_cmd_resilient "$timeout" 15 test list --mode "$mode" --json)" && rc=0 || rc=$?
  exit_on_version_mismatch "$rc" "$raw"
  if [ "$rc" -ne 0 ]; then
    echo "${script_name}: test list の unity cmd 呼び出し自体が失敗/タイムアウトしました。ハング・タイムアウト時の対応に従ってください。" >&2
    report_unity_cmd_failure "$raw"
    exit 2
  fi

  missing="$(printf '%s' "$raw" | jq -r \
    --arg assembly "$SEL_ASSEMBLY" \
    --arg excludes "$SEL_EXCLUDE" \
    --arg includeCats "$SEL_INCLUDE_CATEGORY" \
    --arg excludeCats "$SEL_EXCLUDE_CATEGORY" '
    def csv: if . == "" then [] else split(",") end;
    (.data.result.Tests // []) as $all
    | ($all | if $assembly == "" then . else map(select((.Assembly // "" | ascii_downcase) == ($assembly | ascii_downcase))) end) as $base
    | (if $assembly != "" and ($base | length) == 0 then ["アセンブリ: " + $assembly] else [] end)
      + [($excludes | csv)[] as $n
          | select(($base | map(.FullName) | any(. == $n or startswith($n + ".") or startswith($n + "("))) | not)
          | "除く名前: " + $n]
      + [(($includeCats | csv) + ($excludeCats | csv))[] as $c
          | select(($base | map(.Categories // []) | add // [] | index($c)) == null)
          | "カテゴリ: " + $c]
    | .[]
  ' 2>/dev/null)" || {
    echo "${script_name}: test list の応答を読めませんでした（想定外の形）。" >&2
    report_unity_cmd_failure "$raw"
    exit 3
  }

  if [ -n "$missing" ]; then
    echo "${script_name}: 次の名前が test list（${mode}${SEL_ASSEMBLY:+、アセンブリ ${SEL_ASSEMBLY}}）に見つかりません。綴りを確かめてください。実行はしていません。" >&2
    printf '%s\n' "$missing" | sed 's/^/  /' >&2
    echo "  除く名前はクラスかメソッドの完全名（FullName）で、引数付きのケースはメソッドの完全名で指定します。カテゴリ名は大文字小文字を区別します。" >&2
    exit 1
  fi
}
