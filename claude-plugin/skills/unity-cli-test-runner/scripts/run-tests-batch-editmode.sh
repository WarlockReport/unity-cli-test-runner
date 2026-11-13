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
#   0  結果確定（PASS/FAILは問わない）。標準出力の JSON（status/duration/summary{total,passed,failed,skipped,inconclusive}/
#      results[]{fullName,status,duration,message,stackTrace}。SKILL.mdステップ6参照）を読み、通常の結果報告に進んでよい。
#      要求した名前の一部が見つからなかった・0 件だった場合も 0（標準エラーにその旨を出す）
#   1  引数付きケースの FullName（括弧を含む名前。例: Ns.Class.Method(First,2)）が指定された。実行はしない。
#      名前の中のカンマで区切りが割れるため。引数部分を外したメソッドの FullName を重複を除いて渡し直す
#      （そのメソッドの全ケースが実行される）
#   2  ハング・タイムアウト（一時的切断のリトライ予算超過を含む、`unity cmd`呼び出し自体の失敗）、
#      Unity 側で受理されなかった（テスト実行のタイムアウトを含む）、またはモーダルダイアログ。
#      スキルの「ハング・タイムアウト時の対応」に従う
#   3  版の組み合わせのずれ（コマンドまたは引数が見つからない、unity CLI が古い、UPM パッケージが旧版で応答が PascalCase。
#      標準エラーに診断が出る。再試行せず版を揃えてもらう）、または応答が想定外の形

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if [ "$#" -lt 1 ]; then
  echo "使い方: run-tests-batch-editmode.sh <カンマ区切りFullName> [timeout(既定120)]" >&2
  exit 2
fi

FULL_NAMES="$1"
exit_on_parameterized_case_names "$FULL_NAMES" "run-tests-batch-editmode.sh"
CLI_TIMEOUT="${2:-120}"
ONESHOT_RETRY_BUDGET_SECONDS=15

echo "[1/1] wr.testrunner run_tests_batch_editmode --full-names ${FULL_NAMES}" >&2
raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" wr.testrunner run_tests_batch_editmode --full-names "$FULL_NAMES" --json)" && rc=0 || rc=$?
finish_own_editmode_result "$rc" "$raw" run-tests-batch-editmode.sh "wr.testrunner run_tests_batch_editmode" \
  "指定した完全名のうち実行されたテストが 0 件でした。名前の綴りを確かめてください。"
