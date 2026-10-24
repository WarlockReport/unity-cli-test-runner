# Unity CLI Test Runner (Unity Package)

`com.unity.pipeline` パッケージ向けに、EditMode/PlayModeテストを複数クラスにまたがって一括実行するためのカスタムコマンドを追加するEditor専用パッケージです。

## 前提条件

- Unity 6000.3（LTS）以降（`package.json` の `unity` で 6000.3 を要求する。6000.0〜6000.2 のプロジェクトには導入できない）
- `com.unity.pipeline` パッケージ（**0.9.0-exp.1 以降**）が対象プロジェクトに導入済みであること
  - 0.8.0-exp.1 以前には対応していない。0.9 でコマンドが「グループ + 名前」に再編され、本パッケージのコマンドも
    `wr.testrunner` グループに登録する 3 引数の `CliCommand` を使うようになったため。0.8 を使うプロジェクトでは
    `#v0.8.0` に固定する。0.9 未満の Pipeline が入っているプロジェクトでは、本パッケージのコードはコンパイル対象から
    外れる（プロジェクトのコンパイルは壊さない。`TestRunnerCli.asmdef` の `versionDefines` による）
  - 0.7.0-exp.1 以前には対応していない（未検証）。0.8 で `CliCommandAttribute` / `CliArgAttribute` が
    `Unity.Pipeline.Attributes` アセンブリへ移り、本パッケージの asmdef がそれを参照する形になったため。
    `batch_test_status` の結果も 0.8 本体の `*_status` に合わせてネイティブなJSONで返す
  - 0.6.0-exp.1 以前にも対応していない。0.7 で `get_console_logs` が削除され、プラグイン側の
    コンパイルエラー判定が `recompile_status` 前提に変わったため
  - 0.5.0-exp.1 以前にも対応していない。0.6 で `TestResultCollector` / `TestExecutionResponse` /
    `TestSummary` / `TestResult` が `internal` 化され、本パッケージが同等の型を自前で持つように
    なったため
  - 本パッケージの `dependencies` には含めていない。experimental なパッケージであり、
    どの版を入れるかは対象プロジェクト側で明示的に選ぶべきものだから。未導入の環境では、
    このパッケージのコードは自動的にコンパイル対象から除外される
    — `TestRunnerCli.asmdef` の `versionDefines`（`com.unity.pipeline` 0.9.0-exp.1 以上で有効）による

## インストール

Unity Editor の Package Manager → `+` → `Add package from git URL...` に以下を入力します。

```
https://github.com/WarlockReport/unity-cli-test-runner.git?path=/unity
```

特定の版に固定するには、末尾に `#<タグ>` を付けます（例: `...?path=/unity#v0.9.0`）。版の前 2 桁は対応する
`com.unity.pipeline` の版を表します。Claude Code プラグインも同じタグに揃えてください。対応表と手順はリポジトリ直下の
`README.md` を参照してください。

## 追加されるコマンド

すべて `wr.testrunner` グループに登録されます（`unity cmd wr.testrunner <コマンド> ...` で呼ぶ。
`unity cmd wr.testrunner` でグループのコマンド一覧を表示できます）。

| コマンド | 用途 |
| --- | --- |
| `wr.testrunner run_tests_batch_editmode` | 複数クラスにまたがる完全名(FullName)の集合をEditModeで一括実行する |
| `wr.testrunner run_tests_batch_playmode` | 同上をPlayModeで非同期実行する |
| `wr.testrunner batch_test_status` | `wr.testrunner run_tests_batch_playmode` の実行状況をポーリングする |
| `wr.testrunner batch_cancel_tests` | 実行中のPlayModeバッチテストをキャンセルする |

対応するClaude Codeスキル（`claude-plugin/skills/unity-cli-test-runner`）と組み合わせて使うことを想定しています。
単体で `unity cmd` から直接呼び出すこともできます。
