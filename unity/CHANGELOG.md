# Changelog

All notable changes to this package are documented in this file.

## [0.9.1] - 2026-10-25

### Changed

- Unity 側のコードに変更は無い。プラグイン側の修正に合わせて版番号を揃えた（引数が 2 つ以上ある `[TestCase]` のテストを、
  他のテストと一緒にバッチ実行で指定できなかった問題への対応。プラグインはケースの FullName ではなくメソッドの FullName を渡す）。

## [0.9.0] - 2026-10-24

### Changed

- **`com.unity.pipeline` 0.9.0-exp.1 以降が必須になった**（0.8.0-exp.1 以前は非対応。0.8 を使うプロジェクトは `#v0.8.0` に固定する）。
  0.9 でコマンドが「グループ + 名前」に再編され、2 引数の `[CliCommand(name, description)]` が 0.9.0 で非推奨
  （Obsolete 警告）になったため、0.9.0 / 0.9.1 の両方で警告の出ない 3 引数形式に書き換えた。
- **コマンドを `wr.testrunner` グループへ移した**。呼び出し名が変わる（引数名と応答 JSON の形は変わらない）:
  `run_tests_batch_editmode` → `wr.testrunner run_tests_batch_editmode`、`run_tests_batch_playmode` →
  `wr.testrunner run_tests_batch_playmode`、`batch_test_status` → `wr.testrunner batch_test_status`、
  `batch_cancel_tests` → `wr.testrunner batch_cancel_tests`。グループ名に `wr` を付けるのは、0.9 ではコマンド名が
  重複すると後から登録された側が拒否され、本体のコマンドが残るため。
- **Unity 6000.3 が必須になった**（`package.json` の `unity` を 6000.0 から 6000.3 へ）。対象とする Unity を LTS の版に限り、
  検証している 6000.3 だけを対応と表示するため。6000.0〜6000.2 のプロジェクトには導入できなくなる。
- `TestRunnerCli.asmdef` の `versionDefines` に `com.unity.pipeline` 0.9.0-exp.1 以上の条件を付けた。0.9 未満の Pipeline が
  入っているプロジェクトでは本パッケージのコードがコンパイル対象から外れ、プロジェクトのコンパイルを壊さない。

## [0.8.0] - 2026-10-24

### Changed

- **版番号の付け方を変えた（コードの変更はない）**。0.4.0 と同じ内容のまま、版を 0.8.0 に上げた。
  以後、版の前 2 桁（major.minor）は対応する `com.unity.pipeline` の版を、末尾（patch）は本リポジトリ側の
  修正番号を表す。Claude Code プラグイン `wr-unity-cli-tools` も同じ版番号で揃え、リリースごとに共通の
  git タグ `vX.Y.Z` を打つ。本版は `com.unity.pipeline` 0.8.x 向けで、git URL の末尾に `#v0.8.0` を付けると
  この版に固定できる。

## [0.4.0] - 2026-10-04

### Changed

- **`com.unity.pipeline` 0.8.0-exp.1 以降が必須になった**（0.7.0-exp.1 以前は非対応・未検証）。
  0.8 で `CliCommandAttribute`/`CliArgAttribute` が `Unity.Pipeline` アセンブリから
  `Unity.Pipeline.Attributes` アセンブリへ移った（名前空間 `Unity.Pipeline.Commands` は変わらない）ため、
  `TestRunnerCli.asmdef` の `references` に `Unity.Pipeline.Attributes` を追加した。
- **`batch_test_status` の `data.result` がネイティブなJSONオブジェクトになった**（従来はJSON文字列として
  二重エンコードされていた）。0.8 で本体の `recompile_status`/`test_status` などが同じ形に揃えられたのに
  合わせた。ステータスファイルが空・パース不能・書き込み途中の場合は例外にせず
  `{"status":"malformed","raw":"<読んだ文字列>"}` を返す。中身のキー（`status`/`duration`/`summary`/`results`）は変わらない。

## [0.3.0] - 2026-09-21

### Changed

- **`com.unity.pipeline` 0.7.0-exp.1 以降が必須になった**（0.6.0-exp.1 以前は非対応）。
  0.7 で `get_console_logs` が削除され、Claude Code プラグイン側のコンパイルエラー判定が
  `recompile_status` の `failed`/`compilationFailed` を一次情報とする形に変わったため。**本パッケージの C# コードに変更はない** — 0.6 と 0.7 のソースを直接比較し、
  `CliCommandAttribute`/`CliArgAttribute` が `Unity.Pipeline` アセンブリにバイト単位で同一のまま
  残っていること、`CommandExecutionResponse`/`BaseResponse` が public のままであること、
  `TestCommands.cs`/`TestResultCollector.cs`/`PipelineTestRunner.cs` に差分が無いことを確認済み。
  `TestRunnerCli.asmdef` の `references` も変更不要。前提版が変わったことのみを記録するための
  バージョン更新である。

## [0.2.0] - 2026-09-06

### Changed

- **`com.unity.pipeline` 0.6.0-exp.1 以降が必須になった**（0.5.0-exp.1 以前は非対応）。
  0.6 で `Unity.Pipeline.Editor.Testing.TestResultCollector` / `Unity.Pipeline.TestExecutionResponse` /
  `TestSummary` / `TestResult` が `internal` 化されたため、同等の型を本パッケージ側に持つように変更した。
  基底の `Unity.Pipeline.Models.CommandExecutionResponse` は 0.6 でも public のままなので、
  公式ドキュメントが正規の作法として挙げる「`CommandExecutionResponse` を継承した独自モデルを返す」形に沿う。
  コマンド名・引数・レスポンスJSONの形は 0.1.0 から変わっていない。

## [0.1.0] - 2026-08-15

### Added

- 初回リリース。
- `run_tests_batch_editmode` / `run_tests_batch_playmode` / `batch_test_status` / `batch_cancel_tests` の4つのPipelineカスタムコマンド。
