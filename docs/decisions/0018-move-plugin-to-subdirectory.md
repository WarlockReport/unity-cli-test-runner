# ADR-0018: Claude Code プラグイン本体を `claude-plugin/` サブディレクトリへ移す

## Status

Accepted (2026-10-15)

## Context

- `.claude-plugin/marketplace.json` の `"source": "./"` により、プラグインのインストール時にリポジトリ全体がプラグインキャッシュへ複製されていた。GitHub から 0.5.0 を入れたキャッシュの直下には、プラグインの実行に不要な `unity/`（UPM パッケージ）・`docs/`・`README.md`・`.gitignore` まで含まれていた。また、2026-08-25 にローカルディレクトリのマーケットプレイスから当時の Claude Code で入れた開発者の環境では、キャッシュに ignore 対象のローカル専用ファイルまで複製されていた（2026-10-15 にキャッシュの中身を確認）
- 今後、開発・検証用の Unity プロジェクトと E2E 照合スクリプトをリポジトリに追加する予定であり、そのままではそれらもすべての利用者のキャッシュへ複製される

## Decision

- プラグインの実体（`.claude-plugin/plugin.json`・`skills/`・`agents/`）を `claude-plugin/` へ移し、マーケットプレイスの manifest（`.claude-plugin/marketplace.json`）だけをリポジトリのルートに残して `"source": "./claude-plugin"` とする
- MIT ライセンスの条件を満たすため、`claude-plugin/LICENSE` にルートの `LICENSE` の複製を置く（`unity/LICENSE.md` と同じ方式）
- マーケットプレイス名・プラグイン名・スキル名・エージェント名は変えない。プラグインの版を 0.5.0 → 0.6.0 に上げる
- スキル・エージェント定義・スクリプトの中身は変えない。スキル間の参照はスキルのディレクトリを起点とする相対表記で、スクリプトは自身のディレクトリを起点に `_lib.sh` を読むため、`claude-plugin/` 配下へ丸ごと移しても解決先は変わらない

## Consequences

- プラグインキャッシュに入るのは `claude-plugin/` の中身だけになる
- プラグインの実行に必要なファイルは、今後すべて `claude-plugin/` の中に置く必要がある（外側のファイルはキャッシュに入らず、参照できない）
- 既存の利用者は通常の更新（`/plugin marketplace update` → プラグインの更新）だけで 0.6.0 に移行できる。入れ直しは不要（下記の実地検証）
- 戻すときは、`marketplace.json` の `source` を `./` に戻すだけでは足りない（ルートに `plugin.json` が無いため）。この変更の PR を revert し、版を 0.6.1 に上げて出し直す

## 実地検証

実地検証済み（2026-10-15、Claude Code 2.1.300、Unity 6000.3.25f1 + `com.unity.pipeline` 0.8.0-exp.1）。

利用者の環境に影響しないよう、`CLAUDE_CONFIG_DIR` で隔離した一時設定ディレクトリで、シェルの `claude plugin ...` コマンドを使って GitHub 経由の更新を再現した。

- 作業ブランチを移動前のコミットの地点で push し、`claude plugin marketplace add 'WarlockReport/unity-cli-test-runner#<ブランチ>'` → `claude plugin install` で 0.5.0 を入れた。キャッシュの直下は `.claude-plugin`・`.gitignore`・`agents`・`docs`・`LICENSE`・`README.md`・`skills`・`unity` だった
- 移動後のコミットを同じブランチに push し、`claude plugin marketplace update` → `claude plugin update` を実行すると「updated from 0.5.0 to 0.6.0」となり、`source` の変更に自動で追従した。0.6.0 のキャッシュの直下は `.claude-plugin`・`agents`・`LICENSE`・`skills` だけだった（このほかに Claude Code 自身が置く `.in_use` がある）
- `claude plugin details` で、スキル 2 つ（`unity-cli-test-runner`・`unity-compile-check`）とエージェント 1 つ（`unity-test-runner`）が従来と同じ名前で認識された
- 0.6.0 のキャッシュ内の `skills/unity-compile-check/../unity-cli-test-runner/scripts/` を起点に、リポジトリ外を CWD にして、起動中の Editor に対して `check-editor-ready.sh`・`ensure-compile-clean.sh` を実行し、ともに exit 0 になった
- 現行の公式ドキュメントによれば、ローカルディレクトリから追加したマーケットプレイスでは、相対パスの `source` のプラグインはキャッシュへ複製されずにその場で読み込まれる。Context に書いた 2026-08-25 の導入環境ではキャッシュへ複製されていたため、Claude Code の版によって挙動が異なる可能性がある（この経路での 0.6.0 への更新は未検証）。キャッシュの中身の確認は、利用者と同じ GitHub 経由の経路でのみ行った
