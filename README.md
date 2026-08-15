# unity-cli-test-runner

Unity CLI（`unity cmd`、Pipelineサーバー経由で起動中のUnityエディタに接続するCLI）を使って、
コード修正後のEditMode/PlayModeテストを絞り込み実行するためのClaude Codeプラグイン。

対象Unityプロジェクト側に導入するUnity Editor拡張（UPMパッケージ）と、
Claude Code側のスキル・専用サブエージェントの2つで構成される。

## 前提条件

- `unity` CLI と `jq` が PATH 上にあること
- 対象Unityプロジェクトに `com.unity.pipeline` パッケージ（0.5.0-exp.1）が導入済みであること

## インストール

### 1. Claude Codeプラグイン

```
/plugin marketplace add WarlockReport/unity-cli-test-runner
/plugin install unity-cli-test-runner
```

スキル `unity-cli-test-runner` と専用サブエージェント `unity-test-runner` が使えるようになる。

### 2. Unity側パッケージ

対象Unityプロジェクトの Package Manager → `+` → `Add package from git URL...` に以下を入力する。

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

## ライセンス

MIT。詳細は [LICENSE](LICENSE) を参照。
