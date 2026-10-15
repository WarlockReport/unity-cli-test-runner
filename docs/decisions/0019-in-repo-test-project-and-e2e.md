# ADR-0019: リポジトリ内に検証用 Unity プロジェクト（TestProject）と E2E 照合スクリプトを置く

## Status

Accepted (2026-10-15)

## Context

- これまで UPM パッケージの C# はこのリポジトリ内でコンパイルさせる手段が無く、スクリプト・スキルの実機検証は、
  別の Unity プロジェクトへ git URL で導入して手作業で行っていた。検証のたびに、そのプロジェクトのどのテストを
  使うかを決め直す必要があり、結果の再現性も低かった
- Pipeline の版上げ（0.6・0.7・0.8）のたびに、同じ実機検証をやり直してきた
- プラグイン本体を `claude-plugin/` に移したことで（ADR-0018）、リポジトリのルートに置いたものは利用者の
  プラグインキャッシュにも UPM パッケージにも入らなくなった

## Decision

- リポジトリのルートに Unity 6000.3.25f1 のプロジェクト `TestProject/` を置き、`unity/` を `file:../../unity` で参照する。
  `com.unity.pipeline` は 0.8.0-exp.1 に固定する。プロジェクトは `unity projects create`（3D Built-In テンプレート、
  `--with-pipeline --no-cloud`）で生成した
- `TestProject/Assets/Fixtures/` に、結果が既知の固定台のテスト（EditMode: 成功のみ・成功/失敗/スキップ混在・
  前方一致するクラス名・PlayMode と同名のクラス、PlayMode: フレームをまたぐ成功/失敗・EditMode と同名のクラス）を置く
- `e2e/run-all.sh` が、起動中の Editor に対してスキルのスクリプトを順に実行し、終了コードと
  `summarize-test-result.sh` の SUMMARY 行（total/passed/failed/skipped）を期待値と照合する。
  コンパイルエラーの検出と回復も、壊れた `.cs` を一時的に書き込んで照合する
- 接続先は、環境変数 `UNITY_PROJECT_PATH` を TestProject に設定して固定する（`unity cmd` がこの変数で接続先を選ぶ）。
  さらに `editor_status` の `projectPath` を照合し、一致しなければ何も実行せずに打ち切る
- テスト名の解決（クラス名の境界一致、`list_tests` によるモードの裏取り）はスキルの手順（LLM の判断）にあるため、
  E2E ではスキルが前提にしている Unity 側の挙動の存続だけを検査し、解決の正しさは手動シナリオで確かめる
- CI では実行しない。ダイアログによるブロックの再現は対象外とする

## Consequences

- Pipeline の版上げやスクリプトの変更のあと、TestProject を開いて `bash e2e/run-all.sh` を実行するだけで、
  実機での挙動を再検証できる
- 固定台のテストの件数は E2E の期待値と結びつく。テストを変えたら期待値も直す必要がある
- 意図的に失敗するテストを含むため、TestProject の Test Runner で全件を実行すると赤が出る
- Unity の版を上げるときは、TestProject の版も上げて E2E で再検証する

## 実地検証

実地検証済み（2026-10-15、Unity 6000.3.25f1 + `com.unity.pipeline` 0.8.0-exp.1、Claude Code 2.1.300）。

- `bash e2e/run-all.sh` が全 22 件一致で exit 0 になった（所要 約 80 秒）。別プロジェクトの Editor を同時に起動した状態で行った
- 期待値を 1 つ変えると exit 1、TestProject の Editor を閉じた状態では exit 2 で段階 1 以降を実行しなかった
- `UNITY_PROJECT_PATH` が起動していないプロジェクトを指すと、`unity cmd` は別の Editor へはつながず、
  `No Pipeline instance found for project: <パス>` で失敗する（rc=6、エラーは `--json` の応答として標準出力に出る）
- Editor にフォーカスが無い状態でも、`ensure-compile-clean.sh`（内部で `recompile`）が新しく書き込んだ `.cs` を取り込んでコンパイルした。
  Refresh を別に呼ぶ必要は無かった
- 段階 8 で壊れた `.cs` を書き込んだ直後に E2E を `kill -TERM` しても、仕掛けは削除され、直後のコンパイル確認は exit 0 だった
- Unity 側の挙動: `testName` にテストクラスの完全名を渡すとクラス内の全テストが実行される。`[Ignore]` は skipped に数えられる。
  `testName` にカンマ区切りで複数名を渡すと、今も 0 件で空振りする。`list_tests` は同名クラスをモードごとに別々に列挙する
- 手動シナリオ（`unity-test-runner` エージェント）:
  - 「`PrefixFixture` を実行して」: **期待どおりにならなかった**。エージェントは `list_tests` でクラス境界を考慮して
    `Fixtures.EditMode.PrefixFixture.Pass_Only` の 1 件に正しく絞り込んだが、実行時は短いクラス名 `PrefixFixture` を
    `testName` に渡した。Unity の `testName` フィルターが `PrefixFixtureExtra` まで一致させ、2 件が実行された
    （エージェントは報告で、`list_tests` の 1 件と実行結果の 2 件の食い違いを明示した）。
    候補の絞り込みだけでなく、実行時にも完全名を渡す必要があることを示している。スキルの修正は別の作業として扱う
  - 「`SameNameFixture` を EditMode で実行して」: 期待どおり。`list_tests` で両モードの同名クラスを識別し、
    EditMode の 1 件だけを実行した（実行時に渡したのは短いクラス名だが、前方一致する別クラスが無いため結果は正しかった）
