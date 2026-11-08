#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「EditMode 絞り込み実行」を 1 コマンドにまとめる。
# アセンブリ・含めるカテゴリ・除くカテゴリ・除く完全名を組み合わせ、Unity 側で 1 回の実行として絞り込む
# （wr.testrunner run_tests_filtered_editmode）。完全名の一覧をコマンド行に組み立てないので、数百件のアセンブリから
# 一部を除くときも呼び出しが短い。名前・カテゴリ・アセンブリはすべて完全一致で照合され、名前の先頭が同じ
# 別クラス・別メソッド・別カテゴリを巻き込まない。
#
# 実行前に test list で、指定した名前（アセンブリ・除く名前・カテゴリ）が実在するかを確かめ、1 つでも
# 見つからなければ実行しない。綴りを誤ったまま実行すると、除いたつもりのテストが黙って流れるため。
#
# 使い方: run-tests-filtered-editmode.sh [--assembly <アセンブリ名>] [--exclude <カンマ区切りFullName>]
#           [--include-category <カンマ区切り>] [--exclude-category <カンマ区切り>] [--timeout <秒(既定300)>]
#   --assembly          基準のアセンブリ（完全一致、大文字小文字は区別しない）。省略時は EditMode の全アセンブリ
#   --exclude           除く完全名。クラスの完全名ならクラス全体、メソッドの完全名ならそのメソッド（引数付きの
#                       ケースは全ケース）、名前空間の完全名ならその配下を除く
#   --include-category  含めるカテゴリ（いずれかに当たれば含める。大文字小文字を区別する）
#   --exclude-category  除くカテゴリ（いずれかに当たれば除く。大文字小文字を区別する）
#   絞り込み条件（--timeout 以外）を少なくとも 1 つ指定する
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 終了コード:
#   0  結果確定（PASS/FAILは問わない）。標準出力のJSON（Summary.Total/Passed/Failed、
#      Results[].FullName/Status/Message/StackTrace を含む）を読み、通常の結果報告に進んでよい。
#      指定の組み合わせに当たるテストが 0 件だった場合も 0（標準エラーに 0 件であることを出す）
#   1  実行していない。絞り込み条件が無い、除く名前に引数付きケースの FullName（括弧を含む名前）がある、
#      または指定した名前が test list に見つからない（標準エラーに見つからない名前を列挙する）
#   2  使い方の誤り（未知の引数・値の欠落）、ハング・タイムアウト（一時的切断のリトライ予算超過を含む、
#      `unity cmd`呼び出し自体の失敗）、または Unity 側で受理されなかった。スキルの「ハング・タイムアウト時の対応」に従う
#   3  unity cmd がコマンドまたは引数を見つけられなかった（プラグイン・UPMパッケージ・com.unity.pipeline の版の組み合わせが
#      揃っていない疑い。標準エラーに診断が出る。再試行せず版を揃えてもらう）、または test list の応答が想定外の形

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

SCRIPT_NAME="run-tests-filtered-editmode.sh"
USAGE="${SCRIPT_NAME} [--assembly <名前>] [--exclude <カンマ区切りFullName>] [--include-category <カンマ区切り>] [--exclude-category <カンマ区切り>] [--timeout <秒>]"
ONESHOT_RETRY_BUDGET_SECONDS=15

parse_filtered_args "$SCRIPT_NAME" "$USAGE" "$@"

echo "[1/2] 絞り込み条件の名前を確認" >&2
exit_on_unknown_selection EditMode 30 "$SCRIPT_NAME"

# 指定された絞り込み条件だけをコマンドに渡す（空の引数を渡すと「指定あり」と区別がつかないため）
cmd_args=()
[ -n "$SEL_ASSEMBLY" ] && cmd_args+=(--assembly "$SEL_ASSEMBLY")
[ -n "$SEL_INCLUDE_CATEGORY" ] && cmd_args+=(--include-categories "$SEL_INCLUDE_CATEGORY")
[ -n "$SEL_EXCLUDE_CATEGORY" ] && cmd_args+=(--exclude-categories "$SEL_EXCLUDE_CATEGORY")
[ -n "$SEL_EXCLUDE" ] && cmd_args+=(--exclude-names "$SEL_EXCLUDE")

echo "[2/2] wr.testrunner run_tests_filtered_editmode ${cmd_args[*]}" >&2
raw="$(run_unity_cmd_resilient "$SEL_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" wr.testrunner run_tests_filtered_editmode "${cmd_args[@]}" --json)" && rc=0 || rc=$?
exit_on_version_mismatch "$rc" "$raw"
if [ "$rc" -ne 0 ]; then
  echo "wr.testrunner run_tests_filtered_editmode のunity cmd呼び出し自体が失敗/タイムアウトしました（一時的なドメインリロード切断のリトライ予算超過を含む）。ハング・タイムアウト時の対応に従ってください。" >&2
  report_unity_cmd_failure "$raw"
  exit 2
fi

if [ "$(printf '%s' "$raw" | jq -r '.data.result.success // empty' 2>/dev/null || true)" != "true" ]; then
  error_message="$(printf '%s' "$raw" | jq -r '.data.result.Error // .data.result.error // "(no error message)"' 2>/dev/null || echo "(no error message)")"
  echo "wr.testrunner run_tests_filtered_editmode がUnity側で受理されませんでした（.data.result.success が true ではありません）: ${error_message}" >&2
  exit 2
fi

if [ "$(printf '%s' "$raw" | jq -r '.data.result.Summary.Total // empty' 2>/dev/null || true)" = "0" ]; then
  echo "指定の組み合わせに当たるテストが 0 件でした（名前はすべて実在するが、含める条件と除く条件を合わせると何も残らない）。" >&2
fi

printf '%s\n' "$raw"
exit 0
