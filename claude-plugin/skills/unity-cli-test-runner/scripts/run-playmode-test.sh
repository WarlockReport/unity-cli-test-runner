#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「PlayModeテスト実行」を1コマンドにまとめる。
# test status ベースライン取得 → test run --mode PlayMode --async-tests →
# test status ポーリング → 完了確認 → ベースライン比較（同一filter連続実行時のstale検知）→
# 結果に指定filterの手がかりが含まれるかの簡易整合性チェック（testName指定時のみ。異なるfilterへの取り違え検知）、を
# 順に実行する。流れは run-editmode-test.sh と同じで、本体は _lib.sh の run_pipeline_test_async にある。
#
# 使い方: run-playmode-test.sh <filter> <filter-type> [timeout(既定120)] [ポーリング予算秒数(既定90)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI。1.0.0 以降）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  結果確定（PASS/FAILは問わない）。標準出力の JSON（test status のオブジェクト。status/duration/
#      summary{total,passed,failed,skipped,inconclusive}/results[]{fullName,status,duration,message,stackTrace}）を読み、
#      通常の結果報告に進んでよい
#   1  指定した filter に一致するテストが無い（実行していない。標準出力は空。filter と filter-type を見直す）
#   2  ハング・タイムアウト（ポーリング予算超過、`unity cmd`呼び出し自体の失敗を含む）、test run が Unity 側で
#      受理されなかった、結果を持たない終端状態（error / cancelled 等）、またはモーダルダイアログ。
#      スキルの「ハング・タイムアウト時の対応」に従う
#   3  完了は検知したが結果が信用できない。以下の3パターンがあり、どれも標準エラー出力の
#      メッセージで区別できる:
#        - test status の結果から summary / results を取り出せない（想定外のレスポンス形状）
#        - test status の結果が test run 発行前のベースラインと一致（同一filterの連続実行で
#          「前回の完了結果」を取り違えている疑い）。ポーリング中に完了状態かつベースラインと一致する応答を
#          受け取った場合は即断せず、ポーリング予算内は待ち続ける（--async-tests 発行直後のごく短いレース状態を
#          許容するため）。予算を使い切ってもベースラインと一致したままの場合にのみこのパターンで exit 3 となる
#        - test status の結果に指定filterの手がかりが見当たらない（異なるfilterへの取り違えの疑い）。
#          filter-type が testName のときだけ確認する（大文字小文字は区別しない）
#      後の2パターン（stale の疑い）ではUnityコンソールログで InvalidOperationException（TestResultCollector.RunFinished）
#      の有無を確認すること。
#      また、版の組み合わせのずれ（コマンドまたは引数が見つからない、unity CLI が古い。標準エラーに診断が出る。
#      再試行せず版を揃えてもらう）もこの終了コードになる
#
# 注意: PlayMode突入直後はドメインリロードが発生し、その1〜2秒間 unity cmd が一時的に失敗する
# （unity CLI 1.0 では終了コード 6 の「the Editor closed the connection ...」や終了コード 12 の
# 「No Pipeline instance found for project」。_lib.sh参照）。test status ポーリング中にこれを検知した場合は
# ハング扱いにせずポーリングを継続する。test run --async-tests の起動呼び出し自体がこの瞬断に当たることも
# あるため、こちらは run_unity_cmd_resilient（有限予算の単発リトライ）で吸収する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

if [ "$#" -lt 2 ]; then
  echo "使い方: run-playmode-test.sh <filter> <filter-type> [timeout(既定120)] [ポーリング予算秒数(既定90)]" >&2
  exit 2
fi

FILTER="$1"
FILTER_TYPE="$2"
CLI_TIMEOUT="${3:-120}"
POLL_BUDGET_SECONDS="${4:-90}"

run_pipeline_test_async PlayMode "$FILTER" "$FILTER_TYPE" "$CLI_TIMEOUT" "$POLL_BUDGET_SECONDS" run-playmode-test.sh
