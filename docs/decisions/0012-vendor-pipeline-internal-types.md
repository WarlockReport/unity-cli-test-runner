# ADR-0012: `com.unity.pipeline` 0.6での`internal`化に伴う型のベンダリング

## Status

Accepted (2026-09-06)

## Context

`com.unity.pipeline` 0.6.0-exp.1 がリリースされた。本プラグインのUnity側パッケージは 0.5.0-exp.1 を前提としており、追随の可否と規模を判断する必要があった。

CHANGELOGには「`Editor/Commands/` 配下のコマンドハンドラ」「フレームワーク型」「`Tests/` 配下のヘルパー」を `internal` 化したという記述があったが、本プラグインが依存する具体的な型がその対象に含まれるかは記述からは判断できなかった。
そこで公開UPMレジストリ（`https://packages.unity.com/com.unity.pipeline`）から 0.5.0-exp.1 と 0.6.0-exp.1 の tarball を両方取得し、ソースを直接 diff して確認した。

結果、本プラグインが使用している以下4型が `public` から（修飾子なしの）`internal` へ変わっていた。

| 型 | 場所 | 本プラグインでの使用箇所 |
| --- | --- | --- |
| `Unity.Pipeline.TestExecutionResponse` | `Runtime/Models/` | 全カスタムコマンドの戻り値型 |
| `Unity.Pipeline.TestSummary` | `Runtime/Models/` | `TestRunnerCliUtility.BuildSuccessResponse` |
| `Unity.Pipeline.TestResult` | `Runtime/Models/` | `TestResultCollector.Results` の要素型 |
| `Unity.Pipeline.Editor.Testing.TestResultCollector` | `Editor/Testing/` | EditMode・PlayMode 両方の実行経路 |

```
0.5: public class TestResultCollector : ICallbacks
0.6:        class TestResultCollector : ICallbacks
```

`Runtime/AssemblyInfo.cs` の `InternalsVisibleTo` は `Unity.Pipeline.Tests.Runtime` / `Unity.Pipeline.Tests.Editor` / `Unity.Pipeline.Editor` の3つだけで、サードパーティのアセンブリには開かれていない。
したがって 0.6 に対して本プラグインは**コンパイルできない**。回避策は無く、同等の型を自前で持つ以外に選択肢が無い。

一方で、以下は 0.6 でも変わっていないことを同じ diff で確認した。これが「設計変更ではなく機械的な差し替えで済む」という判断の根拠である。

- `Unity.Pipeline.Models.CommandExecutionResponse` と `BaseResponse` は **`public` のまま**。本プラグインが設定する `Success` / `Command` / `Result` / `Error` / `Message` / `ExecutedAt` はすべて健在
- `CliCommandAttribute` / `CliArgAttribute` は **バイト単位で同一**
- アセンブリ名 `Unity.Pipeline` / `Unity.Pipeline.Editor` は不変（`TestRunnerCli.asmdef` の `references` は変更不要）
- サーバーはハンドラの戻り値を常に `CmdSuccess(command, result)` で `result` へ**ネスト**する（0.5: `BasePipelineServer.cs` L1507 / 0.6: L2040）。
  0.6 でレスポンスが既定で lean 化された（`command` / `executedAt` / `executionTimeMs` を剥がし、null の `message` / `error` / `errorDetails` を落とす）が、
  スクリプトが読む `.data.result.success` / `.data.result.error` はいずれも lean で落ちる対象ではないため、シェルスクリプト側のjqパスは変更不要

そして公式ドキュメント `Documentation~/creating-commands.md` は、コマンドの戻り値について「`CommandExecutionResponse` を継承した独自モデルを返す」ことを正規の作法として明記している。
つまり移行先はパッケージ側が想定している使い方そのものである。

## Decision

`internal` 化された4型と同等のものを、本パッケージの `TestRunnerCli` 名前空間に持つ（ベンダリングする）。

- `TestResult` / `TestSummary` / `TestExecutionResponse` — DTO。フィールド名はパッケージ本体と一致させ、レスポンスJSONの形を 0.1.0 から変えない。
  `TestExecutionResponse` は引き続き（0.6でもpublicな）`Unity.Pipeline.Models.CommandExecutionResponse` を継承する
- `TestResultCollector` — パッケージ本体 0.6 版の実装を移植する

**両バージョン対応はしない。** 0.6.0-exp.1 以降を必須とする。
（技術的には、ベンダリングした型を `TestRunnerCli` 名前空間直下に置き `Unity.Pipeline` を `using` しなければ、0.5 でも名前解決は自前の型が優先され両対応は可能だった。
しかし 0.5 と 0.6 では後述の busy 応答をはじめ挙動が異なり、両方を検証し続けるコストに見合わないと判断した。）

移植にあたっての本体からの差分は2点で、いずれも本パッケージでの用途に合わせた削減である。

1. `TestExecutionResponse` から `StatusPath` を落とした。本パッケージはPlayModeの状況取得に独自のステータスファイル（`Temp/testrunner_cli_batch_status.json`、`batch_test_status` コマンド）を使っており、未使用のため
2. `TestResultCollector` から同期モード（`WaitForCompletionAsync` / `SetError` / `TaskCompletionSource`）を落とした。
   本パッケージのEditModeコマンドは自前の `TaskCompletionSource` と `OnRunFinished` で待ち合わせており、PlayModeはステータスファイル経由なので、いずれも使っていない。
   これに伴い、二重完了ガードの根拠を `TaskCompletionSource` の完了状態からリセットされない `bool` フラグへ置き換えた（下記）

### 二重完了ガードを `bool` に置き換えた理由

本体0.6版は、古いコレクタが後続の実行の `RunFinished` を受け取ってしまう問題（AUTHAPI-36 および 0.5 の UUM-149016）を `m_CompletionSource.Task.IsCompleted` で弾いている。
`IsComplete` プロパティでは弾けない。`RunStarted` がキャンセルされていないコレクタすべてで `IsComplete` を `false` に戻してしまうため、古いコレクタもリセットされてしまうからである（本体のコメントにも同旨の記述がある）。

同期モードを落とすと `TaskCompletionSource` 自体が不要になるので、代わりに `RunStarted` でリセットされない `m_HasCompleted` フラグを持たせ、同じ役割を担わせた。
ガードの意味論は本体と等価で、根拠がフラグの名前として明示される分わかりやすい。

なお、ログのprefixは本体（`[TestResultCollector]`）と区別できるよう `[TestRunnerCli]` に変更した。

## Consequences

- 0.6.0-exp.1 以降でコンパイル・動作するようになる。0.5.0-exp.1 以前は非対応になる（README・`unity/README.md` に明記）
- コマンド名・引数・レスポンスJSONの形は 0.1.0 から変わらない。スキル側のシェルスクリプトのjqパスも変更不要
- パッケージ本体の `TestResultCollector` に将来修正が入っても自動では追随しない。
  PlayModeのドメインリロード跨ぎの結果収集という繊細な処理を含むため、本体の更新時は `Editor/Testing/TestResultCollector.cs` の差分を確認すること
- パッケージ本体が今後さらに `public` 面を削った場合、同じ手当てが必要になりうる。
  現時点で本プラグインが本体のpublic APIに依存しているのは `CommandExecutionResponse` / `BaseResponse` / `CliCommandAttribute` / `CliArgAttribute` の4つだけであり、
  依存面はベンダリング前より小さくなっている

## 関連

- [ADR-0002](0002-playmode-invalidoperationexception-accumulation.md) — 0.6 の AUTHAPI-36 について追記した
- [ADR-0004](0004-domain-reload-transient-failures.md) / [ADR-0007](0007-domain-reload-transient-pipeline-unreachable.md) — 0.6 の busy 応答・`CommandRegistry` 修正について追記した
