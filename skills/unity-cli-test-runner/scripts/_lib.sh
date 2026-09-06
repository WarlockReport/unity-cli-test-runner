#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの各スクリプトが共有するヘルパー関数。
# 単体では実行せず、各スクリプトから `source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"` で読み込んで使う。
#
# 一時的失敗（リトライすれば解消しうる失敗）には2種類ある。
#
# 1. Pipelineサーバーへの到達不能
#    ドメインリロード中（コンパイル完了後の数秒間、およびPlayModeへの遷移直後）、Unity側の
#    Pipeline HTTPサーバーが一時的にダウンし、`unity cmd` が以下のエラーメッセージ付きで
#    失敗することが実測で確認されている（リロードは通常1〜2秒で完了し、Pipelineサーバーは
#    自動的に復帰する）:
#      "No Unity Editor instances found with reachable Pipeline servers."
#
# 2. サーバーがbusyを返す（com.unity.pipeline 0.6.0-exp.1 以降）
#    0.6は、コマンドを実行できない状態を HTTP 503 と構造化エンベロープ
#    （error="Server Busy" / status="busy" / retryable=true / busyReason）で返すようになった。
#    busyReasonは "settling"（エディタ起動直後のインポート・コンパイル中）と
#    "blocked_by_dialog"（モーダルダイアログがメインスレッドを塞いでいる）。
#    本スキルのカスタムコマンドはすべて MainThreadRequired = true なのでどちらにも該当しうる。
#
# どちらも「起動中のエディタが本当に落ちている / 応答しない」場合と区別が付くのは継続時間だけ
# なので、無条件にリトライし続けるのではなく、必ず呼び出し元の予算管理と組み合わせて使う。
# 特に blocked_by_dialog は、ユーザーがダイアログを閉じるまで解消しない（＝予算を使い切って
# 失敗するのが正しい振る舞いで、そのときエラー本文がダイアログの存在を伝える）。

is_transient_pipeline_unreachable() {
  local raw="$1"
  echo "$raw" | grep -qF "No Unity Editor instances found with reachable Pipeline servers"
}

# 0.6以降のbusy応答を検出する。`unity` CLIが503応答をどう整形するかは版によって異なりうるため、
# サーバーが返す構造化フィールドと、CLIが本文へ埋め込むメッセージの両方を拾う
# （既存の400応答では CLI が "Pipeline server returned 400 Bad Request: <error>. <errorDetails>"
# の形で error/errorDetails を本文に埋め込むことを実測で確認済み）。
is_transient_busy() {
  local raw="$1"
  echo "$raw" | grep -qE '"retryable"[[:space:]]*:[[:space:]]*true|"status"[[:space:]]*:[[:space:]]*"busy"|503 Service Unavailable|Server Busy'
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

# editor_status（MainThreadRequired）等のメインスレッド必須コマンドが失敗/タイムアウトした際、
# モーダルダイアログによるメインスレッドブロックかどうかを判別する。
# メインスレッド不要な recompile_status を1回叩き、応答すれば「Pipelineサーバー自体は生きて
# いてメインスレッドだけが塞がれている」＝ダイアログブロックと判定する（check-editor-ready.sh
# のステップ0で先に実測・確認済みだったロジックを共通化したもの）。
# 戻り値: 0=ダイアログブロックと判定（recompile_statusが正常応答した）
#         1=判定つかず（recompile_statusも失敗。真のハングの可能性が高い）
is_blocked_by_dialog() {
  local timeout="$1"
  run_unity_cmd_capture recompile_status --json --timeout "$timeout" >/dev/null 2>&1 &&
    [ "$(echo "$UNITY_CMD_OUT" | jq -r '.success // empty' 2>/dev/null || true)" = "true" ]
}

# `unity cmd` を1回実行し、結果を2つのグローバル変数へ入れる。
#   UNITY_CMD_OUT  … 標準出力のみ（jqでパースするのはこちら）
#   UNITY_CMD_DIAG … 標準出力＋標準エラー（is_transient_failure に渡すのはこちら）
# 一時的失敗のメッセージが標準出力・標準エラーのどちらに出るかはCLIの版・失敗種別に依存するため、
# 判定には両方を結合したものを使い、呼び出し元がパースする値は標準出力だけに保つ。
# 戻り値は `unity cmd` 自体の終了コード。
UNITY_CMD_OUT=""
UNITY_CMD_DIAG=""
run_unity_cmd_capture() {
  local err_file rc
  err_file="$(mktemp)"
  UNITY_CMD_OUT="$(unity cmd "$@" 2>"$err_file")" && rc=0 || rc=$?
  UNITY_CMD_DIAG="${UNITY_CMD_OUT}
$(cat "$err_file")"
  # 改修前の `raw="$(unity cmd ...)"` という形では標準エラーはそのまま端末へ素通りしていた。
  # ここで握り潰すと、標準出力が空で標準エラーにだけ理由が出る失敗（CLIとサーバーの
  # 版不整合などがこの形になる）で「失敗しました」以外の手がかりが消えるため、素通りさせる。
  cat "$err_file" >&2
  rm -f "$err_file"
  return "$rc"
}

# ポーリングループを持たない単発コマンド用。一時的失敗の場合のみ
# 有限のリトライ予算内でリトライし、それ以外の失敗は即座に呼び出し元へ返す。
# 標準出力に生JSONを出す。終了コード:
#   0  成功
#   1  一時的ではない失敗（生JSONは標準出力に出す。呼び出し元で内容を確認すること）
#   2  一時的失敗のままリトライ予算を使い切った（真のハング、またはユーザー操作待ちのダイアログ）
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
      return 0
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
