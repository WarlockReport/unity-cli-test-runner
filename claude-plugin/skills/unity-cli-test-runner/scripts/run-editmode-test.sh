#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「EditModeテスト実行」（単一テスト／単一クラス／単一アセンブリ）を
# 1コマンドにまとめる。test status ベースライン取得 → test run --mode EditMode --async-tests →
# test status ポーリング → 完了確認 → ベースライン比較（stale検知）→ filter の手がかり確認（testName のときだけ）、を
# 順に実行する。流れは run-playmode-test.sh と同じで、本体は _lib.sh の run_pipeline_test_async にある。
# unity CLI 1.0 の同期 test run は summary の無い結果のストリームしか返さないため、EditMode も非同期で起動し、
# test status の summary 付きの結果を読む。
#
# 使い方: run-editmode-test.sh <filter> <filter-type> [timeout(既定120)] [ポーリング予算秒数(既定=timeout)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI。1.0.0 以降）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  結果確定（PASS/FAILは問わない）。標準出力の JSON（test status のオブジェクト。status/duration/
#      summary{total,passed,failed,skipped,inconclusive}/results[]{fullName,status,duration,message,stackTrace}）を読み、
#      通常の結果報告に進んでよい
#   1  指定した filter に一致するテストが無い（実行していない。標準出力は空。filter と filter-type を見直す）
#   2  ハング・タイムアウト（ポーリング予算超過、一時的切断のリトライ予算超過を含む `unity cmd` 呼び出し自体の失敗）、
#      test run が Unity 側で受理されなかった、結果を持たない終端状態（error / cancelled 等）、
#      またはモーダルダイアログ。スキルの「ハング・タイムアウト時の対応」に従う
#   3  版の組み合わせのずれ（コマンドまたは引数が見つからない、unity CLI が古い。標準エラーに診断が出る。
#      再試行せず版を揃えてもらう）、または完了は検知したが結果が信用できない（前回の結果と同一＝stale の疑い、
#      testName の手がかりが結果に無い、summary を取り出せない。標準エラーのメッセージで区別できる）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if [ "$#" -lt 2 ]; then
  echo "使い方: run-editmode-test.sh <filter> <filter-type> [timeout(既定120)] [ポーリング予算秒数(既定=timeout)]" >&2
  exit 2
fi

FILTER="$1"
FILTER_TYPE="$2"
CLI_TIMEOUT="${3:-120}"
# EditMode はテストの実行時間がそのまま完了までの時間になるので、ポーリング予算の既定は timeout と同じにする
POLL_BUDGET_SECONDS="${4:-$CLI_TIMEOUT}"

run_pipeline_test_async EditMode "$FILTER" "$FILTER_TYPE" "$CLI_TIMEOUT" "$POLL_BUDGET_SECONDS" run-editmode-test.sh
