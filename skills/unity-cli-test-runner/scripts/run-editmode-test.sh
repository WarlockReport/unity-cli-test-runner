#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「EditModeテスト実行」（単一テスト／単一クラス／単一アセンブリ）を
# 1コマンドにまとめる。run_tests --mode EditMode を run_unity_cmd_resilient 経由で呼び、テスト起動
# 直後のドメインリロードによる一時的なPipeline切断（_lib.sh参照）を吸収する。
# EditModeの run_tests は同期応答のため、PlayMode版（run-playmode-test.sh）と異なりポーリングは
# 不要で、この起動呼び出し1回のみで完結する（ADR-0009）。
#
# 使い方: run-editmode-test.sh <filter> <filter_type> [timeout(既定120)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  run_tests のunity cmd呼び出しに成功。標準出力のJSON（Summary.Total/Passed/Failed、
#      Results[].FullName/Status/Message/StackTrace を含む。SKILL.mdステップ6参照）を読み、
#      通常の結果報告に進んでよい
#   2  ハング・タイムアウト（一時的切断のリトライ予算超過を含む、`unity cmd`呼び出し自体の失敗）。
#      スキルの「ハング・タイムアウト時の対応」に従う

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if [ "$#" -lt 2 ]; then
  echo "使い方: run-editmode-test.sh <filter> <filter_type> [timeout(既定120)]" >&2
  exit 2
fi

FILTER="$1"
FILTER_TYPE="$2"
CLI_TIMEOUT="${3:-120}"
ONESHOT_RETRY_BUDGET_SECONDS=15

echo "[1/1] run_tests --mode EditMode --filter ${FILTER} --filter_type ${FILTER_TYPE}" >&2
if ! raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" run_tests --mode EditMode --filter "$FILTER" --filter_type "$FILTER_TYPE" --json)"; then
  echo "run_tests のunity cmd呼び出し自体が失敗/タイムアウトしました（一時的なドメインリロード切断のリトライ予算超過を含む）。ハング・タイムアウト時の対応に従ってください。" >&2
  exit 2
fi

echo "$raw"
exit 0
