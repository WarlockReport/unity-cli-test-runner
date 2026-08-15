# unity-cli-test-runner 開発メモ

このファイルはエージェント実行時には読み込まれない、人間向けの調査経緯・保守メモ。
SKILL.md は実行時に必要な結論のみを記載しており、調査プロセスの詳細はここに集約する。

## Unity MCPからの移行について
当初は `unity-mcp-test-runner`（Unity MCP経由）を利用していたが、
MCP固有の制約（ドメインリロード前提・結果ファイルの置き場所問題・`Filter.groupNames`不動作等）や、
ライセンス費用の問題（MCP利用のみでもサブスクリプションが必要）などの理由から、CLI経由へと移行した。

## PlayModeテストの `InvalidOperationException` 累積について

### 現象（2026-08-10観測）

PlayModeの `run_tests` を `--async_tests` なしで実行する、または `test_status` の完了確認前に
次の `run_tests`/`cancel_tests` を発行すると、Unityコンソールに `InvalidOperationException`
（`Unity.Pipeline.Editor.Testing.TestResultCollector.RunFinished`）が発生し、以降の
`test_status` が古い結果を返すことがある。待機規律を徹底しても、この例外自体は解消しないことを
実地検証済み（2026-08-11: `scripts/run-playmode-test.sh` 経由で完了確認を徹底した状態でも、
同一Unityエディタセッション内でPlayModeの `run_tests` 呼び出しを重ねるたびに例外が1件ずつ
累積して増える現象を確認。`clear_console` を挟んでもこの累積はリセットされない）。

### 原因の詳細（2026-08-11精緻化）

`get_console_logs`（severityフィルタ無し）で `[TestResultCollector] Run started`/
`Run finished` のログ回数を確認したところ、実行回数に比例して増加し、かつ複数回分の
`Run finished` ログが全て同一内容（同じ `total/passed/failed`）だった。これは実際にテストが
複数回実行されているのではなく、`run_tests` を呼ぶたびに新しい `TestResultCollector` が
`TestRunnerApi` にコールバック登録される一方、前回登録分の解除が行われていないことを示す。
1回の実際のテスト完了イベントが、その時点で登録されている全ての（リークした）リスナーに配信され、
各リスナーが自分のログを吐きつつ自分の `TaskCompletionSource` に `SetResult` しようとするが、
最新の1つ以外はすでに完了済みのため `InvalidOperationException` になる、という構造。実際の
テスト重複実行ではなく通知の重複配信であるため、副作用のあるテストが裏で何度も走ることへの
心配は不要。ドメインリロード／エディタ再起動でリセットされると考えられるが未検証。

原因は com.unity.pipeline パッケージ内部の実装と見られ、プロジェクト側コードでは修正できない。

### stale結果の再現性検証（2026-08-11）

同一セッション内で7回連続（同一filter4回・異なるfilterへの切り替えを挟んで3回）実行した限りでは、
`test_status` が返す結果（`FullName`・`Duration`）は毎回実際の実行に対応する新しい値であり、
staleな結果が返る現象自体は再現しなかった。ただし `scripts/run-playmode-test.sh` のfilter文字列
チェック（返却JSONに `<filter>` 文字列が含まれるかの簡易チェック）単体では異なるfilterへの
取り違えしか検出できない。同一filterを連続実行した際に古い実行結果が使い回されるケースは、
同スクリプトが `run_tests` 発行前に取得する `test_status` のベースラインとの完全一致比較
（exit 3、filter文字列チェックとは別のメッセージで区別可能）でカバーしている
（2026-08-11実装。正常系で誤検知しないこと・同一完了結果の再読み込みが文字列一致することは
実機確認済みだが、真のstale状態そのものの再現確認は未実施）。

### 当時の結論（2026-08-11時点、後述の修正によりSKILL.mdからは削除済み）

- 例外そのものの解消は不可能だが、待機規律・ポーリング・ベースライン比較によるstale結果の
  検知には、この例外が解消するかどうかとは独立した価値がある。そのため
  `scripts/run-playmode-test.sh` 経由での実行を引き続き必須とする
- 長時間・多数回のPlayMode実行を1つのUnityエディタセッションで繰り返す場合は、
  `get_console_logs --severity error` で例外の累積状況を随時確認し、累積が多い状態では
  結果を鵜呑みにせずユーザーに報告する

### 解決（2026-08-13）

`com.unity.pipeline` 0.5.0-exp.1 で修正された。CHANGELOG記載:

> Fix `InvalidOperationException`s logged after running `run_tests` more than once: a stale
> `TestResultCollector` left registered with Unity's TestRunnerApi kept receiving later runs'
> completion notifications and re-completed its own already-completed result.

（出典: https://docs.unity3d.com/Packages/com.unity.pipeline@0.5/changelog/CHANGELOG.html）

検証に使用した環境では `Packages/manifest.json` で `com.unity.pipeline: 0.5.0-exp.1` を採用済みであり、
スキルの実地検証でも例外が再現しないことを確認した。これに伴い、SKILL.md の「既知の罠」・
ステップ5にあった例外累積確認のアクションは削除した（経緯としてこの節に残す）。

## `ensure-compile-clean.sh` のJSONフィールド名について

`recompile_status`/`get_console_logs` の正確なJSONフィールド名は、スクリプト設計時点では
実地未検証だった（スクリプト自身の分岐ロジック・フォールバックはモックによるテストで確認済み）。
複数の候補フィールド名を試すフォールバックを入れているため通常は動作するはずだが、別マシンでの
初回実行時に実際のフィールド名・応答時間を確認し、想定と異なれば `scripts/ensure-compile-clean.sh`
内のjqフィルタ・タイムアウト目安値を確定値に更新すること。

## 「No Unity Editor instances found with reachable Pipeline servers」の一時的な接続断について

実装エージェントで複数回発生しました。
いずれも .cs ファイル編集直後（コンパイル/ドメインリロード中と思われるタイミング）に unity-test-runner を呼んで起きており、コントローラー側で少し待ってから unity cmd editor_status を叩くと ready に戻っていて、再試行で解決しました。
SKILL.mdの「コンパイル状態の確定」（ensure-compile-clean.sh でコンパイル確定してからテスト対象解決へ進む手順）が徹底されていれば避けられた可能性があります。
実装エージェント側がこの手順をどこまで踏んでいたかは不明。

## list_tests が一時的に0件ヒットについて

ドメインリロード未完了のタイミングでlist_testsを呼んで0件になり、再試行で解決したとのことでした。
これも「No Unity Editor instances found with reachable Pipeline servers」の一時的な接続断についてと同梱で、コンパイル確定ステップの徹底不足の可能性があります。

## サブエージェントのネスト呼び出しで完了通知が親に届かない問題について

実装エージェントが自分で unity-test-runner サブエージェントを呼び出した後、その完了通知が呼び出し元の実装エージェントではなくコントローラーに直接届く現象が2回あった。
実装エージェントは「結果を待っています」という状態で自分のターンを終えてしまい実質ハングし、
コントローラーが editor_status で状況確認したうえで実装エージェントを再開させる必要がありました。
これはUnity側ではなく、ハーネスのエージェント委任（サブエージェントがさらにサブエージェントを呼ぶ）まわりのイベントルーティングの問題に見えます。
SKILL.mdには記載がなく、対処法として明文化する価値がありそうです。

### 解決（2026-08-15）

原因を精緻化した結果、ハーネス側のイベントルーティング自体を回避する手段はなく、対処は
「実装サブエージェントに、自分でAgentツールを使い `unity-test-runner` を呼び出させない」という
運用面の徹底に限られると判断した。これは新しい制約ではなく、元々SKILL.md・エージェント定義・
メモリに存在していた「テスト実行の委任はコントローラー本体、または `unity-test-runner` サブ
エージェントのみ」という方針からの**逸脱**が原因だった。事故が起きたplanの指示文
（「テストの実行は必ずunity-test-runnerサブエージェントへ委譲する」）が委譲の主体を明示していな
かったため、実装エージェントが自分で呼び出す以外の解釈ができなかったことが根本原因。

以下の3箇所に、委譲の主体を明示する形で修正を反映した:

- 利用側プロジェクトの開発フロー規約（spec/plan作成時に必ず読まれるrulesファイル）へ、
  「サブエージェント委任時のテスト実行方針」として恒久方針を明記。実装サブエージェントはテストを
  実行せず、コントローラーへ差し戻す。再開はSendMessageで既存の実装サブエージェントのコンテキスト
  を保持したまま行う
- `SKILL.md`（このリポジトリでは `skills/unity-cli-test-runner/SKILL.md`）の「禁止事項」 —
  実装サブエージェントがタスク遂行中にこの状況に迷い込んだ場合の行動（自分で呼び出さず報告して
  ターンを終える）を明記
- `agents/unity-test-runner.md` — 「コントローラー本体からの明示的なディスパッチでのみ
  使用する」制約の理由（ネストした委任は完了通知の宛先を誤らせる）を追記

Aとして検討した「実装エージェントが直接スキルを利用する」案は採用しなかった。2026-08-02に
「実装系サブエージェントへの無条件許可は不可、専用の軽量エージェント経由に限定する」と確定させた
既存方針を覆すことになり、ハング・タイムアウト時の「盲目的にリトライしない」規律をタスク遂行中の
実装エージェントが守りきれないという当時の懸念を再び引き受けることになるため。

## 複数テスト一括実行・起動チェックスクリプト化について（2026-08-13）

以下3点の残課題を解消した:

1. 複数のテストを連続で実行する場合、対象ごとにコンパイル確認からやり直す非効率があった →
   スキルのワークフローを「1回の呼び出し＝対象リスト」前提へ再構成し、コンパイル確認・起動確認を
   呼び出し内で1回化した
2. Unity CLIの`run_tests`は複数クラスにまたがる完全名の一括実行に対応できない（`--filter_type
   testName`へのカンマ区切りは部分一致ロジックの都合で静かに0件空振りする）→ Unity側に
   `run_tests_batch_editmode`/`run_tests_batch_playmode`というPipelineカスタムコマンドを新設した。
   実例として、同一プロジェクト内の既存Pipelineカスタムコマンド実装を雛形にした
3. `unity status`によるエディタ起動チェックが自然文の手順のみだった → `check-editor-ready.sh`として
   スクリプト化した

本設計のバッチ化により、複数テスト対象1件ごとにサブエージェントを呼び直す頻度は下がる。
「サブエージェントのネスト呼び出しで完了通知が親に届かない問題」自体への対応は、上記の別節
（2026-08-15解決）を参照。
