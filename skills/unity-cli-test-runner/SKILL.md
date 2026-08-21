---
name: unity-cli-test-runner
description: Unity CLI（`~/.unity/bin/unity cmd`、Pipelineサーバー経由で起動中エディタに接続）が使える状態で、コード修正後にUnityのテスト（EditMode/PlayMode）を絞り込み実行して結果を確認する。ユーザーが「テストを実行して」「直ったか確認して」のように検証を依頼したとき、あるいはTDD系スキル（test-driven-development, verification-before-completion等）が検証ステップを必要とするときは、明示的に指示されていなくても必ずこのスキルを使うこと。コントローラー本体（メインセッション）、または専用の `unity-test-runner` サブエージェントのみが使用し、他の実装サブエージェントへの委任は行わない。
---

# Unity CLI テスト実行

`unity cmd`（Pipelineサーバー経由、`unity status`で見える起動中エディタに接続）を使い、
コード修正後のテスト実行を絞り込み付きで自動化する。

**このスキルはコントローラー本体（メインセッション）、または専用の `unity-test-runner` サブエージェントのみが使う。
他の実装サブエージェントへのディスパッチ文にテスト実行（このスキル経由を含む）を指示しない。**

## 前提

- 各コマンドには必ず明示的な `--timeout <秒>` を付ける
- エディタの起動確認はワークフローのステップ0（`scripts/check-editor-ready.sh`）で行う
- 本ドキュメント中の `scripts/...` はすべて、このスキル自身のディレクトリからの相対パスである。
  実行時はスキルのベースディレクトリを起点に絶対パスへ解決してから呼び出すこと（対象Unity
  プロジェクトのカレントディレクトリとは無関係）

## ワークフロー

進捗はチェックリストとしてコピーし、完了ごとにチェックすること。1回のスキル/エージェント呼び出しは
**テスト対象のリスト**を受け取り、ステップ0・1は呼び出し内で1回だけ行う。

```
- [ ] 0. エディタ起動確認
- [ ] 1. コンパイル状態の確定
- [ ] 2. 全テスト対象の解決
- [ ] 3. 対象を実行グループへ分類
- [ ] 4. PlayMode時の未保存シーン処理
- [ ] 5. 実行（グループごと）
- [ ] 6. 結果確認・報告（全グループ集約）
```

### 0. エディタ起動確認

対象リストの解決・実行に進む前に、必ず `scripts/check-editor-ready.sh` を実行する。

```bash
scripts/check-editor-ready.sh
```

内部では `unity cmd editor_status`（このスキルの他スクリプトが依拠するのと同じ自動検出機構）を使う。
引数なしで呼び出せば、`unity cmd` 自身の自動検出により、呼び出し時のカレントディレクトリに関わらず
接続中のエディタを解決できる。

| 終了コード | 意味 | 対応 |
| --- | --- | --- |
| 0 | 起動中エディタが見つかり status が ready | 次のステップ（コンパイル状態の確定）へ進む |
| 1 | 起動中エディタは見つかったが status が ready 以外 | 標準エラー出力のstatus値をそのまま報告し、「ハング・タイムアウト時の対応」に準じてユーザーに状況確認を依頼する |
| 2 | 起動中エディタが見つからない、リトライ予算（15秒）を使い切ってもなお `unity cmd editor_status` が失敗/タイムアウト | Unityエディタが起動していないか未接続。ユーザーに手動起動を依頼する（ドメインリロード中の一時的な切断はスクリプト内部で自動リトライ済みなので、ここに到達した場合は本当に未起動/未接続の可能性が高い） |
| 3 | 応答は得られたが想定した形式でパースできなかった | 標準出力の生JSONを確認して手動判断する |

### 1. コンパイル状態の確定

コード修正直後は、Unity側が変更を検知・反映しきっていない状態で `list_tests`/`run_tests` を呼ぶと、
テスト対象の解決を誤る（存在しないテストが残る、EditMode/PlayModeの判定が実態と異なる等）おそれがある。
テスト対象の解決に進む前に、必ず `scripts/ensure-compile-clean.sh` を実行してコンパイルを確定させる。

```bash
scripts/ensure-compile-clean.sh
```

このスクリプトは `clear_console → recompile → recompile_status ポーリング → editor_status によるドメイン
リロード完了の安定確認 → get_console_logs(error)` を順に実行し、以下の終了コードを返す（`unity` CLI と
`jq` がPATH上にあることが前提）。第1引数でポーリング予算秒数を上書きできる（既定60秒。この予算は
recompile_statusポーリングとeditor_statusによる安定確認の両方に個別適用されるため、全体の最大所要
時間は指定値の2倍になりうる）。

| 終了コード | 意味 | 対応 |
| --- | --- | --- |
| 0 | コンパイル確定・ドメインリロードも完了・エラー無し | 次のステップ（テスト対象の解決）へ進む |
| 1 | コンパイルエラーを検出（標準出力に詳細） | テスト対象の解決に進まず、エラー内容をそのまま報告して終了する |
| 2 | ポーリング予算超過（`unity cmd`呼び出し自体の失敗を含む） | 「ハング・タイムアウト時の対応」に従う（盲目的に再試行しない） |
| 3 | `get_console_logs` の返り値の形式が想定と異なり判定不能 | 標準出力の生JSONを確認して手動判断する |

**注意（実測済み、既知の罠も参照）**: コンパイル完了直後の1〜2秒間、ドメインリロード（アセンブリの
再読み込み）によりUnity側のPipelineサーバーが一時的にダウンし、`unity cmd` が
`No Unity Editor instances found with reachable Pipeline servers.` で失敗することがある。この
スクリプトは内部でこれを一時的な切断として扱い、`recompile_status` が完了状態を報告した後も
`editor_status` の `compiling`/`domainReloadInProgress` が2回連続でfalseになるまで `exit 0` にしない。
これにより「ドメインリロードが終わりきる前にテスト対象の解決へ進んでしまう」誤りと、「一時的な
切断1回だけでハング扱いにしてしまう」誤りの両方を防いでいる。exit 2 に到達した場合は、budget
全体を通じて到達不能だったことを意味する（＝一時的な切断のリトライでは済まない状態）。

### 2. テスト対象の解決

対象リストに含まれる全ての対象について、このステップをまとめて行う（対象ごとにコンパイル確認から
やり直さない）。`list_tests --mode EditMode`/`list_tests --mode PlayMode` は対象リストに必要な
モードのみ、それぞれ1回ずつ呼べばよい。

`list_tests --mode <Mode> --json` の応答は `.data.result.Tests` が配列で、各要素が
`{FullName, Mode, Assembly, Categories, Explicit}` を持つ（実地検証済み、2026-08-21。
`jq -r '.data.result.Tests[] | select(.FullName == "<対象>")'` で特定の `FullName` を検索できる）。
`Mode` は各要素に個別に入っており、`--mode EditMode` で呼んでも `--mode PlayMode` で呼んでも
その呼び出しで実際に存在したテストしか返らない点に注意（存在しなければ配列に現れない）。

**呼び出し元（人間の発言・plan文・コントローラーからのディスパッチ文など）が添えた `Mode`
（EditMode/PlayMode）は、実行前に必ず list_tests の実データで裏取りする参考情報であり、
確定情報として鵜呑みにしてはならない。** plan文はテストクラスが実際にどちらのアセンブリ／
基底クラスに属するかを実行時点まで正確に知り得ないため、古い/誤った前提のままModeを
書いていることがある（これを鵜呑みにしてステップ5へ直行すると、指定Modeでの実行が
失敗し、正しいModeでの再試行が必要になる）。

- ユーザーから完全名（`FullName`）が明示された場合でも、そのまま次へ進まず、
  `unity cmd list_tests --mode EditMode --timeout 30` と `unity cmd list_tests --mode PlayMode
  --timeout 30` の出力から当該 `FullName` に完全一致するレコードを探し、実際の `Mode` を確定する
  - 該当レコードが見つからない場合: 誤字や存在しないテスト名の可能性として報告し、実行しない
  - 呼び出し元が添えたModeと実際のModeが食い違う場合: 黙って実際のModeで上書き実行せず、
    その食い違い（指定Mode／実際のMode）をそのまま報告する。plan文等の記載が古い可能性を示す
    シグナルなので、実行を止めてユーザー/コントローラーに確認を仰ぐ
  - 一致した場合（またはそもそもModeが添えられていなかった場合）: 確定したModeでそのまま次へ進む
- クラス名・アセンブリ名・自然言語で渡された場合は `unity cmd list_tests --mode EditMode --timeout 30` と
  `unity cmd list_tests --mode PlayMode --timeout 30` の出力（`FullName`/`Mode`/`Assembly`/`Categories`を含むJSON）を
  ローカルでgrepし候補を絞り込む。**`Mode`は各テストのJSONに含まれているので推定しない**（旧MCP版の
  「testMode を推定するしかない」制約はここでは存在しない）
  - 0件: 誤字や存在しないテスト名の可能性を報告する
  - 1件: そのまま次へ
  - 1アセンブリの全件に一致: ステップ5で `--filter_type assembly` を使う
  - **単一クラスに閉じた複数件**（1つのクラス名に一致するメソッドが複数、かつ assembly より狭い粒度）:
    対話や確認を挟まず、ステップ5で `--filter_type testName` にクラス名をそのまま渡す1回の呼び出しで
    実行する（実地検証済み: クラス名を渡すと所属する全メソッドが1回の呼び出しで実行される）。これが
    テスト実行依頼で最も頻出する粒度であり、「クラスを実行して」という指示自体がその全メソッド実行の
    意図とみなせるため、ここで実行をためらわない（下記「既知の罠」参照）。単一テストのループ実行が
    必要なのは、複数クラスにまたがる個別 `FullName` の組み合わせをユーザーから明示された場合のみである
  - **上記以外で対象を一意に絞れない複数件**（複数クラスにまたがる、または曖昧な自然言語で
    どのクラス/テストを指すか確定できない）: 候補一覧をユーザーに提示して指定を仰ぐ。
    自己判断で全件ループ実行はしない

### 3. 対象を実行グループへ分類

対象リストの各要素を、以下のルールで実行グループへ分類する。

| 対象の性質 | 実行方法 |
| --- | --- |
| 単一クラス／単一アセンブリ全体 | 既存通り `run_tests --filter_type assembly/testName`（EditMode）または `run-playmode-test.sh`（PlayMode） |
| 複数クラスにまたがる個別FullNameの集合 | `unity cmd run_tests_batch_editmode --full_names <カンマ区切り>`（EditMode）または `scripts/run-tests-batch-playmode.sh <カンマ区切り>`（PlayMode） |

同一呼び出し内で複数グループが混在してもよい（例: EditModeの単一クラス実行1件 + PlayModeの
複数クラス横断バッチ1件）。ステップ5で各グループを順に実行する。

### 4. PlayMode時の未保存シーン処理

対象に `Mode: PlayMode` のテストが含まれる場合、実行前に必ず以下を行う（ユーザーへの事前確認は不要、
事後報告のみでよい — ユーザー承認済みの運用）。

1. `unity cmd list_open_scenes --timeout 30` でdirty状態を確認
2. dirtyなシーンが1つでもあれば `unity cmd save_all --timeout 30` を実行する
3. 保存したシーン名を最終報告に含める

これはPlayModeテスト実行がPlayモードへの遷移を伴い、未保存のシーン変更があるとUnityが
「Sceneの保存確認」モーダルダイアログを表示してエディタのメインスレッドをブロックし、
それ以降の`unity cmd`呼び出し全体が応答不能になる既知の障害を、発生条件そのものを潰すことで
回避するため。EditModeのみの実行ではPlayモードに入らないためこの処理は不要。

### 5. 実行

対象に含まれる `Mode` によって実行方法が異なる。

**`Mode: EditMode` のみの場合**（従来通り、同期呼び出し）:

```
unity cmd run_tests --mode EditMode --filter <値> --filter_type <testName|assembly> --timeout <秒>
```

**`Mode: PlayMode` を含む場合**（`scripts/run-playmode-test.sh` を必ず使う。直接
`unity cmd run_tests --mode PlayMode` を呼んではならない — 「禁止事項」参照）:

```
scripts/run-playmode-test.sh <値> <testName|assembly> [timeout] [ポーリング予算秒数]
```

このスクリプトが `run_tests --async_tests` の実行から `test_status` の完了確認・結果の簡易整合性
チェックまでを1コマンドにまとめる（詳細は同スクリプトのヘッダコメント参照）。標準出力に最終結果
JSON（`test_status`由来。`status`/`duration`/`summary`/`results`を含む。EditModeの`run_tests`直接
呼び出しとはキーの大文字小文字が異なる点に注意。詳細はステップ6参照）が出力されるので、これを
ステップ6の結果確認に使う。

- 単一テスト: `--filter_type testName` に ステップ2で確認した完全一致の `FullName` を渡す
- クラス一括: `--filter_type testName` にクラス名を渡す（ステップ2「単一クラスに閉じた複数件」参照）
- アセンブリ全体: `--filter_type assembly` にアセンブリ名を渡す
- 複数クラスにまたがる個別テストをまとめて実行したい場合、`--filter` にカンマ区切りで複数の
  `FullName` を渡しては**ならない**（「既知の罠」参照）。単一テスト呼び出し（PlayModeの場合は
  `run-playmode-test.sh` 呼び出し）をテスト数分ループする。PlayModeでは1回の呼び出しが完了確認
  まで完全にブロッキングするため、ループのイテレーション間で待機が自然に強制される
- `--timeout` の目安: EditMode の単一〜少数テストは `120`、アセンブリ全体の実行は `300` を起点に
  する（`list_tests` 等の照会系は `30`）。`run-playmode-test.sh` の `timeout` 引数（第3引数）も
  同様の目安、ポーリング予算秒数（第4引数、既定90）は対象規模に応じて調整してよい

**バッチコマンド（複数クラス横断）を使う場合**:

- EditMode: `unity cmd run_tests_batch_editmode --full_names <カンマ区切りFullName> --timeout <秒>`
- PlayMode: `scripts/run-tests-batch-playmode.sh <カンマ区切りFullName> [timeout] [ポーリング予算秒数]`（直接 `unity cmd run_tests_batch_playmode` を呼ばない。「禁止事項」参照）

**複数グループがある場合の失敗時の扱い**: テストのPass/Failは通常の結果として扱い、他のグループの
実行を止めない。`unity cmd` 呼び出し自体のハング・タイムアウトは「ハング・タイムアウト時の対応」に
従いその場で止めて報告し、残りのグループを盲目的に続行しない。

### 6. 結果確認・報告

複数グループを実行した場合、このステップは全グループの結果を集約してから行う。グループごとの
Pass/Fail件数を合算したサマリと、失敗があったグループの詳細を報告する。

`run_tests`（EditMode）または `run-playmode-test.sh`（PlayMode）の出力を確認する。

- EditModeの小規模実行はレスポンスに結果が同期的に含まれる（実地確認済み）。キーは
  `Summary.Total/Passed/Failed`、`Results[].FullName/Status/Message/StackTrace`（PascalCase）
- PlayModeは `run-playmode-test.sh` の標準出力JSONを結果源とする。同スクリプトが `test_status` の
  完了確認まで済ませてから結果を返すため、追加のポーリングは不要。ただしこのJSONは`test_status`
  由来（`.data.result` をデコードした中身のオブジェクト）であり、EditMode直呼び出しとはキーの
  大文字小文字が異なる（実地検証済み、2026-08-11）: `status`・`duration`・
  `summary.total/passed/failed/skipped/inconclusive` は小文字、`results[].FullName/Status/
  Duration/Message/StackTrace` はPascalCase、という混在になる
- 件数確認は、EditModeなら `Summary.Total`、PlayModeなら `summary.total`（大文字小文字に注意）を
  期待件数（ステップ2で確認した対象数）と比較する。一致しない場合、フィルタ指定の誤り
  （特に「既知の罠」のカンマ区切り）を疑う。テストの失敗と取り違えない

結果は以下の形式で報告する:

- Pass/Fail件数と所要時間のサマリ
- 失敗があれば `Results` の `FullName`・`Message`・`StackTrace` を列挙
- ステップ4でシーンを保存した場合はその旨を明記

## ハング・タイムアウト時の対応

`unity cmd` の呼び出しがタイムアウトした場合、**同じ呼び出しをそのまま再試行しない**。1回のタイムアウトで
「Unityエディタの画面でモーダルダイアログが出ていないか」の確認をユーザーに直接依頼する。

- **`cancel_tests` を打つ条件**: タイムアウトは即「接続喪失」ではない。多くはUnity側のモーダルダイアログ
  （シーン保存確認・コンパイルエラー・Import等）がメインスレッドをブロックしているだけで、この場合
  `cancel_tests` ではなくダイアログ解消が必要。順序は次の通り: (1) まずユーザーにダイアログの有無を確認依頼
  する（最優先）→ (2) ダイアログが無いとの回答なら、`test_status` 等の軽い照会を1回だけ試す →
  (3) その照会すら応答しない（接続そのものが失われたと疑われる）場合に限り `unity cmd cancel_tests` を
  **1回だけ**試みる。それ以上粘らない

  **バッチコマンド（`run_tests_batch_playmode`）実行中のハングには `cancel_tests` ではなく
  `batch_cancel_tests` を使う**。パッケージ本体の`cancel_tests`はバッチ実行の内部状態を追跡して
  いないため、バッチ実行を止められない。
- **原因解消後の実行は「再試行」ではない**: ユーザーがモーダルを閉じた、コンパイルエラーを直した等、
  タイムアウトの原因が取り除かれたと確認できた後に同じテストを実行し直すのは、禁止対象の「再試行を
  繰り返す」には当たらない。原因が消えたことを確認したうえで通常どおり実行してよい。この再実行では
  `--timeout` を伸ばす必要はなく、元と同じ値でよい（伸ばすのは対象規模が大きい等の別理由がある時だけ）。
  禁止しているのは「原因を潰さないまま `--timeout` を伸ばして叩き直す」盲目的なリトライである

## 既知の罠

- `unity cmd status` というコマンドは**存在しない**（実行すると `Command Not Found` で全コマンド
  一覧が返るだけ）。起動中エディタの一覧（port）を見るのは `cmd` を経由しない `unity status`。
  接続済みエディタ個別のコンパイル状況（`compiling`/`domainReloadInProgress`等）を確認したい
  場合は `unity cmd editor_status --timeout 30` を使う
- `--filter_type` に指定できる値は `testName` / `assembly` / `category` の3つのみ。`FullName` や
  `class` といった文字列は**存在せずエラーになる**（`FullName` は実地検証済み: `Invalid filterType 'FullName'`）。
  クラス単位で実行する専用の filter_type は無いが、`testName` にクラス名をそのまま渡すと所属する全
  メソッドが1回の呼び出しで実行される（実地検証済み。ステップ2「単一クラスに閉じた複数件」参照）
- `--filter_type testName` に**カンマ区切りで複数の完全名を渡すと、エラーにならず `success:true` のまま
  `Summary.Total:0` で静かに空振りする**（実地検証済み）。複数クラスにまたがる個別テストが必要な場合は
  呼び出しをループする。複数クラスにまたがる完全名の集合を1回で実行したい場合は、この罠を踏む
  `--filter_type testName`のカンマ区切りではなく、`run_tests_batch_editmode`/
  `run_tests_batch_playmode`（`Filter.testNames`配列に完全一致名を直接詰める専用コマンド）を使う
- `--filter_type testName` はクラス名（完全一致のクラス名文字列）を渡すと所属メソッド全体にマッチする
  ことを確認済み。それ以外の部分一致・プレフィックス一致の挙動は引き続き未検証。基本は `list_tests` で
  得た完全一致の `FullName`、またはクラス名をそのまま渡す
- `--filter_type category` は未検証（検証環境のテストは現状すべて `Categories:["Uncategorized"]`）。
  使う場合は事前に実地確認すること
- コンパイル完了直後・PlayMode突入直後のドメインリロード中（通常1〜2秒）、`unity cmd` が
  `No Unity Editor instances found with reachable Pipeline servers.` で失敗することがある
  （実地検証済み、2026-08-21）。これは**エディタが未起動という意味ではない**——ドメインリロードで
  Pipelineサーバーが一時的に落ちているだけで、リロード完了とともに自動的に復帰する。
  `ensure-compile-clean.sh`/`run-playmode-test.sh`/`run-tests-batch-playmode.sh`/
  `check-editor-ready.sh` は内部でこれを一時的な切断として扱いポーリング・リトライを続ける
  （`scripts/_lib.sh` の `is_transient_pipeline_unreachable`）ため、スキル利用者が意識する必要は
  通常ない。ただし、これらのスクリプトを介さず `unity cmd` を直接叩いた際にこのメッセージに
  遭遇した場合は、「未接続」と即断せず数秒待って再試行すること
- `recompile_status --json` の `data.result` は `test_status`/`batch_test_status` と同様、JSON文字列
  として二重エンコードされている（`jq '.data.result | fromjson | .status'` で取り出す）。トップレベルに
  `.status` が直接あるわけではない点に注意（実地検証済み、2026-08-21）

## 禁止事項

- このスキルの実行主体はコントローラー本体、または専用の `unity-test-runner` サブエージェントのみ。
  他の実装サブエージェントへの委任プロンプトにテスト実行を含めない
- 実装サブエージェントは、たとえ渡された指示に「テスト実行はunity-test-runnerサブエージェントへ委譲
  する」とあっても、自分でAgentツールを使い `unity-test-runner` サブエージェントを呼び出しては
  ならない（ネストしたサブエージェント呼び出しでは完了通知が呼び出し元ではなくコントローラーに届き、
  呼び出し元が「結果待ち」のまま応答不能になるハーネス側の既知の制約があるため）。テスト実行が必要に
  なった時点で、その旨を結果として報告してターンを終え、コントローラー本体が `unity-test-runner` を
  ディスパッチするのを待つ
- タイムアウト・ハング時に原因（モーダルダイアログ等）を潰さないまま盲目的に再試行しない
  （1回で見切ってユーザーに確認を依頼する。原因解消を確認した後の実行はこの禁止に当たらない）
- `--filter_type testName` にカンマ区切りの複数値を渡さない
- PlayModeのテスト実行は必ず `scripts/run-playmode-test.sh` 経由で行う。`unity cmd run_tests
  --mode PlayMode` を直接（スクリプトを介さず）呼ばない
- バッチのPlayModeテスト実行は必ず `scripts/run-tests-batch-playmode.sh` 経由で行う。`unity cmd
  run_tests_batch_playmode` を直接（スクリプトを介さず）呼ばない
