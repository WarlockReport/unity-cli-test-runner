# ADR-0026: 引数付きケースはメソッドの FullName でバッチ実行し、ケースの FullName は実行前に拒否する

## Status

Accepted (2026-10-25)

## Context

引数が 2 つある `[TestCase]` のテストを、コード変更の影響範囲にある他のテストと一緒に流そうとして、
指定できないという報告があった。そのテストを含めて流すにはアセンブリ全体を実行するしかなく、実行時間が延びていた。

- NUnit はケースの FullName に引数をカンマ区切りで入れる（例: `Ns.Class.Method(First,2)`）。`test list` もこの名前を返す
- バッチ実行（`run-tests-batch-editmode.sh` / `run-tests-batch-playmode.sh` → `wr.testrunner run_tests_batch_*`）は
  FullName の一覧をカンマ区切りの 1 引数で受け取り、Unity 側の `TestRunnerCliUtility.ParseFullNames` が `Split(',')` で分ける。
  PlayMode のスクリプトも整合性チェックで `IFS=','` で分ける。そのため名前の途中で割れ、`Ns.Class.Method(First` と `2)` という、
  どのテストにも一致しない断片になる
- **実測（TestProject、Unity 6000.3.25f1 + `com.unity.pipeline` 0.9.1-exp.1、2026-10-25）**:
  - EditMode でケースの FullName と通常のテストを渡すと、**exit 0・`Summary.Total: 1` で、ケースだけが静かに実行されない**
  - PlayMode では同じ指定で、整合性チェックが断片の手がかりを見つけられず exit 3 になる
  - 引数部分を外したメソッドの FullName（`Ns.Class.Method`）を渡すと、EditMode・PlayMode とも、そのメソッドの全ケースが
    実行される（`Filter.testNames` はメソッドのノードに完全一致し、その子のケースが流れる）。PlayMode の整合性チェックも通る

影響範囲を流す用途では、特定のケースだけに絞る必要は無く、メソッドの全ケースを流せれば十分である（報告者に確認済み）。

## Decision

- スキル（SKILL.md ステップ2）で、`test list` から絞り込んだ一覧に引数付きのケースがあれば、末尾の `(引数)` を外した
  メソッドの FullName に置き換え、重複を除いてからバッチスクリプトに渡す
- バッチスクリプトは、括弧を含む名前を受け取ったら `unity cmd` を呼ばずに exit 1 で止め、メソッドの FullName で渡し直すよう
  案内する（`_lib.sh` の `exit_on_parameterized_case_names`）。LLM がスキルの指示を守らずにケースの FullName を渡しても、
  ケースが静かに抜け落ちる事態を防ぐ
- Unity 側のコマンドと、カンマ区切りという引数の形式は変えない

### 検討して採らなかった案

- **括弧・引用符の中のカンマでは区切らない解析に変える**: 個々のケースを指定できるようになる。しかし C# とシェルの両方の解析を
  変える必要がある。また、文字列引数に括弧や引用符が含まれる名前まで正しく扱うには、NUnit の表示名の書式に依存する解析が要る。
  ケース単位の指定は必要とされていないため見送った
- **区切り文字を変える・JSON 配列で渡す**: プラグインと UPM パッケージの契約が変わる。両者は別々に更新されるため、
  版の組み合わせによっては壊れる
- **スクリプト側で `(…)` を自動的に外す**: 文字列引数に `)` が含まれると誤変換する。止めて指示どおりに渡し直させるほうが確実

## Consequences

- 影響範囲のテストに引数付きのメソッドが含まれていても、アセンブリ全体に切り替えずにバッチ実行できる
- 特定のケースだけを流すことはできない（メソッドの全ケースが流れる）
- クラス側に引数がある `[TestFixture(...)]`（`Ns.Class(1).Method`）は、括弧を含むためバッチスクリプトで拒否される。
  これを指定できるようにする対応は今回の対象外
- 固定台に引数付きの `ParameterizedFixture`（EditMode 4 ケース・PlayMode 2 ケース）を追加し、`e2e/run-all.sh` に、
  メソッドの FullName によるバッチ実行と、ケースの FullName の拒否（exit 1）の段階を加えた
