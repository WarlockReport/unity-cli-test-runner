#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「EditModeバッチテスト実行」（複数クラス横断の個別FullName集合）を
# 1コマンドにまとめる。wr.testrunner run_tests_batch_editmode を run_unity_cmd_resilient 経由で呼び、起動直後の
# ドメインリロードによる一時的なPipeline切断（_lib.sh参照）を吸収する。wr.testrunner run_tests_batch_editmode は
# 同期応答のため、PlayMode版（run-tests-batch-playmode.sh）と異なりポーリングは不要で、この起動
# 呼び出し1回のみで完結する。
#
# 使い方: run-tests-batch-editmode.sh <カンマ区切りFullName> [timeout(既定120)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  wr.testrunner run_tests_batch_editmode のunity cmd呼び出しに成功。標準出力のJSON（Summary.Total/Passed/
#      Failed、Results[].FullName/Status/Message/StackTrace を含む。SKILL.mdステップ6参照）を読み、
#      通常の結果報告に進んでよい
#   2  ハング・タイムアウト（一時的切断のリトライ予算超過を含む、`unity cmd`呼び出し自体の失敗）。
#      スキルの「ハング・タイムアウト時の対応」に従う
#   3  unity cmd がコマンドを見つけられなかった（プラグイン・UPMパッケージ・com.unity.pipeline の版の組み合わせが
#      揃っていない疑い。標準エラーに診断が出る。再試行せず版を揃えてもらう）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if [ "$#" -lt 1 ]; then
  echo "使い方: run-tests-batch-editmode.sh <カンマ区切りFullName> [timeout(既定120)]" >&2
  exit 2
fi

FULL_NAMES="$1"
CLI_TIMEOUT="${2:-120}"
ONESHOT_RETRY_BUDGET_SECONDS=15

echo "[1/1] wr.testrunner run_tests_batch_editmode --full_names ${FULL_NAMES}" >&2
raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" wr.testrunner run_tests_batch_editmode --full_names "$FULL_NAMES" --json)" && rc=0 || rc=$?
exit_on_version_mismatch "$rc" "$raw"
if [ "$rc" -ne 0 ]; then
  echo "wr.testrunner run_tests_batch_editmode のunity cmd呼び出し自体が失敗/タイムアウトしました（一時的なドメインリロード切断のリトライ予算超過を含む）。ハング・タイムアウト時の対応に従ってください。" >&2
  report_unity_cmd_failure "$raw"
  exit 2
fi

echo "$raw"
exit 0
