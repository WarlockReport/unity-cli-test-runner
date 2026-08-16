# unity-cli-test-runner

[Unity CLI](https://docs.unity.com/en-us/unity-cli/unity-cli) と [Unity Pipeline package](https://docs.unity3d.com/Packages/com.unity.pipeline@0.5/manual/index.html) を使用して、コード修正後に指定したテストを実行するための Claude Code プラグインです。

対象 Unity プロジェクト側に導入する Unity Editor 拡張（UPMパッケージ）と、Claude Code 側のスキル・専用サブエージェントの 2 つで構成されています。

## 前提条件

- `unity` CLI と `jq` が PATH 上にあること
- 対象Unityプロジェクトに `com.unity.pipeline` パッケージ（0.5.0-exp.1）が導入済みであること

## インストール

### 1. Claude Codeプラグイン

```
/plugin marketplace add WarlockReport/unity-cli-test-runner
/plugin install unity-cli-test-runner
```

スキル `unity-cli-test-runner` と専用サブエージェント `unity-test-runner` が使えるようになります。

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
