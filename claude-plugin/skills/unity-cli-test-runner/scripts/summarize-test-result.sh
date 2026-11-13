#!/usr/bin/env bash
#
# テスト結果JSONから、報告にそのまま貼るためのブロックだけを生成する。
#
# 実運用で、サブエージェントがツール出力と矛盾する最終報告（件数が多め、Failが消える、
# テスト名がもっともらしい別名に置き換わる）を返す事象が観測された。報告文を自然語で
# 組み立てさせる限り指示では防ぎきれないため、報告文そのものをこのスクリプトが機械的に
# 生成する。数値を捏造しないことが唯一の存在理由なので、summary を取り出せない場合は
# 「0件」「全件PASS」と出力せず exit 3 で明示的に失敗する。
#
# 使い方: summarize-test-result.sh <結果JSONファイル> <editmode|playmode>
#
# 入力（既存スクリプトの標準出力を保存したファイル）:
#   editmode … run-editmode-test.sh / run-tests-batch-editmode.sh / run-tests-filtered-editmode.sh の出力
#   playmode … run-playmode-test.sh / run-tests-batch-playmode.sh / run-tests-filtered-playmode.sh の出力
#   どちらも同じ camelCase の形 {status, duration, summary:{total,passed,failed,skipped,inconclusive},
#   results:[{fullName,status,duration,message,stackTrace}]}（com.unity.pipeline 1.0 の test status と同じ形）。
#   モードは SUMMARY 行の表示にだけ使う。旧形式（.data.result のエンベロープ、PascalCase のキー）は読まない。
#   読み違えた件数を報告するより、読めないことを明示する方が安全なため、exit 3 にする。
#
# 出力（標準出力。これをそのまま報告へ貼る）:
#   SUMMARY mode=playmode total=89 passed=88 failed=1 skipped=0 inconclusive=0 duration=41.2
#   FAIL SomeTests.SomeTestCase.テスト名
#     System.Exception: エラーメッセージ
#     at SomeClass.SomeMethod () [0x00001] in <filename unknown>:0
#   FAIL AnotherTests.AnotherTestCase.別のテスト名
#     NullReferenceException: Object reference not set to an instance of an object
#     at AnotherClass.AnotherMethod () [0x00002] in <filename unknown>:0
#   MISMATCH summary.failed=1 results内のFailed=0 結果JSONが不完全な可能性。SOURCEの生JSONを確認すること
#   SOURCE /var/folders/xx/unity-test-abc123.json
#
#   （出力順: SUMMARY → FAIL ブロック群 → MISMATCH（省略可、食い違いがある場合のみ出現） → SOURCE）
#
#   summary を取り出せなかった場合（exit 3）は上記と異なり、標準出力には
#   `SOURCE <結果JSONの絶対パス>` の1行だけを出す（SUMMARY/FAIL/MISMATCHは出さない）。
#   件数が分からない以上、報告に書ける事実は「summaryを取り出せなかったこと」と
#   「生JSONの場所」だけであり、それ以外を捏造・省略させないための契約。
#
# 応答に含まれないフィールドは n/a と出す（値を推測して埋めない）。
#
# 終了コード:
#   0  要約を出力した（FAILの有無は問わない）
#   2  引数不正、ファイルが無い、JSONとしてパースできない
#   3  想定したパスから summary を取り出せなかった。標準出力には `SOURCE` 行のみを出し
#      （SUMMARY等は出さない）、診断メッセージと生JSONの先頭は標準エラーへ出す
#
# 前提: `jq` がPATH上にあること。

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "使い方: summarize-test-result.sh <結果JSONファイル> <editmode|playmode>" >&2
  exit 2
fi

RESULT_FILE="$1"
MODE="$2"

case "$MODE" in
  editmode | playmode) ;;
  *)
    echo "第2引数は editmode または playmode を指定してください（受け取った値: ${MODE}）。" >&2
    exit 2
    ;;
esac

if [ ! -f "$RESULT_FILE" ]; then
  echo "結果JSONファイルが見つかりません: ${RESULT_FILE}" >&2
  exit 2
fi

if ! jq -e . "$RESULT_FILE" >/dev/null 2>&1; then
  echo "JSONとしてパースできません: ${RESULT_FILE}" >&2
  exit 2
fi

# 報告のSOURCE行に出す絶対パス。コントローラーが後から jq で裏取りするために使う。
SOURCE_PATH="$(cd "$(dirname "$RESULT_FILE")" && pwd)/$(basename "$RESULT_FILE")"

# 旧形式（unity CLI 1.0 より前のエンベロープ、または旧版の PascalCase のキー）は読まない。
legacy_reason="$(jq -r '
  if type != "object" then empty
  elif (.data | type) == "object" then ".data.result のエンベロープ（unity CLI 1.0 より前の形式）"
  elif has("Summary") or has("Results") then "PascalCase の Summary / Results（旧版の形式）"
  elif ((.results // [])[0] | type == "object" and has("FullName")) then "results[] の PascalCase のキー（旧版の形式）"
  else empty end
' "$RESULT_FILE" 2>/dev/null || true)"

# summary オブジェクト（キーは total/passed/failed/skipped/inconclusive）。
summary=""
if [ -z "$legacy_reason" ]; then
  summary="$(jq -c 'if type == "object" and (.summary | type) == "object" then .summary else empty end' "$RESULT_FILE")"
fi

if [ -z "$summary" ]; then
  if [ -n "$legacy_reason" ]; then
    echo "結果JSONが旧形式でした（${legacy_reason}）。このスクリプトは camelCase の結果だけを読みます。件数を推測せず中断します。生JSONの先頭:" >&2
  else
    echo "summary を取り出せませんでした（.summary が無い）。件数を推測せず中断します。生JSONの先頭:" >&2
  fi
  head -c 500 "$RESULT_FILE" >&2
  echo >&2
  # SUMMARY/FAILは出せない（件数が分からないため）が、SOURCEだけは常に出す契約にする。
  # 報告手順が「exit 3ならSOURCEパスを報告する」を要求しているため、ここで省略すると
  # 呼び出し元が捏造するか省略するかの二択に追い込まれてしまう。
  echo "SOURCE ${SOURCE_PATH}"
  exit 3
fi

# duration は結果オブジェクトの直下から読む。無ければ read_field の n/a に委ねる（推測で埋めない）。
meta="$(jq -c 'if type == "object" then . else {} end' "$RESULT_FILE")"

# 指定キーを読む。無ければ n/a（推測で埋めない）。
read_field() {
  local key="$1" json="$2"
  echo "$json" | jq -r --arg k "$key" '.[$k] // "n/a"'
}

printf 'SUMMARY mode=%s total=%s passed=%s failed=%s skipped=%s inconclusive=%s duration=%s\n' \
  "$MODE" \
  "$(read_field total "$summary")" \
  "$(read_field passed "$summary")" \
  "$(read_field failed "$summary")" \
  "$(read_field skipped "$summary")" \
  "$(read_field inconclusive "$summary")" \
  "$(read_field duration "$meta")"

# 失敗したテストの詳細。message/stackTrace は複数行になるため先頭行だけを出す（報告を短く保ち、
# かつ原文のまま貼れるようにするため。全文は SOURCE の生JSONにある）。
results="$(jq -c 'if (.results | type) == "array" then .results else [] end' "$RESULT_FILE")"

echo "$results" | jq -r '
  .[]
  | select((.status // "Passed") != "Passed")
  | ["FAIL " + (.fullName // "(fullName不明)")]
    + ((.message // "") | split("\n") | map(select(length > 0)) | .[0:1] | map("  " + .))
    + ((.stackTrace // "") | split("\n") | map(select(length > 0)) | .[0:1] | map("  " + .))
  | .[]
'

# summary の failed 件数と、results 内の Failed 要素数が食い違っていないかを確認する。
# 食い違う場合、結果JSONが不完全（stale、途中で切れている等）である可能性が高い。報告が
# データより楽観的に見えるのを防ぐため、黙って通さず1行で明示する。
# Skipped/Inconclusive は summary で別に数えられるので、比較は Failed のみに限る。
failed_in_summary="$(read_field failed "$summary")"
failed_in_results="$(echo "$results" | jq '[.[] | select((.status // "") == "Failed")] | length')"

if [ "$failed_in_summary" != "n/a" ] && [ "$failed_in_summary" != "$failed_in_results" ]; then
  echo "MISMATCH summary.failed=${failed_in_summary} results内のFailed=${failed_in_results} 結果JSONが不完全な可能性。SOURCEの生JSONを確認すること"
fi

echo "SOURCE ${SOURCE_PATH}"
