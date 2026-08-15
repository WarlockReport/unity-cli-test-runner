# ADR-0002: PlayModeのInvalidOperationException累積

## Status

Resolved (2026-08-13)

## Context

前提: [ADR-0001](0001-migrate-from-unity-mcp-to-cli.md) によりCLI経由に移行済み。

### 現象（2026-08-10観測）

PlayModeの `run_tests` を `--async_tests` なしで実行する、または `test_status` の完了確認前に次の `run_tests`/`cancel_tests` を発行すると、
Unityコンソールに `InvalidOperationException`（`Unity.Pipeline.Editor.Testing.TestResultCollector.RunFinished`） が発生し、
以降の `test_status` が古い結果を返すことがある。

待機規律を徹底しても、この例外自体は解消しないことを実地検証済み（2026-08-11: `scripts/run-playmode-test.sh` 経由で完了確認を徹底した状態でも、
同一Unityエディタセッション内でPlayModeの `run_tests` 呼び出しを重ねるたびに 例外が1件ずつ累積して増える現象を確認。`clear_console` を挟んでもこの累積は リセットされない）。

### 原因の詳細（2026-08-11精緻化）

`get_console_logs`（severityフィルタ無し）で `[TestResultCollector] Run started`/`Run finished` のログ回数を確認したところ、
実行回数に比例して増加し、かつ複数回分の `Run finished` ログが全て同一内容（同じ total/passed/failed）だった。
これは実際に テストが複数回実行されているのではなく、`run_tests` を呼ぶたびに新しい `TestResultCollector` が `TestRunnerApi` にコールバック登録される一方、
前回登録分の解除が行われていないことを示す。
1回の実際のテスト完了イベントが、その時点で登録されている全ての（リークした）リスナーに配信され、
各リスナーが自分のログを吐きつつ自分の `TaskCompletionSource` に `SetResult` しようとするが、
最新の1つ以外はすでに完了済みのため `InvalidOperationException` になる、という構造。
実際のテスト重複実行ではなく通知の重複配信であるため、副作用のあるテストが裏で何度も走ることへの心配は不要。
ドメインリロード／エディタ再起動でリセットされると考えられるが**未検証**。

原因は `com.unity.pipeline` パッケージ内部の実装と見られ、プロジェクト側コードでは修正できない。

### stale結果の再現性検証（2026-08-11）

同一セッション内で7回連続（同一filter4回・異なるfilterへの切り替えを挟んで3回）実行した限りでは、
`test_status` が返す結果（FullName・Duration）は毎回実際の実行に 対応する新しい値であり、staleな結果が返る現象自体は再現しなかった。

ただし `scripts/run-playmode-test.sh` のfilter文字列チェック（返却JSONに `<filter>` 文字列が含まれるかの簡易チェック）単体では異なるfilterへの取り違えしか検出できない。
同一filterを連続実行した際に古い実行結果が使い回されるケースは、
同スクリプトが `run_tests` 発行前に取得する `test_status` のベースラインとの完全一致比較 （exit 3、filter文字列チェックとは別のメッセージで区別可能）でカバーしている（2026-08-11実装。正常系で誤検知しないこと・同一完了結果の再読み込みが文字列一致することは実機確認済みだが、**真のstale状態そのものの再現確認は未実施**）。

### 当時の結論（2026-08-11時点。後述の修正によりSKILL.mdからは削除済み）

- 例外そのものの解消は不可能だが、待機規律・ポーリング・ベースライン比較によるstale結果の検知には、
  この例外が解消するかどうかとは独立した価値がある。そのため `scripts/run-playmode-test.sh` 経由での実行を引き続き必須とする
- 長時間・多数回のPlayMode実行を1つのUnityエディタセッションで繰り返す場合は、
  `get_console_logs --severity error` で例外の累積状況を随時確認し、累積が多い状態では結果を鵜呑みにせずユーザーに報告する

この結論は下記「解決（2026-08-13）」により覆り、SKILL.mdの該当ステップは削除された。

## Decision

`com.unity.pipeline` 0.5.0-exp.1 で本問題が修正された。CHANGELOG記載:

> Fix InvalidOperationExceptions logged after running run_tests more than once: a stale
> TestResultCollector left registered with Unity's TestRunnerApi kept receiving later runs'
> completion notifications and re-completed its own already-completed result.

（出典: https://docs.unity3d.com/Packages/com.unity.pipeline@0.5/changelog/CHANGELOG.html）

検証に使用した環境では `Packages/manifest.json` で `com.unity.pipeline: 0.5.0-exp.1` を採用済みであり、スキルの実地検証でも例外が再現しないことを確認した。

## Consequences

SKILL.mdの「既知の罠」・ステップ5にあった例外累積確認のアクションは削除した（経緯として本ADRに残す）。
ただし「当時の結論」節に記載したstale結果検知の仕組み（ベースライン比較、exit 3）自体は本問題の解消とは独立した価値を持つため、
`scripts/run-playmode-test.sh` の実装として維持されている。