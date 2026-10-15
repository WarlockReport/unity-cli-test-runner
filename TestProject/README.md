# TestProject

unity-cli-test-runner の開発・検証用の Unity プロジェクトです。利用者が導入するものではありません
（プラグインのキャッシュにも UPM パッケージにも含まれません）。

- **パッケージ開発の作業場所**: `Packages/manifest.json` が `unity/` を `file:../../unity` で参照しているため、
  `unity/` の C# を編集するとそのまま Editor に反映されます
- **実機検証の固定台**: `Assets/Fixtures/` に結果が既知のテストを置いています。`e2e/run-all.sh` がこれを使って、
  スキルのスクリプトの挙動を照合します

## 前提

- Unity 6000.3.25f1（ほかの版で開くとアップグレードを求められます。版を上げる場合は `e2e/run-all.sh` で再検証してください）
- `com.unity.pipeline` 0.8.0-exp.1

## 意図的に失敗・スキップするテストがあります

Test Runner で全件を実行すると、次のテストが失敗・スキップになります。これは意図どおりです。
失敗するテストには `ExpectedFailure` カテゴリを付けています。

| テスト | 結果 |
| --- | --- |
| `Fixtures.EditMode.MixedResultFixture.Fail_Intentionally` | 失敗 |
| `Fixtures.EditMode.MixedResultFixture.Skip_Intentionally` | スキップ |
| `Fixtures.PlayMode.PlayModeFixture.Fail_Intentionally` | 失敗 |

## 固定台のテストを変えるとき

テストの件数・結果は `e2e/run-all.sh` の期待値と結びついています。テストを増減・変更したら、
`e2e/run-all.sh` の期待値も同時に直してください。

## E2E の実行

このプロジェクトを Unity で開いた状態で、リポジトリ内のどこからでも次を実行します。

    bash e2e/run-all.sh

終了コードは 0（全件一致）・1（不一致あり）・2（接続先が TestProject でない、または前提の段階で失敗）です。
生の出力は `e2e/.out/` に残ります。別のプロジェクトの Editor が同時に起動していても、接続先は
`UNITY_PROJECT_PATH` で TestProject に固定されます。

## 手動で確かめるシナリオ

テスト名の解決は、スクリプトではなくスキルの手順（LLM の判断）で行うため、E2E では検証できません。
Claude Code で `unity-test-runner` エージェントに次のように依頼し、結果を確かめます。
依頼文では、対象プロジェクトがこの TestProject であることと、`UNITY_PROJECT_PATH` を設定することを伝えてください。

| 依頼 | 期待される結果 |
| --- | --- |
| 「`PrefixFixture` のテストを実行して」 | `Fixtures.EditMode.PrefixFixture.Pass_Only` の 1 件だけを実行する（`PrefixFixtureExtra` を巻き込まない） |
| 「`SameNameFixture` を EditMode で実行して」 | `Fixtures.EditMode.SameNameFixture.Pass_Only` の 1 件だけを EditMode で実行する |