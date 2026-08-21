#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの各スクリプトが共有するヘルパー関数。
# 単体では実行せず、各スクリプトから `source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"` で読み込んで使う。
#
# ドメインリロード中（コンパイル完了後の数秒間、およびPlayModeへの遷移直後）、Unity側の
# Pipeline HTTPサーバーが一時的にダウンし、`unity cmd` が以下のエラーメッセージ付きで
# 失敗することが実測で確認されている（リロードは通常1〜2秒で完了し、Pipelineサーバーは
# 自動的に復帰する。編集中にエディタが落ちている場合と区別がつかないのは「継続時間」だけ
# なので、無条件でリトライし続けるのではなく、必ず呼び出し元の予算管理と組み合わせて使う）:
#   "No Unity Editor instances found with reachable Pipeline servers."

is_transient_pipeline_unreachable() {
  local raw="$1"
  echo "$raw" | grep -qF "No Unity Editor instances found with reachable Pipeline servers"
}

# ポーリングループを持たない単発コマンド用。transient unreachable の場合のみ
# 有限のリトライ予算内でリトライし、それ以外の失敗は即座に呼び出し元へ返す。
# 標準出力に生JSONを出す。終了コード:
#   0  成功
#   1  transientではない失敗（生JSONは標準出力に出す。呼び出し元で内容を確認すること）
#   2  transient unreachableのままリトライ予算を使い切った（真のハング）
#
# 使い方: run_unity_cmd_resilient <timeout秒> <リトライ予算秒> <unity cmdへの引数...>
run_unity_cmd_resilient() {
  local timeout="$1"
  local retry_budget="$2"
  shift 2

  local retry_interval=1
  local elapsed=0
  local raw

  while true; do
    if raw="$(unity cmd "$@" --timeout "$timeout")"; then
      echo "$raw"
      return 0
    fi

    if ! is_transient_pipeline_unreachable "$raw"; then
      echo "$raw"
      return 1
    fi

    if [ "$elapsed" -ge "$retry_budget" ]; then
      echo "$raw"
      return 2
    fi

    sleep "$retry_interval"
    elapsed=$((elapsed + retry_interval))
  done
}
