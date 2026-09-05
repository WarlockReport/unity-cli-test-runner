# Changelog

All notable changes to this package are documented in this file.

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
