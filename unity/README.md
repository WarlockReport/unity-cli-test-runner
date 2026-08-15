# Unity CLI Test Runner (Unity Package)

`com.unity.pipeline` パッケージ（`unity cmd` CLI経由でUnityエディタを操作するPipelineサーバー）向けに、
EditMode/PlayModeテストを複数クラスにまたがって一括実行するためのカスタムコマンドを追加するEditor専用パッケージ。

## 前提条件

- Unity 6000.0 以降
- `com.unity.pipeline` パッケージが対象プロジェクトに導入済みであること（本パッケージの `dependencies` には含めていない。限定配布のパッケージであり公開UPMレジストリで解決できない可能性があるため。未導入の環境では、このパッケージのコードは自動的にコンパイル対象から除外される — `TestRunnerCli.asmdef` の `versionDefines` による）

## インストール

Unity Editor の Package Manager → `+` → `Add package from git URL...` に以下を入力する。

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

対応するClaude Codeスキル（`skills/unity-cli-test-runner`）と組み合わせて使うことを想定している。単体でも `unity cmd` から直接呼び出せる。
