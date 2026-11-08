# ADR-0028: `com.unity.pipeline` 0.10.x への一本化と引数名の kebab-case 化

## Status

Accepted (2026-11-08)

## Context

`com.unity.pipeline` 0.10.0-exp.1（2026-11-02）が出た。TestProject（Unity 6000.3.25f1、`unity` CLI 1.0.0-beta.13）で実測した。

- **Pipeline 本体の引数名が kebab-case になった（changelog に記載なし）**: `unity cmd test run ... --filter_type testName` は
  `success:false`、`errors[].code = "INVALID_COMMAND_ARGS"`、
  `Invalid arguments for test:\n  test has no parameter --filter_type. Did you mean --filter-type?` で拒否される
  （`--async_tests` も同様）。`--filter-type` / `--async-tests` に直すと正常に実行される
- 0.9 対応版のスクリプトのままの e2e は一致 43 / 不一致 7 で、不一致はすべて `test run` を使う照合だった。
  スクリプトはこのエラーを「一時的でない失敗」として終了コード 2（ハング・予算超過）で報告しており、原因が伝わらなかった
- `console get` は `--since_session` と `--since-session` の両方を受け付け、応答の `parameters` では `since-session` に
  正規化される（2026-11-08 実測）。スキルの記述は `--since-session` に揃えた
- **自前コマンドの引数は宣言どおりの名前でしか通らない**: `[CliArg("full_names", ...)]` のコマンドは `--full_names` で通り、
  `--full-names` は `has no parameter --full-names. Did you mean --full_names?` で拒否される。CLI が名前を変換しているのではなく、
  宣言名と完全一致で照合している。宣言名を `full-names` に変えると `--full-names` で通り、`--full_names` は
  `wr.testrunner has no parameter --full_names. Did you mean --full-names?` で拒否されることを確認した
- コマンド名（`recompile_status`、`run_tests_batch_editmode` など）の snake_case は 0.10 でも変わらない
- 値の誤りは別の形で返る: 型の合わない値は `INVALID_COMMAND_ARGS` の `--tail expects Int32 but got abc.`、
  `--filter-type` の範囲外の値は `success:true` のまま `.data.result.success:false`・`error:"Invalid filterType 'bogus'. ..."`
- 0.10 では `editor status` に `codeLoadCount` が加わった（コンパイル完了の判定に使う。ADR-0029）

## Decision

1. **0.10 専用にする（0.9 との互換は取らない）**。版番号はプラグイン・UPM パッケージとも 0.10.0、共通タグ `v0.10.0`
   （ADR-0024）。`TestRunnerCli.asmdef` の `versionDefines` を `0.10.0-exp.1` に上げる。0.9 の利用者は `v0.9.2` に固定する
2. **Pipeline 本体の呼び出しを kebab-case の引数名にする**（`--filter-type`、`--async-tests`）
3. **自前の `wr.testrunner` コマンドの引数名も kebab-case に揃える**（`full-names`、`async-tests`、`include-categories`、
   `exclude-categories`、`exclude-names`。`assembly`・`timeout`・コマンド名・応答 JSON は変えない）。Pipeline 本体と同じ
   見た目にしておくと、手で叩くときに引数名の流儀を取り違えない
4. **引数名の不一致を版の組み合わせのずれ（終了コード 3）として報告する**。`_lib.sh` の `is_command_not_found` が見る文言に
   `has no parameter --` を加える。`run_unity_cmd_resilient` が 3 を返し、`exit_on_version_mismatch` が版を揃える案内を出す。
   `INVALID_COMMAND_ARGS` というコード全体では判定しない（値の誤りまで版のずれと報告しないため）。
   引数名が kebab-case になったことで、プラグインと UPM パッケージの片方だけを更新した組み合わせはこの形で失敗する
5. `e2e/run-all.sh --pipeline` は 0.10 以上の版だけを受け付ける（0.10.x 間の差し替え照合に使う）
6. `check-editor-ready.sh` には版の確認を足さない。0.9 の環境では ready と答え、次の `ensure-compile-clean.sh` や
   テスト実行スクリプトで終了コード 3 になる流れを受け入れる

## Consequences

- 0.9 以前の Pipeline では、プラグインの各スクリプトが終了コード 3 で止まる（`ensure-compile-clean.sh` は `codeLoadCount` が
  無いこと、テスト実行スクリプトは引数名の不一致またはコマンド不在で）。UPM パッケージのコードはコンパイル対象から外れる
- UPM パッケージの引数名変更は破壊的変更で、`unity cmd wr.testrunner ...` を直接叩いていた利用者は引数名を直す必要がある
- 引数名の不一致は「コマンドまたは引数が見つからない」として報告される。終了コード 3 の意味（想定外の応答形状、
  版の組み合わせのずれを含む）は変わらない
- 範囲外の `--filter-type` の値は従来どおり終了コード 0 で返り、`.data.result.success:false` を読む側で扱う（今回は変えていない）

### 実地検証（2026-11-08、TestProject）

- `e2e/run-all.sh`: 一致 59 件 / 不一致 0 件（0.9 対応版のままでは一致 43 / 不一致 7 だった `test run` 系の照合を含む。
  PlayMode の `test status` は 0.10 で結果の集め方が変わったが、`7-playmode-class` / `7-playmode-assembly-ns-mismatch` は一致し、
  同じ filter での PlayMode の連続実行 2 回も exit 0 で、stale 検知・取り違え検知は誤発火しなかった）
- `e2e/run-all.sh --pipeline 0.10.0-exp.1`: 一致 59 件 / 不一致 0 件、後片付け成功。0.10 では `package add` の引数が
  `--identifier` ではなく `--name` であり（`package has no parameter --identifier.` で拒否される）、`e2e/run-all.sh` もこれに合わせた
- 版のずれ: Pipeline を 0.9.1-exp.1 に戻した TestProject で、`ensure-compile-clean.sh`（`codeLoadCount` が無い）、
  `run-tests-batch-editmode.sh`（自前コマンドがコンパイル対象から外れる）、`run-editmode-test.sh`
  （`test has no parameter --filter-type. Did you mean --filter_type?`）がいずれも exit 3 と版を揃える案内を返した。
  0.10.0-exp.1 に戻すと `ensure-compile-clean.sh` は exit 0
