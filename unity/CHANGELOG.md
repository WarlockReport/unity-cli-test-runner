# Changelog

All notable changes to this package are documented in this file.

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
  `TestSummary` / `TestResult` が `internal` 化されたため、同等の型を本パッケージ側に持つように変更した
  （ADR-0012）。基底の `Unity.Pipeline.Models.CommandExecutionResponse` は 0.6 でも public のままなので、
  公式ドキュメントが正規の作法として挙げる「`CommandExecutionResponse` を継承した独自モデルを返す」形に沿う。
  コマンド名・引数・レスポンスJSONの形は 0.1.0 から変わっていない。

## [0.1.0] - 2026-08-15

### Added

- 初回リリース。
- `run_tests_batch_editmode` / `run_tests_batch_playmode` / `batch_test_status` / `batch_cancel_tests` の4つのPipelineカスタムコマンド。
