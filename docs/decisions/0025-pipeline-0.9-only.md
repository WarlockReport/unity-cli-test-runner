# ADR-0025: `com.unity.pipeline` 0.9.x への一本化、コマンドのグループ化への追従と対象 Unity の限定

## Status

Accepted (2026-10-24)

## Context

0.8.0-exp.1 / 0.9.0-exp.1 / 0.9.1-exp.1 のパッケージソースを直接比較し、TestProject（Unity 6000.3.25f1）で実測した。

- **組み込みコマンドの全面改名**: 0.9.0 でコマンドが「グループ + 名前」に再編された（`run_tests` → `test run`、
  `test_status` → `test status`、`list_tests` → `test list`、`cancel_tests` → `test cancel`、`recompile(_status)` →
  `script recompile(_status)`、`editor_status` → `editor status`、`save_all` → `editor save_all`、
  `list_open_scenes` → `scene list_open`、`console` → `console get`、`clear_console` → `console clear`、
  `package_*` → `package *`）。旧名は実行されず `No command named '<旧名>' is available. It was renamed: run 'unity command <新名>'.`
  で失敗する。`unity cmd` は CLI（1.0.0-beta.13）で `unity command` の別名として残る
- 処理内容と応答 JSON の形は 0.8 から変わらない（`test run` / `test list` / `test status` / `script recompile(_status)` の実装は
  0.9.0 と 0.9.1 でバイト単位で同一）。違いは `test run` の `timeout` 既定値（300 → 600 秒）と、応答の `command` フィールドが
  `--verbose` 時などにしか出なくなったこと
- **自前コマンドの属性**: 2 引数の `[CliCommand(name, description)]` は 0.9.0 で `[Obsolete]`（`global` グループに登録）、0.9.1 で
  非推奨が外れた。3 引数 `[CliCommand(group, name, description)]` は 0.9.0 / 0.9.1 の両方にあり警告が出ない。ドット区切りの
  入れ子グループ（組み込みにも `animation.animator` 等がある）も両方で使える。0.9 ではコマンド名が重複すると後から登録された側が
  拒否され、パッケージ本体のコマンドが残る
- **入れ子グループの一覧（実測）**: `unity cmd wr --json` は `data.result` に `{"group":"wr","subgroups":["wr.testrunner"],"commands":[]}`、
  `unity cmd wr.testrunner --json` は `commands[]`（`command`・`name`・`description`）を返す。サーバー側の `listedGroup` は CLI の出力には現れない
- **ダイアログの直接判定は Unity 6000.7 以降のみ**: 0.9 では busy 応答（503）に `busyReason="blocked_by_dialog"` と `dialogs[]` が付くが、
  ダイアログの追跡（`EditorDialogStateMirror`）は `#if UNITY_6000_7_OR_NEWER` で囲まれている。6000.3 では 0.8 と同じく、
  メインスレッド必須コマンドが応答しなくなるだけ
- **同時実行上限**: 実行待ちのコマンドが 100 件を超えると 429 と `error="Too Many Queued Commands"`（ジョブは `"Too Many Queued Jobs"`）を返す。`retryable` は付かない
- **0.9 で新たに観測した一時的切断の文言（実測）**:
  - `UNITY_PROJECT_PATH` で接続先を固定していると、C# 変更直後の再コンパイル中に `No Pipeline instance found for project: <パス>. Make sure Unity Editor is running ...`
    （`unity cmd` の終了コード 6）で失敗することがある
  - `com.unity.pipeline` 自体の版を差し替えた直後（サーバーの再起動中）は、`Network error: An error occurred while sending the request.` で接続自体が失敗する
- **版の組み合わせのずれ（実測）**:
  - Pipeline 0.8 のプロジェクトに 3 引数の `CliCommand` を使う本パッケージを入れると、0.8 にその属性が無いためプロジェクト全体がコンパイルエラーになる
  - Pipeline 0.8 のサーバーに 0.9 の名前で呼ぶと、`editor` / `script` / `test` / `wr.testrunner` は
    `Pipeline server returned 400 Bad Request: Command Not Found. No command named '<最初の語>' is available. ...` で失敗する。
    ただし 0.8 にも同名のフラットなコマンドがある `console` は、2 語目が引数と解釈されて `Invalid arguments for console: --tail expects Int32 but got clear.` になる
  - Pipeline 0.9 + 本パッケージ v0.8.0 では、旧版のコマンドは `global` に登録されて旧名のまま動くが、`wr.testrunner …` は
    `Command Not Found. No command named 'wr.testrunner' is available.` で失敗する
- 対象とする Unity を LTS の版に限ることにした。現在の LTS のうち、検証しているのは 6000.3 だけである

## Decision

- **0.9.0-exp.1 以降に一本化する**。0.8 との互換（新旧名の呼び分け）は持たない。0.8 の利用者は `v0.8.0` タグ（ADR-0024）に固定する
- スクリプト・SKILL.md・E2E の `unity cmd` 呼び出しを 0.9 の名前に置き換える
- 自前コマンドを 3 引数形式で **`wr.testrunner` グループ**に登録する（コマンド名・引数名・応答 JSON の形は変えない）。`wr` を付けるのは、
  将来 Unity が同名のグループ・コマンドを足したときに自前のコマンドが黙って消えるのを避けるため
- `TestRunnerCli.asmdef` の `versionDefines` に `com.unity.pipeline` 0.9.0-exp.1 以上の条件を付け、0.9 未満のプロジェクトでは自前コードを
  コンパイル対象から外す（実測: 0.8 でコンパイルが通り、0.9.0 / 0.9.1 では有効になる）
- **版の組み合わせのずれを終了コード 3 で報告する**。`_lib.sh` の `is_command_not_found`（`Command Not Found` / `No command named`）に
  一致したら、`run_unity_cmd_resilient` は戻り値 3 を返し、各スクリプトは `exit_on_version_mismatch` で診断を出して終了コード 3 で終える。
  一時的失敗の判定より先に見る（リトライしても解消しないため）。ダイアログ判別のプローブ（`script recompile_status`）が見つからない場合も同じ扱いにする
  （0.8 の `console clear` のように、別の失敗の形でしか版のずれが表に出ない場合を拾うため）
- 一時的失敗に、429（`429 Too Many Requests` / `Too Many Queued Commands` / `Too Many Queued Jobs`）と、上記 2 つの瞬断の文言を加える
- 6000.3 でのダイアログ判定は従来どおり（応答の非対称性による判別）。直接判定は扱わない
- **対象 Unity は LTS（現在 6000.3）に限る**。`unity/package.json` の `unity` を 6000.3 に上げる
- **TestProject は 1 つに保つ**。Unity の版は対象とする LTS に合わせ、次の LTS を対象にするときにその版で開いて変換してからコミットする。
  manifest の `com.unity.pipeline` は対応する最新の版にし、ほかの対応版は `bash e2e/run-all.sh --pipeline <版>` で確かめる
  （起動中の Editor の Pipeline を一時的に差し替えて照合し、終了時に manifest を git の状態へ戻す。0.9 未満には切り替えない）

## Consequences

- 2026-10-24 に TestProject（6000.3.25f1）で、Pipeline 0.9.1-exp.1 と 0.9.0-exp.1（`--pipeline`）の両方について E2E が 28 件すべて一致した
- 2026-10-24 に 6000.3.25f1 + 0.9.1-exp.1 で、保存確認のモーダルダイアログを出したまま実行し、従来どおりの判定を確かめた。
  `editor status` はサーバーの 60 秒打ち切りより先に CLI の 30 秒タイムアウト（`Pipeline command 'editor' timed out after 30000ms`、
  `unity cmd` の終了コード 6）で切れ、busy（503）は返らない。`script recompile_status` は応答し続けるので、
  `check-editor-ready.sh` は 1、`ensure-compile-clean.sh` は 4 でダイアログブロックとして報告した
- 片方だけ更新した利用者は、「未起動」や「ハング」ではなく版の不一致として案内される（実測: Pipeline 0.8 + 新プラグインで `check-editor-ready.sh` /
  `ensure-compile-clean.sh` が 3、Pipeline 0.9 + UPM v0.8.0 で `run-tests-batch-editmode.sh` が 3）
- 6000.0〜6000.2 のプロジェクトには本パッケージの 0.9.0 を導入できない
- Unity 6000.7 系が LTS として対象に入ったら、`busyReason="blocked_by_dialog"` + `dialogs[]` による直接判定と、ダイアログ表示中の
  `editor status` が「ダイアログ直前のスナップショット」を返す挙動（コンパイル確認の安定確認を誤らせうる）を実機で確かめて取り込む
- 自前コマンドの応答 JSON の `Command` フィールドの値（`run_tests_batch_playmode` 等）は従来のまま残した。0.9 本体はフルネームを入れるため、表記は揃っていない
