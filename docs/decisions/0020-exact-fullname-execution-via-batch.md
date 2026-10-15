# ADR-0020: 単一テスト・クラスの実行を、完全一致のバッチ実行に切り替える

## Status

Accepted (2026-10-15)

## Context

- TestProject の手動シナリオで、`unity-test-runner` エージェントに「`PrefixFixture` を実行して」と依頼したところ、
  `PrefixFixtureExtra` のテストまで実行された（ADR-0019）。エージェントは `list_tests` でクラス境界を考慮し、
  候補を 1 件に正しく絞り込んでいたが、実行時には SKILL.md の指示どおり `--filter_type testName` にクラス名を渡していた
- `com.unity.pipeline` 0.8.0-exp.1 の `run_tests` は、`testName` を各テストの `FullName` に対する、`assembly` を
  アセンブリ名に対する、大文字小文字を区別しない部分一致で照合する（`Editor/Testing/PipelineTestRunner.cs` の
  `ShouldIncludeTest` が `IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0` を使っている）
- そのため、クラスの完全名を渡しても名前の先頭が同じ別クラスまで、単一テストの完全名を渡しても名前の先頭が同じ
  別メソッドまで実行される。SKILL.md の「`run_tests` 側の filter は厳密一致」（ADR-0010 の事例の記述）と
  「部分一致・プレフィックス一致の挙動は未検証」は、現行の Pipeline では誤り、または未確認のままだった
- 一方、このパッケージの `run_tests_batch_editmode` / `run_tests_batch_playmode` は、Unity の `Filter.testNames`
  に完全名の配列を直接渡すため、完全一致で実行される

## Decision

- 単一テスト・クラス一括の実行は、ステップ2で `list_tests` から絞り込んだ `FullName` の一覧を
  `run-tests-batch-editmode.sh` / `run-tests-batch-playmode.sh` に渡して行う（1 件でもバッチスクリプトを使う）
- `run-editmode-test.sh` / `run-playmode-test.sh` は、アセンブリ全体の実行（`assembly`）にだけ使う。
  ただし `list_tests` の `Assembly` に、対象の名前を部分文字列として含む別のアセンブリがある場合は、
  そのアセンブリに属する `FullName` の一覧をバッチスクリプトに渡す
- SKILL.md の誤った記述（`testName` が厳密一致、クラス名を `testName` に渡す手順）を改め、
  「既知の罠」と「禁止事項」に部分一致であることと、単一テスト・クラスに `testName` を使わないことを書く
- E2E（`e2e/run-all.sh`）の段階 6 に、`testName` の部分一致の罠（クラスの完全名で 2 件実行される）と、
  バッチの完全一致（同じ相手に対して 1 件だけ実行される）の確認を加える
- スクリプト・UPM パッケージは変更しない。プラグインの版を 0.6.0 → 0.7.0 に上げる

## Consequences

- クラス・単一テストの実行で、名前の先頭が同じ別クラス・別メソッドを巻き込まなくなる
- クラス一括の実行でも、ステップ2で得た `FullName` の一覧を渡すため、メソッド数が多いクラスでは引数が長くなる
- `testName` を部分一致として使う経路がスキルから無くなるため、Pipeline が将来照合方法を変えても影響を受けにくい。
  照合方法の変化は E2E の段階 6 で検出できる

## 実地検証

実地検証済み（2026-10-15、Unity 6000.3.25f1 + `com.unity.pipeline` 0.8.0-exp.1、TestProject）。

- `run-editmode-test.sh "Fixtures.EditMode.PrefixFixture" testName` で `PrefixFixture` と `PrefixFixtureExtra` の
  2 件が実行され、`run-tests-batch-editmode.sh "Fixtures.EditMode.PrefixFixture.Pass_Only"` では 1 件だけが実行された
- `bash e2e/run-all.sh` が、上記 2 件の確認を加えた全 26 件の一致で exit 0
- 修正後の SKILL.md を読み込んだ `unity-test-runner` エージェントで、TestProject の手動シナリオを再実行した。
  「`PrefixFixture` を実行して」は `run-tests-batch-editmode.sh Fixtures.EditMode.PrefixFixture.Pass_Only` で
  1 件だけが実行され（`PrefixFixtureExtra` を巻き込まない）、「`SameNameFixture` を EditMode で実行して」は
  `run-tests-batch-editmode.sh Fixtures.EditMode.SameNameFixture.Pass_Only` で EditMode の 1 件だけが実行された
