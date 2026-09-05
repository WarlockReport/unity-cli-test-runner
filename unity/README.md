# Unity CLI Test Runner (Unity Package)

`com.unity.pipeline` パッケージ向けに、EditMode/PlayModeテストを複数クラスにまたがって一括実行するためのカスタムコマンドを追加するEditor専用パッケージです。

## 前提条件

- Unity 6000.0 以降
- `com.unity.pipeline` パッケージ（**0.6.0-exp.1 以降**）が対象プロジェクトに導入済みであること
  - 0.5.0-exp.1 以前には対応していない。0.6 で `TestResultCollector` / `TestExecutionResponse` /
    `TestSummary` / `TestResult` が `internal` 化され、本パッケージが同等の型を自前で持つように
    なったため（[ADR-0012](../docs/decisions/0012-vendor-pipeline-internal-types.md)）
  - 本パッケージの `dependencies` には含めていない。experimental なパッケージであり、
    どの版を入れるかは対象プロジェクト側で明示的に選ぶべきものだから。未導入の環境では、
    このパッケージのコードは自動的にコンパイル対象から除外される
    — `TestRunnerCli.asmdef` の `versionDefines` による

## インストール

Unity Editor の Package Manager → `+` → `Add package from git URL...` に以下を入力します。

```
https://github.com/WarlockReport/unity-cli-test-runner.git?path=/unity
```

## 追加されるコマンド

| コマンド | 用途 |
| --- | --- |
| `run_tests_batch_editmode` | 複数クラスにまたがる完全名(FullName)の集合をEditModeで一括実行する |
| `run_tests_batch_playmode` | 同上をPlayModeで非同期実行する |
| `batch_test_status` | `run_tests_batch_playmode` の実行状況をポーリングする |
| `batch_cancel_tests` | 実行中のPlayModeバッチテストをキャンセルする |

対応するClaude Codeスキル（`skills/unity-cli-test-runner`）と組み合わせて使うことを想定しています。
単体で `unity cmd` から直接呼び出すこともできます。
