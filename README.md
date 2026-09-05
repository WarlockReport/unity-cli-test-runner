# unity-cli-test-runner

[Unity CLI](https://docs.unity.com/en-us/unity-cli/unity-cli) と [Unity Pipeline package](https://docs.unity3d.com/Packages/com.unity.pipeline@0.6/manual/index.html) を使用して、コード修正後に指定したテストを実行するための Claude Code プラグインです。

対象 Unity プロジェクト側に導入する Unity Editor 拡張（UPMパッケージ）と、Claude Code 側のスキル・専用サブエージェントの 2 つで構成されています。

## 前提条件

- `unity` CLI と `jq` が PATH 上にあること
- 対象Unityプロジェクトに `com.unity.pipeline` パッケージ（**0.6.0-exp.1 以降**）が導入済みであること。
  0.5.0-exp.1 以前には対応していない（0.6でパッケージ内部の型が `internal` 化されたため。詳細は [ADR-0012](docs/decisions/0012-vendor-pipeline-internal-types.md)）

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

### 2. Unity側パッケージ

対象Unityプロジェクトの Package Manager → `+` → `Add package from git URL...` に以下を入力します。

```
https://github.com/WarlockReport/unity-cli-test-runner.git?path=/unity
```

詳細は [`unity/README.md`](unity/README.md) を参照。

## 構成

```
.claude-plugin/    Claude Codeプラグイン・マーケットプレイスmanifest
skills/            unity-cli-test-runner スキル本体（SKILL.md・スクリプト）
agents/            テスト実行専用サブエージェント定義
unity/             Unity側UPMパッケージ（Editor拡張）
```

## 参考資料

- [The Unity Pipeline package and Unity CLI: Installation guide and walkthrough](https://unity.com/resources/unity-pipeline-cli-technical-walkthrough)

## ライセンス

MIT。詳細は [LICENSE](LICENSE) を参照。
