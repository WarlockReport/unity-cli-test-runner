#!/usr/bin/env bash
#
# TestProject を開いた起動中の Unity Editor に対して、unity-cli-test-runner スキルのスクリプトを
# 順に実行し、終了コードとテスト結果のサマリーを期待値と照合する E2E 照合スクリプト。
# Pipeline の版上げやスクリプトの変更のあとに、実機での挙動が変わっていないかを 1 コマンドで確かめる。
#
# 使い方: bash e2e/run-all.sh   （リポジトリ内のどこから実行してもよい。引数なし）
#
# 前提: TestProject を Unity Editor で開いていること。`unity` と `jq` が PATH 上にあること。
#
# 終了コード:
#   0  全段階が期待値どおり
#   1  1 つ以上の段階が期待値と食い違った（標準エラーの FAIL 行と e2e/.out/ を参照）
#   2  接続先が TestProject の Editor でない・Editor が見つからない、または前提の段階
#      （起動確認・コンパイル確定）が期待どおりでなかったため、照合を打ち切った
#
# 固定台（TestProject/Assets/Fixtures）のテストを増減したら、下の期待値も同時に直すこと。

set -uo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${E2E_DIR}/.." && pwd -P)"
SCRIPTS="${REPO_ROOT}/claude-plugin/skills/unity-cli-test-runner/scripts"
PROJECT_PATH="${REPO_ROOT}/TestProject"
OUT_DIR="${E2E_DIR}/.out"

# 子プロセス（スキルのスクリプト）が呼ぶ unity cmd の接続先を TestProject の Editor に固定する。
# 別プロジェクトの Editor が同時に起動していても、そちらでテストやコンパイルを走らせないため
export UNITY_PROJECT_PATH="${PROJECT_PATH}"

passed=0
failed=0

record_pass() { passed=$((passed + 1)); echo "PASS  $1" >&2; }
record_fail() { failed=$((failed + 1)); echo "FAIL  $1: $2" >&2; }

# コマンドを実行し、標準出力を ${OUT_DIR}/<ラベル>.out、標準エラーを .err に保存する。
# 戻り値はコマンドの終了コード
run_saved() {
  local label="$1"; shift
  "$@" >"${OUT_DIR}/${label}.out" 2>"${OUT_DIR}/${label}.err"
}

# 終了コードが期待値と一致するかを照合する
# 使い方: expect_exit <ラベル> <期待する終了コード> <コマンド...>
expect_exit() {
  local label="$1" expected="$2"; shift 2
  local actual=0
  run_saved "$label" "$@" || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    record_pass "$label"
    return 0
  fi
  record_fail "$label" "終了コード 期待=${expected} 実際=${actual}（${OUT_DIR}/${label}.err を参照）"
  return 1
}

# テスト実行スクリプトを実行し、終了コードが 0 であることと、summarize-test-result.sh の
# SUMMARY 行の total/passed/failed/skipped が期待値と一致することを照合する。
# テストの Pass/Fail は実行スクリプトの終了コードに出ない（呼び出しに成功すれば 0）ため、
# 結果の照合は SUMMARY 行で行う。duration は毎回変わるので照合から外す
# 使い方: run_test_case <ラベル> <editmode|playmode> "total=N passed=N failed=N skipped=N" <コマンド...>
run_test_case() {
  local label="$1" mode="$2" expected="$3"; shift 3
  expect_exit "$label" 0 "$@" || return 1
  local summary actual
  summary="$(bash "${SCRIPTS}/summarize-test-result.sh" "${OUT_DIR}/${label}.out" "$mode" 2>"${OUT_DIR}/${label}.summary.err")"
  printf '%s\n' "$summary" >"${OUT_DIR}/${label}.summary"
  actual="$(printf '%s\n' "$summary" | grep -m1 '^SUMMARY ' \
    | grep -oE '(total|passed|failed|skipped)=[0-9]+' | tr '\n' ' ' | sed 's/ $//')"
  if [ "$actual" = "$expected" ]; then
    record_pass "${label} SUMMARY"
    return 0
  fi
  record_fail "${label} SUMMARY" "期待=[${expected}] 実際=[${actual}]（${OUT_DIR}/${label}.summary を参照）"
  return 1
}

# 直前の run_test_case（同じラベル）の集計結果に、指定したテストの FAIL 行があるかを照合する
# 使い方: expect_fail_line <ラベル> <テストの FullName>
expect_fail_line() {
  local label="$1" fullname="$2"
  if grep -qxF "FAIL ${fullname}" "${OUT_DIR}/${label}.summary"; then
    record_pass "${label} FAIL 行"
    return 0
  fi
  record_fail "${label} FAIL 行" "「FAIL ${fullname}」が無い（${OUT_DIR}/${label}.summary を参照）"
  return 1
}

# 段階 0: 接続先が TestProject の Editor であることを確かめる。
# 違う Editor に対して以降を実行すると、そのプロジェクトでテストやコンパイルが走るため、
# 一致しなければ何も実行せずに打ち切る
check_connection() {
  local actual
  # 接続先のプロジェクトの Editor が起動していないと、unity cmd は別の Editor へはつながず失敗する。
  # そのときのエラーは --json の応答として標準出力に出るため、失敗時も .out に残す
  if ! run_saved "0-connection" unity cmd editor_status --json --timeout 30; then
    echo "TestProject の Editor に接続できません。TestProject を Unity で開いてから再実行してください（${OUT_DIR}/0-connection.out を参照）。" >&2
    return 1
  fi
  actual="$(jq -r '.data.result.projectPath // empty' "${OUT_DIR}/0-connection.out" 2>/dev/null)"
  if [ -z "$actual" ] || [ "$(cd "$actual" 2>/dev/null && pwd -P)" != "$(cd "$PROJECT_PATH" && pwd -P)" ]; then
    echo "接続先が TestProject ではありません（projectPath=${actual:-取得できず}）。" >&2
    return 1
  fi
  record_pass "0-connection"
}

# 段階 3〜5: EditMode のクラス単位・アセンブリ単位・バッチ実行の集計を照合する
stage_editmode() {
  run_test_case "3-editmode-class-allpass" editmode "total=2 passed=2 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-editmode-test.sh" "Fixtures.EditMode.AllPassFixture" testName

  if run_test_case "3-editmode-class-mixed" editmode "total=5 passed=3 failed=1 skipped=1" \
    bash "${SCRIPTS}/run-editmode-test.sh" "Fixtures.EditMode.MixedResultFixture" testName; then
    expect_fail_line "3-editmode-class-mixed" "Fixtures.EditMode.MixedResultFixture.Fail_Intentionally"
  fi

  # AllPass 2 + MixedResult 5 + Prefix 1 + PrefixExtra 1 + SameName 1
  run_test_case "4-editmode-assembly" editmode "total=10 passed=8 failed=1 skipped=1" \
    bash "${SCRIPTS}/run-editmode-test.sh" "Fixtures.EditMode" assembly

  # 複数クラスにまたがる個別の FullName を 1 回で実行できるか（Pass 2 + Fail 1）
  run_test_case "5-editmode-batch" editmode "total=3 passed=2 failed=1 skipped=0" \
    bash "${SCRIPTS}/run-tests-batch-editmode.sh" \
    "Fixtures.EditMode.AllPassFixture.Pass_First,Fixtures.EditMode.MixedResultFixture.Fail_Intentionally,Fixtures.EditMode.PrefixFixtureExtra.Pass_Only"
}

# 段階 6: スキルが前提にしている Unity 側の挙動が、今も変わっていないかを確かめる
stage_unity_traps() {
  # testName にカンマ区切りで複数名を渡すと、エラーにならず 0 件で空振りする。
  # この罠があるためにバッチ専用コマンドを用意している。挙動が変わったら設計を見直す合図になる
  run_test_case "6-trap-comma-testname" editmode "total=0 passed=0 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-editmode-test.sh" "Fixtures.EditMode.AllPassFixture,Fixtures.EditMode.PrefixFixture" testName

  # list_tests の Mode でモードを裏取りする手順の前提: 同名クラスがモードごとに別々に列挙される
  local label="6-trap-list-tests-mode" em pm
  if ! run_saved "${label}-editmode" unity cmd list_tests --mode EditMode --json --timeout 30 \
    || ! run_saved "${label}-playmode" unity cmd list_tests --mode PlayMode --json --timeout 30; then
    record_fail "$label" "list_tests の呼び出しに失敗（${OUT_DIR}/${label}-*.out を参照）"
    return 1
  fi
  em="$(jq -r '[.data.result.Tests[] | select(.FullName | test("\\.SameNameFixture\\.")) | "\(.FullName)@\(.Mode)"] | sort | join(",")' \
    "${OUT_DIR}/${label}-editmode.out" 2>/dev/null)"
  pm="$(jq -r '[.data.result.Tests[] | select(.FullName | test("\\.SameNameFixture\\.")) | "\(.FullName)@\(.Mode)"] | sort | join(",")' \
    "${OUT_DIR}/${label}-playmode.out" 2>/dev/null)"
  if [ "$em" = "Fixtures.EditMode.SameNameFixture.Pass_Only@EditMode" ] \
    && [ "$pm" = "Fixtures.PlayMode.SameNameFixture.Pass_Only@PlayMode" ]; then
    record_pass "$label"
    return 0
  fi
  record_fail "$label" "EditMode=[${em}] PlayMode=[${pm}]"
  return 1
}

report() {
  echo "----" >&2
  echo "E2E 集計: 一致 ${passed} 件 / 不一致 ${failed} 件（生の出力: ${OUT_DIR}）" >&2
}

main() {
  mkdir -p "$OUT_DIR"
  rm -f "${OUT_DIR}"/*

  if ! check_connection; then report; exit 2; fi
  if ! expect_exit "1-check-editor-ready" 0 bash "${SCRIPTS}/check-editor-ready.sh"; then report; exit 2; fi
  if ! expect_exit "2-ensure-compile-clean" 0 bash "${SCRIPTS}/ensure-compile-clean.sh"; then report; exit 2; fi

  # --- 段階 3 以降 ---
  stage_editmode
  stage_unity_traps

  report
  [ "$failed" -eq 0 ]
}

main "$@"
