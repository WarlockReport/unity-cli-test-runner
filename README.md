# unity-cli-test-runner

[Unity CLI](https://docs.unity.com/en-us/unity-cli/unity-cli) と [Unity Pipeline package](https://docs.unity3d.com/Packages/com.unity.pipeline@0.8/manual/index.html) を使用して、コード修正後に指定したテストを実行するための Claude Code プラグインです。

対象 Unity プロジェクト側に導入する Unity Editor 拡張（UPMパッケージ）と、Claude Code 側のスキル・専用サブエージェントの 2 つで構成されています。

## 前提条件

- `unity` CLI と `jq` が PATH 上にあること
- 対象Unityプロジェクトに `com.unity.pipeline` パッケージ（**0.8.0-exp.1 以降**）が導入済みであること。
  0.7.0-exp.1 以前には対応していない（0.8 でカスタムコマンドの属性のアセンブリが移り、`*_status` の
  応答がネイティブなJSONになったため。詳細は [ADR-0016](docs/decisions/0016-pipeline-0.8-only.md)。
  0.6・0.5 を切った経緯は [ADR-0015](docs/decisions/0015-pipeline-0.7-only.md)・
  [ADR-0012](docs/decisions/0012-vendor-pipeline-internal-types.md)）

## インストール

### 1. Claude Codeプラグイン

```
/plugin marketplace add WarlockReport/unity-cli-test-runner
/plugin install wr-unity-cli-tools
```

スキル `unity-cli-test-runner`（テスト実行）・`unity-compile-check`（コンパイル確認のみ、テスト実行なし）と、
専用サブエージェント `unity-test-runner` が使えるようになります。

> **既存導入者向けの注意**: 以前 `unity-cli-test-runner` という名前でこのプラグインを導入していた場合、
> プラグイン名・マーケットプレイス名の変更に伴い自動では追従されません。
> `/plugin uninstall unity-cli-test-runner` （または該当プラグインの削除）と
> 旧マーケットプレイスの削除を行った上で、上記コマンドで入れ直してください。

#### プラグインの更新

このマーケットプレイスの自動更新は既定で無効のため、明示的に更新しない限り、導入した時点の版が使われ続けます。
`com.unity.pipeline` の版を上げたときは、プラグインも最新版に更新してください（シェルで実行し、
その後 Claude Code のセッションで `/reload-plugins` を実行するか、セッションを開き直します）。

```
claude plugin marketplace update wr-unity-cli-tools-dev
claude plugin update wr-unity-cli-tools@wr-unity-cli-tools-dev
```

`/plugin` の **Marketplaces** で `wr-unity-cli-tools-dev` を選び、**Enable auto-update** を選ぶと、以後は自動で更新されます。
導入済みの版は、シェルで `claude plugin details wr-unity-cli-tools` を実行すると確認できます。

> **古い版のまま使い続けた場合の症状**: プラグイン 0.3.x 以前の `ensure-compile-clean.sh` は、
> `com.unity.pipeline` 0.7 で削除された `get_console_logs` を最終段で呼ぶため、コンパイルが成功していても
> 終了コード 2（タイムアウト扱い）で止まります。この症状が出たら、上記の手順でプラグインを更新してください
> （`com.unity.pipeline` 0.8 にはプラグイン 0.5.0 以降が対応しています）。

### 2. Unity側パッケージ

対象Unityプロジェクトの Package Manager → `+` → `Add package from git URL...` に以下を入力します。

```
https://github.com/WarlockReport/unity-cli-test-runner.git?path=/unity
```

詳細は [`unity/README.md`](unity/README.md) を参照。

## 構成

```
.claude-plugin/    マーケットプレイスmanifest
claude-plugin/     Claude Codeプラグイン本体（インストール時にこのディレクトリだけが複製される）
  skills/          unity-cli-test-runner・unity-compile-check スキル本体（SKILL.md・スクリプト）
  agents/          テスト実行専用サブエージェント定義
unity/             Unity側UPMパッケージ（Editor拡張）
TestProject/       開発・検証用のUnityプロジェクト（配布物には含まれない）
e2e/               TestProjectに対するE2E照合スクリプト（配布物には含まれない）
```

## 開発者向け: E2E の実行

`TestProject/` を Unity 6000.3.25f1 で開いた状態で、次を実行すると、スキルのスクリプトを起動中の Editor に対して
順に実行し、結果を期待値と照合します。詳細は [`TestProject/README.md`](TestProject/README.md) を参照してください。

    bash e2e/run-all.sh

## 参考資料

- [The Unity Pipeline package and Unity CLI: Installation guide and walkthrough](https://unity.com/resources/unity-pipeline-cli-technical-walkthrough)

## ライセンス

MIT。詳細は [LICENSE](LICENSE) を参照。
