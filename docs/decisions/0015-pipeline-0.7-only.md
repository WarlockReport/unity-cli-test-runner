# ADR-0015: `com.unity.pipeline` 0.7.0-exp.1 への一本化と、コンパイルエラー判定の一次情報の移動

## Status

Accepted (2026-09-21)

## Context

UPMレジストリの `com.unity.pipeline` の `dist-tags.latest` が `0.7.0-exp.1` になった。0.7 の変更のうち、本リポジトリに直接影響するのは次の1点である。

- **`get_console_logs` が削除された**。0.7 の CHANGELOG は「`console` を自前の第2バッファで重複実装しており、全ログ行が二重にキャプチャされ、`clear_console` はそのうち片方しか消していなかった」ことを削除理由に挙げている。代替は `console`（`logType` フィールドが `get_console_logs` の報告していた正確なログ種別を引き継ぐ）

`ensure-compile-clean.sh` はステップ5で `get_console_logs --severity error` を叩き、返ってきた `logs` 配列の件数でコンパイルエラーの有無を**判定**していた。0.7 ではこの呼び出しが `Command Not Found` で失敗するため、コンパイルチェックが機能しなくなる。

0.6 と 0.7 の tarball をUPMレジストリから取得し、ソースを直接 diff して以下を確認した（ADR-0012 と同じ手法、2026-09-21）。

| 確認項目 | 結果 |
|---|---|
| `CliCommandAttribute` / `CliArgAttribute` | `Runtime/Common/`（= `Unity.Pipeline` アセンブリ）に残留し、**バイト単位で同一**。新設された `Unity.Pipeline.Attributes` アセンブリの中身は `CodeReloadAttributes.cs` のみ → `TestRunnerCli.asmdef` の `references` は変更不要 |
| `CommandExecutionResponse` / `BaseResponse` | 0.7 でも public（`Runtime/Models/`）→ ベンダリング済みモデル（ADR-0012）はそのまま有効 |
| `Editor/Commands/TestCommands.cs` | 0.6→0.7 で差分なし（`run_tests` / `list_tests` / `test_status` / `cancel_tests`） |
| `Editor/Testing/TestResultCollector.cs` / `PipelineTestRunner.cs` | 0.6→0.7 で差分なし |
| `recompile_status` の `.data.result` | 0.7 でも `JsonConvert.SerializeObject` で**文字列として**返る（二重エンコードは維持）。中身に `compilationFailed` が追加された |
| `recompile` / `recompile_status` | エラーが残っている状態では `status:"failed"` を返すようになった。0.6 は同じ状況で `up_to_date` を返し、記録済みの失敗を消していた |
| `recompile_status` の正規化 | `status` が `idle`/`up_to_date`（＝自前の証拠を持たない状態）でネイティブフラグが立っていれば `completed` + `failed=true` に書き換えて返す。`completed` は上書きしない |
| `console` / `console_status` | `MainThreadRequired = false`。`clear_console` は `MainThreadRequired` 未指定＝既定 true のままで、依然ダイアログでブロックされうる |
| `compilationFailed` の鮮度 | groundTruth のサンプルが2秒以内（`MaxGroundTruthAgeSeconds = 2.0`）でなければ false に倒れる。サンプリングはメインスレッドで動く |
| `BasePipelineServer.cs` の `blocked_by_dialog` | 0.6 と同一（行番号まで一致）→ Unity 6000.3.14f1 で無効という前提（ADR-0013）は変わらない見込み。非対称判別は引き続き必要 |
| 新 `wait_for` / `wait_status` / `wait_cancel` | 条件は「メンバの dotted path + op」指定で、sync は exec キューを塞ぐ。本リポジトリのポーリング置換には形が合わない |

## Decision

- **0.7 一本化する。0.6 以前のサポートを打ち切る**（ADR-0012 で 0.5 を切ったのと同じ判断）。実験的パッケージに対する多版サポートはコストに見合わない
- **コンパイルエラーの判定の一次情報を `get_console_logs` のログ走査から `recompile_status` の `failed` / `compilationFailed` へ移す。`console` は詳細取得専用にする**。0.7 でこの2フラグが追加され、ネイティブのコンパイル失敗フラグを参照するようになったことで、「ログに何件出ているか」より信頼できる一次情報が手に入るようになった
- **詳細が取れなくても判定は覆さない**。`console` の `entries` が空でも、`console` 呼び出し自体が失敗しても `exit 1` を維持する。sticky エントリの backfill 事情で詳細が欠けることがあるため、ここで成功に倒すと「エラーがあるのに通った」という最悪の誤報告になる（ADR-0014 と同じ「数値・判定を捏造しない」原則の適用）
- `recompile` が `status:"failed"` を返した場合は、ポーリングを飛ばして直ちに詳細取得へ進む。この状態ではコンパイルが走らないので、待っても状態は変わらない
- `recompile_status` のポーリングは `failed` も終端状態として扱う。ただしこの関数ではエラー有無の判定をせず、ドメインリロード完了の安定確認（ステップ4）を必ず通してからステップ5で判定する。`compilationFailed` には2秒の鮮度制約があり、ドメインリロード完了直後の読み直しが最も信頼できるため
- **終了コード 3 の定義を「`recompile_status` から `failed`/`compilationFailed` を取り出せず判定不能」に変更する。** 設計文書は当初「`console` の返り値形式が想定と異なり判定不能」としていたが、判定の一次情報が `recompile_status` に移り、かつ「詳細が取れなくても `exit 1` を維持する」と決めた以上、`console` の形式異常で判定不能になる経路は存在しない
- `_lib.sh` は変更しない。`is_blocked_by_dialog` の probe に使う `recompile_status` は 0.7 でも `MainThreadRequired = false` で、busy 検出の実装も 0.6 と同一である
- **Unity 側 C# は変更しない。** 前提版が変わったことの記録として `unity/package.json` を 0.3.0 に上げるに留める
- `wait_for` / `wait_status` / `wait_cancel` は採用しない（形が合わない）。`console` の cursor を使った継続取得、`console_status` 中心へのポーリング再構成も今回は行わない

## Consequences

- 0.6 以前を使っているプロジェクトでは `ensure-compile-clean.sh` が動かなくなる。README・`unity/README.md`・両 SKILL.md の前提に 0.7.0-exp.1 以降を明記した
- コンパイルエラーの判定が、ログという二次的な表現から Unity のコンパイル失敗フラグという一次情報に変わり、「コンソールがクリアされていた」「ログのキャプチャが死んでいた」といった理由で見逃す余地が減った
- 逆に、`console` の詳細が空でも `exit 1` を返すケースが生まれる。この場合は「詳細が取れなかったコンパイルエラー」として報告される（標準エラーにその旨を出す）
- `recompile` 呼び出しに `--json` が必要になった（`status` を読むため）。0.6 まではレスポンスを捨てていたので付けていなかった
- `unity` CLI を模擬するモック（`tests/fake-unity/unity`）を常設化し、終了コード 0/1/2/3/4 の全経路を Unity 実機なしで回帰テストできるようにした。ADR-0013 では使い捨てのモックで検証していたものを、テストファイル（`tests/ensure-compile-clean.test.sh`）として残した形である。ただし `tests/` は `.gitignore` 対象のためリポジトリには含まれない
- `console` の `--tail` / `--level` というCLIフラグ名は、パッケージのソース上の引数名（`tail` / `level`）から導いたもの。実機検証で実際のフラグ名を確認している（下記「実地検証」節）

## 実地検証 (2026-09-21)

Unity 6000.3.14f1 + `com.unity.pipeline` 0.7.0-exp.1 が導入済みのプロジェクトを対象に、
`ensure-compile-clean.sh` の受け入れ確認を実機で行った。

- **`console` の実際のフラグ名**: `--level error --tail 5 --json` で成功。`ensure-compile-clean.sh`
  に既に書かれている `--level` / `--tail` はそのまま正しく、修正は不要だった。
  `.data.result` のキーは `entries` / `cursor` / `session` / `returned` / `dropped` / `reset` /
  `counts`（`error`/`warn`/`log`）/ `groundTruth`（`sampledUtc`/`ageMs`/`compilationFailed`/
  `compiling`/`consoleErrors`/`consoleWarnings`/`consoleLogs`/`seeded`）だった
- **`recompile_status` の実応答**（正常時、`jq -c '.data.result | fromjson'`）:
  `{"status":"idle","failed":false,"errors":[],"compilationFailed":false}`。
  `.data.result` が JSON 文字列として二重エンコードされている点は 0.7 でも維持されていることを確認した
- **Step 4〜8 の終了コード実測**:
  - Step 4（正常系）: `exit=0`。標準エラー最終行 `コンパイル確定・エラー無し。テスト対象の解決へ進んでよい。` を確認
  - Step 5（構文エラーを含むファイルを新規追加）: `exit=1`。標準出力の `console` JSON の
    `entries[]` に `error CS1525: Invalid expression term ';'` を含む1件が返り、標準エラーに
    `コンパイルエラーを検出しました（recompile_status: failed=true compilationFailed=true）` が出た
  - Step 6（エラーを直さず再実行）: `exit=1` のまま。標準エラーに
    `recompile が status:"failed" を返しました（コンパイルエラーが残っています）。ポーリングを飛ばして詳細取得へ進みます。`
    が出ており、**早期分岐の経路**を通ったことを確認した（通常ポーリング経路は通っていない）
  - Step 7（エラーファイルを削除して「修正」相当にする）: `exit=0` に復帰。0.7 の正規化
   （`up_to_date`/`idle` → `completed` + `failed=true`）が、直った状態を誤ってエラー扱いする方向には
   効いていないことを確認した
  - Step 8（現在開いているシーンファイルへ外部プロセスから末尾に空行を1行追記）: 想定していた
    `exit=4`（ダイアログブロック）は**観測できなかった**。追記直後・Unity Editor をアクティブ化した
    直後のいずれでも `editor_status` は `ready` のままで、シーンの dirty フラグにも変化がなく、
    `ensure-compile-clean.sh 30` は通常どおり `exit=0` で完了した。少なくとも今回の実機構成
    （外部プロセスによるファイル末尾への空行追記、Unity 側のフォーカス遷移を伴う確認）では、
    現在開いているシーンファイルの外部変更が「Reload/Ignore」ダイアログを自動的には引き起こさな
    かった。ダイアログ自体が発生しなかったため、閉じる操作も不要だった。検証後、追記した空行は
    元のファイルへ復元し、差分が無いことを確認済み。ダイアログブロック（`exit=4`）経路そのものは
    今回の実機検証では再現できていない
- **Step 9（テスト実行4経路）**: EditMode 単一クラス（テストメソッド16件）、EditMode バッチ
  （異なる2クラスから1件ずつ計2件）、PlayMode 単一クラス（テストメソッド6件）、PlayMode バッチ
  （異なる2クラスから1件ずつ計2件）の4経路すべてで `summarize-test-result.sh` の `SUMMARY` 行が出て
  終了コード0だった（全件PASS）。レスポンス形状も 0.6 から変化していないことを確認した:
  EditMode（`run_tests` 直接応答）は `Summary.{Total,Passed,Failed,Skipped,Inconclusive}` の
  PascalCase、PlayMode（`test_status` 経由）は `summary.{total,passed,failed,skipped,inconclusive}`
  の小文字 + `results[].{FullName,Status,Message,StackTrace,Duration}` の PascalCase という
  混在がそのまま残っていた。`Editor/Commands/TestCommands.cs` に0.6→0.7で差分が無いという記録
  （Context節）の裏取りになった

## 未解決

- `busyReason="blocked_by_dialog"` が Unity 6000.3.x で有効になる版。0.7 のソースは 0.6 と同一なので、Unity 本体側の対応待ちと見られる
- `console` の cursor（`since` / `since_session`）を使った差分取得は未活用。「今回のコンパイルで出たエラーだけ」を厳密に取り出す手段になりうるが、sticky エントリの扱いと組み合わせた挙動が未検証
