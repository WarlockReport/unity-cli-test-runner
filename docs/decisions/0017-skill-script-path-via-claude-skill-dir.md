# ADR-0017: スキルのスクリプト参照を `${CLAUDE_SKILL_DIR}` 起点の絶対パス表記にする

## Status

Accepted (2026-10-04)

## Context

実利用で、実装担当から「`unity-compile-check` スキルの本文に書かれたスクリプトの相対パスが、実際の配置と合っていない」という報告があった。

- `unity-compile-check` はロジックの複製を避けるため、`unity-cli-test-runner` 側のスクリプトを `../unity-cli-test-runner/scripts/...` で参照している。この相対パスは、スキルのベースディレクトリから辿ればリポジトリでもインストールキャッシュ（`~/.claude/plugins/cache/<marketplace>/wr-unity-cli-tools/<version>/skills/`）でも正しい場所を指している
- ただしコードブロックには `../unity-cli-test-runner/scripts/check-editor-ready.sh` がそのまま書かれ、「ベースディレクトリを起点に解決すること」という注記は前提の箇条書きに埋もれていた。LLM がコードブロックを、対象 Unity プロジェクトのカレントディレクトリのままで実行すると見つからない。報告の原因はこれと推定した（報告者の実行ログは未確認）
- `unity-cli-test-runner` の `scripts/...` や `agents/unity-test-runner.md` の例も同じ構造で、潜在的に同じ問題を持つ
- Claude Code（2.1.289 で確認）は、スキル本文中の `${CLAUDE_SKILL_DIR}` をスキルのディレクトリの絶対パスに置き換える。同梱スキルにも `${CLAUDE_SKILL_DIR}/../run` という同じ形の参照がある

## Decision

- 2 つの SKILL.md で、実行するコマンドとして書かれたスクリプトのパスを `${CLAUDE_SKILL_DIR}/scripts/...`（`unity-compile-check` は `${CLAUDE_SKILL_DIR}/../unity-cli-test-runner/scripts/...`）にする。スクリプト名を名詞として挙げているだけの箇所は変えない
- 保険として、「パスが `$` で始まる変数表記のまま残っていたらベースディレクトリの絶対パスで置き換える」という注記を前提に残す。展開されない環境でも従来と同じ水準に劣化するだけで済む
- **注記などの地の文には `${CLAUDE_SKILL_DIR}` という変数名を書かない**。置換はコードの中かどうかを区別せず本文全体に効くため、「`${CLAUDE_SKILL_DIR}` が展開されずに残っていたら」と書くとその箇所まで絶対パスに置き換わり、意味の通らない文になる（実地検証で確認）
- エージェント定義（`agents/unity-test-runner.md`）では変数が展開されないため、「スキルを読み込んだときに展開された絶対パスを使う」という書き方にする

## Consequences

- コードブロックのコマンドを、カレントディレクトリに関係なくそのまま実行できる
- `${CLAUDE_SKILL_DIR}` を展開しない旧版の Claude Code やその他のハーネスでは、注記どおりに LLM が読み替える必要がある（従来と同じ）

## 実地検証

実地検証済み（2026-10-04、Claude Code 2.1.289）。

- `unity-compile-check` を読み込むと、コードフェンス内の `${CLAUDE_SKILL_DIR}/../unity-cli-test-runner/scripts/...` がスキルのディレクトリの絶対パスに展開された。展開後のパスを、対象 Unity プロジェクトをカレントディレクトリにしたまま実行し、`check-editor-ready.sh` と `ensure-compile-clean.sh` がともに exit 0 になった
- 一方、前提の注記に書いた「`${CLAUDE_SKILL_DIR}` が展開されずに…」という地の文まで絶対パスに置き換わり、意味の通らない文になった。これを受けて、地の文から変数名を除く書き方に改めた（Decision の最後の項目）
