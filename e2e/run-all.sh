#!/usr/bin/env bash
#
# TestProject を開いた起動中の Unity Editor に対して、unity-cli-test-runner スキルのスクリプトを
# 順に実行し、終了コードとテスト結果のサマリーを期待値と照合する E2E 照合スクリプト。
# Pipeline の版上げやスクリプトの変更のあとに、実機での挙動が変わっていないかを 1 コマンドで確かめる。
#
# 使い方: bash e2e/run-all.sh [--pipeline <版>]   （リポジトリ内のどこから実行してもよい）
#
#   --pipeline <版>  起動中の Editor の com.unity.pipeline を一時的に <版>（例: 0.10.0-exp.1）へ差し替えて照合し、
#                    終了時（失敗・中断時も）に TestProject/Packages の manifest.json / packages-lock.json を
#                    git の状態へ戻して再解決させる。旧版の Pipeline でも動くことを確かめるために使う。
#                    スクリプト群が 0.10 専用（引数名・コンパイル完了の判定）のため、0.10 未満の版には切り替えられない
#
# 前提: TestProject を Unity Editor で開いていること。`unity` と `jq` が PATH 上にあること。
#
# 終了コード:
#   0  全段階が期待値どおり
#   1  1 つ以上の段階が期待値と食い違った（標準エラーの FAIL 行と e2e/.out/ を参照）
#   2  接続先が TestProject の Editor でない・Editor が見つからない、または前提の段階
#      （起動確認・コンパイル確定）が期待どおりでなかったため、照合を打ち切った。
#      --pipeline の版が不正・切り替えに失敗した場合もこの終了コード
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

# --pipeline で差し替える版と、差し替えを行ったかどうか（戻す必要があるか）
PIPELINE_VERSION=""
PIPELINE_SWITCHED=0
PIPELINE_POLL_BUDGET_SECONDS=120

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
  if [ "$actual" != "$expected" ]; then
    record_fail "${label} SUMMARY" "期待=[${expected}] 実際=[${actual}]（${OUT_DIR}/${label}.summary を参照）"
    return 1
  fi
  # 件数が期待どおりでも、summary と個別の結果が食い違っている（MISMATCH 行がある）なら、
  # 応答の形が変わった可能性があるため不一致として扱う
  if printf '%s\n' "$summary" | grep -q '^MISMATCH '; then
    record_fail "${label} SUMMARY" "件数は期待どおりだが MISMATCH が出ている（${OUT_DIR}/${label}.summary を参照）"
    return 1
  fi
  record_pass "${label} SUMMARY"
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

# 直前の run_test_case（同じラベル）の結果に、指定したテストが含まれ、別のテストが含まれないことを照合する。
# EditMode の結果は .data.result.Results[]、PlayMode の結果は .results[] に FullName がある
# 使い方: expect_names <ラベル> <含まれるべき FullName（空なら確かめない）> <含まれてはいけない FullName>
expect_names() {
  local label="$1" present="$2" absent="$3" names
  names="$(jq -r '(.data.result.Results // .results // [])[].FullName' "${OUT_DIR}/${label}.out" 2>/dev/null)"
  if [ -n "$present" ] && ! printf '%s\n' "$names" | grep -qxF "$present"; then
    record_fail "${label} テスト名" "「${present}」が結果に無い（${OUT_DIR}/${label}.out を参照）"
    return 1
  fi
  if printf '%s\n' "$names" | grep -qxF "$absent"; then
    record_fail "${label} テスト名" "除いたはずの「${absent}」が結果にある（${OUT_DIR}/${label}.out を参照）"
    return 1
  fi
  record_pass "${label} テスト名"
}

# 段階 0: 接続先が TestProject の Editor であることを確かめる。
# 違う Editor に対して以降を実行すると、そのプロジェクトでテストやコンパイルが走るため、
# 一致しなければ何も実行せずに打ち切る
check_connection() {
  local actual
  # 接続先のプロジェクトの Editor が起動していないと、unity cmd は別の Editor へはつながず失敗する。
  # そのときのエラーは --json の応答として標準出力に出るため、失敗時も .out に残す
  if ! run_saved "0-connection" unity cmd editor status --json --timeout 30; then
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

  # AllPass 2 + MixedResult 5 + Prefix 1 + PrefixExtra 1 + SameName 1 + Parameterized 4 + Categorized 2 + CategoryPrefix 1
  run_test_case "4-editmode-assembly" editmode "total=17 passed=15 failed=1 skipped=1" \
    bash "${SCRIPTS}/run-editmode-test.sh" "Fixtures.EditMode" assembly

  # 複数クラスにまたがる個別の FullName を 1 回で実行できるか（Pass 2 + Fail 1）
  run_test_case "5-editmode-batch" editmode "total=3 passed=2 failed=1 skipped=0" \
    bash "${SCRIPTS}/run-tests-batch-editmode.sh" \
    "Fixtures.EditMode.AllPassFixture.Pass_First,Fixtures.EditMode.MixedResultFixture.Fail_Intentionally,Fixtures.EditMode.PrefixFixtureExtra.Pass_Only"

  # 引数が 2 つある [TestCase] のメソッドを、他のテストと一緒にメソッドの FullName で 1 回で実行できるか
  # （Parameterized 4 ケース + AllPass 1）
  run_test_case "5-editmode-batch-parameterized" editmode "total=5 passed=5 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-tests-batch-editmode.sh" \
    "Fixtures.EditMode.ParameterizedFixture.Multiplier_DependsOnPhase,Fixtures.EditMode.AllPassFixture.Pass_First"

  # ケースの FullName（引数をカンマ区切りで含む）を渡すと、名前が割れてそのケースが静かに抜け落ちるため、
  # スクリプトが実行前に終了コード 1 で止める
  expect_exit "5-editmode-batch-reject-case-name" 1 \
    bash "${SCRIPTS}/run-tests-batch-editmode.sh" \
    "Fixtures.EditMode.ParameterizedFixture.Multiplier_DependsOnPhase(First,2),Fixtures.EditMode.AllPassFixture.Pass_First"
}

# 段階 6: スキルが前提にしている Unity 側の挙動が、今も変わっていないかを確かめる
stage_unity_traps() {
  # testName にカンマ区切りで複数名を渡すと、エラーにならず 0 件で空振りする。
  # この罠があるためにバッチ専用コマンドを用意している。挙動が変わったら設計を見直す合図になる
  run_test_case "6-trap-comma-testname" editmode "total=0 passed=0 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-editmode-test.sh" "Fixtures.EditMode.AllPassFixture,Fixtures.EditMode.PrefixFixture" testName

  # testName は FullName に対する大文字小文字を区別しない部分一致で照合される。そのためクラスの
  # 完全名を渡しても、名前の先頭が同じ別クラス（PrefixFixtureExtra）まで実行される。
  # この罠があるため、スキルは単一テスト・クラスの実行に完全一致のバッチ実行を使う
  run_test_case "6-trap-testname-substring" editmode "total=2 passed=2 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-editmode-test.sh" "Fixtures.EditMode.PrefixFixture" testName

  # バッチ実行は完全一致: 同じ相手に対して、指定した 1 件だけが実行される
  run_test_case "6-batch-exact-match" editmode "total=1 passed=1 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-tests-batch-editmode.sh" "Fixtures.EditMode.PrefixFixture.Pass_Only"

  # test list の Mode でモードを裏取りする手順の前提: 同名クラスがモードごとに別々に列挙される
  local label="6-trap-list-tests-mode" em pm
  if ! run_saved "${label}-editmode" unity cmd test list --mode EditMode --json --timeout 30 \
    || ! run_saved "${label}-playmode" unity cmd test list --mode PlayMode --json --timeout 30; then
    record_fail "$label" "test list の呼び出しに失敗（${OUT_DIR}/${label}-*.out を参照）"
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

# 段階 7: PlayMode の非同期実行（ドメインリロードを越えたポーリング）の集計を照合する。
# PlayMode は 1 回の実行に時間がかかるため、timeout とポーリング予算を広めに取る
stage_playmode() {
  if run_test_case "7-playmode-class" playmode "total=3 passed=2 failed=1 skipped=0" \
    bash "${SCRIPTS}/run-playmode-test.sh" "Fixtures.PlayMode.PlayModeFixture" testName 300 300; then
    expect_fail_line "7-playmode-class" "Fixtures.PlayMode.PlayModeFixture.Fail_Intentionally"
  fi

  run_test_case "7-playmode-batch" playmode "total=2 passed=2 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-tests-batch-playmode.sh" \
    "Fixtures.PlayMode.PlayModeFixture.Pass_AfterOneFrame,Fixtures.PlayMode.SameNameFixture.Pass_Only" 300 300

  # 引数付きのメソッドをメソッドの FullName で指定し、全ケースが実行され整合性チェックも通るか
  # （Parameterized 2 ケース + SameName 1）
  run_test_case "7-playmode-batch-parameterized" playmode "total=3 passed=3 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-tests-batch-playmode.sh" \
    "Fixtures.PlayMode.ParameterizedFixture.Increment_AddsOne,Fixtures.PlayMode.SameNameFixture.Pass_Only" 300 300

  # アセンブリ全体の実行。アセンブリ名と名前空間が一致しない固定台を使い、結果の FullName に
  # アセンブリ名が現れなくても整合性チェックで exit 3 にならないことを確かめる
  run_test_case "7-playmode-assembly-ns-mismatch" playmode "total=1 passed=1 failed=0 skipped=0" \
    bash "${SCRIPTS}/run-playmode-test.sh" "Fixtures.NamespaceMismatch.PlayMode" assembly 300 300
}

# 段階 9: アセンブリ・カテゴリ・除く完全名による絞り込み実行。除いたクラス・メソッド・カテゴリが実行されず、
# 名前の先頭が同じ別クラス（PrefixFixtureExtra）・別カテゴリ（SlowView）が巻き込まれないことを、件数とテスト名で確かめる
stage_filtered() {
  local em="${SCRIPTS}/run-tests-filtered-editmode.sh" pm="${SCRIPTS}/run-tests-filtered-playmode.sh"

  # クラスの完全名で除くと、そのクラスだけが除かれる（前方一致する PrefixFixtureExtra は残る）
  run_test_case "9-filtered-exclude-class" editmode "total=16 passed=14 failed=1 skipped=1" \
    bash "$em" --assembly Fixtures.EditMode --exclude Fixtures.EditMode.PrefixFixture \
    && expect_names "9-filtered-exclude-class" "Fixtures.EditMode.PrefixFixtureExtra.Pass_Only" "Fixtures.EditMode.PrefixFixture.Pass_Only"

  # メソッドの完全名で除くと、同じクラスの他のメソッドは残る
  run_test_case "9-filtered-exclude-method" editmode "total=16 passed=14 failed=1 skipped=1" \
    bash "$em" --assembly Fixtures.EditMode --exclude Fixtures.EditMode.MixedResultFixture.Pass_One \
    && expect_names "9-filtered-exclude-method" "Fixtures.EditMode.MixedResultFixture.Pass_Two" "Fixtures.EditMode.MixedResultFixture.Pass_One"

  # 引数付きメソッドはメソッドの完全名で除くと全ケース（4 件）が除かれる
  run_test_case "9-filtered-exclude-parameterized" editmode "total=13 passed=11 failed=1 skipped=1" \
    bash "$em" --assembly Fixtures.EditMode --exclude Fixtures.EditMode.ParameterizedFixture.Multiplier_DependsOnPhase

  # クラスに付けたカテゴリで除くと配下が除かれ、前方一致する別カテゴリ（SlowView）は残る
  run_test_case "9-filtered-exclude-category" editmode "total=15 passed=13 failed=1 skipped=1" \
    bash "$em" --assembly Fixtures.EditMode --exclude-category Slow \
    && expect_names "9-filtered-exclude-category" "Fixtures.EditMode.CategoryPrefixFixture.Pass_Only" "Fixtures.EditMode.CategorizedFixture.Pass_First"

  # アセンブリを省略し、カテゴリだけで含める（前方一致する別カテゴリは含まない）
  run_test_case "9-filtered-include-category" editmode "total=2 passed=2 failed=0 skipped=0" \
    bash "$em" --include-category Slow \
    && expect_names "9-filtered-include-category" "Fixtures.EditMode.CategorizedFixture.Pass_First" "Fixtures.EditMode.CategoryPrefixFixture.Pass_Only"

  # アセンブリ + 除くカテゴリ 2 つ + 除くクラスの組み合わせ（17 - Slow 2 - ExpectedFailure 1 - Parameterized 4）
  run_test_case "9-filtered-combined" editmode "total=10 passed=9 failed=0 skipped=1" \
    bash "$em" --assembly Fixtures.EditMode --exclude-category Slow,ExpectedFailure --exclude Fixtures.EditMode.ParameterizedFixture

  # 名前空間の完全名でも除ける（名前は実在するので止めず、何も残らないので 0 件）
  run_test_case "9-filtered-exclude-namespace" editmode "total=0 passed=0 failed=0 skipped=0" \
    bash "$em" --include-category Slow --exclude Fixtures.EditMode

  # 綴りを誤った名前（境界の無い前方一致）・存在しないカテゴリ・引数付きケースの名前は実行せずに止める
  expect_exit "9-filtered-not-found-name" 1 \
    bash "$em" --assembly Fixtures.EditMode --exclude Fixtures.EditMode.PrefixFix
  expect_exit "9-filtered-not-found-category" 1 \
    bash "$em" --include-category Slo
  expect_exit "9-filtered-reject-case-name" 1 \
    bash "$em" --exclude "Fixtures.EditMode.ParameterizedFixture.Multiplier_DependsOnPhase(First,2)"

  # PlayMode: アセンブリ 7 件から、カテゴリ Slow（1 件）と失敗するメソッド（1 件）を除く
  run_test_case "9-filtered-playmode" playmode "total=5 passed=5 failed=0 skipped=0" \
    bash "$pm" --assembly Fixtures.PlayMode --exclude-category Slow \
    --exclude Fixtures.PlayMode.PlayModeFixture.Fail_Intentionally --timeout 300 --poll-budget 300 \
    && expect_names "9-filtered-playmode" "Fixtures.PlayMode.PlayModeFixture.Pass_AfterOneFrame" "Fixtures.PlayMode.CategorizedPlayModeFixture.Pass_AfterOneFrame"

  # PlayMode で何も残らない組み合わせでも、ハング扱いにならず 0 件の結果として返る
  run_test_case "9-filtered-playmode-zero" playmode "total=0 passed=0 failed=0 skipped=0" \
    bash "$pm" --include-category Slow --exclude Fixtures.PlayMode --timeout 300 --poll-budget 300
}

# 段階 8 で壊れた .cs を書き込む場所（TestProject/.gitignore で除外済み）
INJECTED_DIR="${PROJECT_PATH}/Assets/E2EInjected"

# 書き込んだコンパイルエラーの仕掛けを削除し、コンパイル状態を回復させる。
# 途中で失敗・中断しても TestProject が壊れたまま残らないよう、EXIT の trap からも呼ぶ
cleanup_injected() {
  if [ -e "$INJECTED_DIR" ] || [ -e "${INJECTED_DIR}.meta" ]; then
    rm -rf "$INJECTED_DIR" "${INJECTED_DIR}.meta"
    echo "後片付け: コンパイルエラーの仕掛けを削除し、コンパイル状態を回復させます" >&2
    if ! bash "${SCRIPTS}/ensure-compile-clean.sh" >/dev/null 2>&1; then
      echo "警告: 後片付け後のコンパイル確認が exit 0 になりませんでした。TestProject の状態を確認してください。" >&2
    fi
  fi
}

# 段階 8: コンパイルエラーを検出できること（exit 1）と、取り除いた後に回復すること（exit 0）を照合する
stage_compile_error() {
  mkdir -p "$INJECTED_DIR"
  cat >"${INJECTED_DIR}/E2EBrokenScript.cs" <<'CS'
// e2e/run-all.sh が一時的に書き込むコンパイルエラーの仕掛け。照合後に削除される
public class E2EBrokenScript
{
    private int broken = ;
}
CS
  expect_exit "8-compile-error-detected" 1 bash "${SCRIPTS}/ensure-compile-clean.sh"
  rm -rf "$INJECTED_DIR" "${INJECTED_DIR}.meta"
  expect_exit "8-compile-error-recovered" 0 bash "${SCRIPTS}/ensure-compile-clean.sh"
}

# 0.10 以上の版かどうか（major.minor を数値で比べる）。0.10 以上なら 0 を返す
is_pipeline_0_10_or_later() {
  local major minor
  major="$(echo "$1" | cut -d. -f1)"
  minor="$(echo "$1" | cut -d. -f2)"
  case "${major}${minor}" in *[!0-9]*|"") return 1 ;; esac
  [ "$major" -gt 0 ] || [ "$minor" -ge 10 ]
}

# --pipeline 指定時に、起動中の Editor の com.unity.pipeline を差し替えてコンパイル完了まで待つ
switch_pipeline() {
  local version="$1"
  echo "Pipeline を ${version} へ一時的に差し替えます" >&2
  # ここから先は失敗しても manifest を戻す必要がある
  PIPELINE_SWITCHED=1
  if ! run_saved "pipeline-switch" unity cmd package add --name "com.unity.pipeline@${version}" \
      --confirm true --wait true --json --timeout 300 \
    || [ "$(jq -r '.data.result.status // empty' "${OUT_DIR}/pipeline-switch.out" 2>/dev/null)" != "completed" ]; then
    echo "com.unity.pipeline@${version} への差し替えに失敗しました（${OUT_DIR}/pipeline-switch.out を参照）。" >&2
    return 1
  fi
  if ! bash "${SCRIPTS}/ensure-compile-clean.sh" 300 >"${OUT_DIR}/pipeline-switch-compile.out" 2>"${OUT_DIR}/pipeline-switch-compile.err"; then
    echo "差し替え後のコンパイルが確定しませんでした（${OUT_DIR}/pipeline-switch-compile.err を参照）。" >&2
    return 1
  fi
}

# 差し替えた Pipeline を git の状態へ戻し、再解決とコンパイル完了まで待つ
restore_pipeline() {
  [ "$PIPELINE_SWITCHED" = "1" ] || return 0
  PIPELINE_SWITCHED=0
  echo "後片付け: TestProject/Packages を git の状態へ戻し、パッケージを再解決します" >&2
  git -C "$REPO_ROOT" checkout -- TestProject/Packages/manifest.json TestProject/Packages/packages-lock.json
  # 照合の直後は Pipeline サーバーが再起動中で接続自体が失敗することがあるため、予算内で再試行する
  local elapsed=0 status=""
  until unity cmd package resolve --json --timeout 120 >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$PIPELINE_POLL_BUDGET_SECONDS" ]; then
      echo "警告: package resolve に失敗しました。TestProject のパッケージ状態を確認してください。" >&2
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  elapsed=0
  while [ "$elapsed" -lt "$PIPELINE_POLL_BUDGET_SECONDS" ]; do
    status="$(unity cmd package status --json --timeout 30 2>/dev/null | jq -r '.data.result.status // empty' 2>/dev/null || true)"
    case "$status" in completed|failed) break ;; esac
    sleep 2
    elapsed=$((elapsed + 2))
  done
  if [ "$status" != "completed" ]; then
    echo "警告: パッケージの再解決が完了しませんでした（package status=${status:-取得できず}）。" >&2
  fi
  if ! bash "${SCRIPTS}/ensure-compile-clean.sh" 300 >/dev/null 2>&1; then
    echo "警告: 再解決後のコンパイル確認が exit 0 になりませんでした。TestProject の状態を確認してください。" >&2
  fi
}

on_exit() {
  cleanup_injected
  restore_pipeline
}

report() {
  echo "----" >&2
  echo "E2E 集計: 一致 ${passed} 件 / 不一致 ${failed} 件（生の出力: ${OUT_DIR}）" >&2
}

main() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pipeline)
        PIPELINE_VERSION="${2:-}"
        if [ -z "$PIPELINE_VERSION" ]; then
          echo "--pipeline には版を指定してください（例: --pipeline 0.10.0-exp.1）。" >&2
          exit 2
        fi
        shift 2
        ;;
      *)
        echo "使い方: bash e2e/run-all.sh [--pipeline <版>]" >&2
        exit 2
        ;;
    esac
  done
  if [ -n "$PIPELINE_VERSION" ] && ! is_pipeline_0_10_or_later "$PIPELINE_VERSION"; then
    echo "0.10 未満の版（${PIPELINE_VERSION}）には切り替えられません（スクリプト群が 0.10 専用のため）。" >&2
    exit 2
  fi

  # 中断（Ctrl+C・kill）されても EXIT の trap を通して後片付けが走るようにする
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap on_exit EXIT

  mkdir -p "$OUT_DIR"
  rm -f "${OUT_DIR}"/*

  if ! check_connection; then report; exit 2; fi
  if [ -n "$PIPELINE_VERSION" ] && ! switch_pipeline "$PIPELINE_VERSION"; then report; exit 2; fi
  if ! expect_exit "1-check-editor-ready" 0 bash "${SCRIPTS}/check-editor-ready.sh"; then report; exit 2; fi
  if ! expect_exit "2-ensure-compile-clean" 0 bash "${SCRIPTS}/ensure-compile-clean.sh"; then report; exit 2; fi

  # --- 段階 3 以降 ---
  stage_editmode
  stage_unity_traps
  stage_playmode
  stage_compile_error
  stage_filtered

  report
  [ "$failed" -eq 0 ]
}

main "$@"
