# unity-cli-test-runner

[Unity CLI](https://docs.unity.com/en-us/unity-cli/unity-cli) と [Unity Pipeline package](https://docs.unity3d.com/Packages/com.unity.pipeline@0.9/manual/index.html) を使用して、コード修正後に指定したテストを実行するための Claude Code プラグインです。

対象 Unity プロジェクト側に導入する Unity Editor 拡張（UPMパッケージ）と、Claude Code 側のスキル・専用サブエージェントの 2 つで構成されています。

## 前提条件

- `unity` CLI と `jq` が PATH 上にあること（`unity` CLI は 1.0.0-beta.13 で検証。`unity cmd <グループ> <コマンド>` の
  形でコマンドを転送できる版が必要）
- 対象 Unity プロジェクトが **Unity 6000.3（LTS）** であること。対象とする Unity は LTS の版に限り、現在は 6000.3 だけで検証している
- 対象Unityプロジェクトに `com.unity.pipeline` パッケージ（**0.9.0-exp.1 以降**）が導入済みであること。
  0.9 でコマンドが「グループ + 名前」に再編され、旧名では実行できなくなったため、0.8 以前には対応していない
  （詳細は [ADR-0025](docs/decisions/0025-pipeline-0.9-only.md)）。**0.8 を使い続ける場合は、プラグインと
  Unity 側パッケージの両方を `v0.8.0` に固定してください**（[版番号と対応する `com.unity.pipeline`](#版番号と対応する-comunitypipeline)）。
  0.7 以前を切った経緯は [ADR-0016](docs/decisions/0016-pipeline-0.8-only.md)・
  [ADR-0015](docs/decisions/0015-pipeline-0.7-only.md)・[ADR-0012](docs/decisions/0012-vendor-pipeline-internal-types.md)

## 版番号と対応する `com.unity.pipeline`

Claude Code プラグインと Unity 側パッケージは同じ版番号で揃えており、リリースごとに共通の git タグ `vX.Y.Z` を打っています。
版の前 2 桁（major.minor）は対応する `com.unity.pipeline` の版を、末尾（patch）はこのリポジトリ側の修正番号を表します。
`com.unity.pipeline` には破壊的な変更が入ることがあるため、使っている版に合うタグに両方を固定しておくと、
こちらが新しい版へ対応したあとも動作を維持できます（手順は [版を固定してインストールする](#版を固定してインストールする)）。

| `com.unity.pipeline` | 使うタグ |
| --- | --- |
| 0.9.x | `v0.9.0` |
| 0.8.x | `v0.8.0` |

プラグインと Unity 側パッケージは、必ず同じタグに揃えてください（両者は `unity cmd` のコマンド名・引数・応答の形で結合しています）。
3 つの版（プラグイン・Unity 側パッケージ・`com.unity.pipeline`）が揃っていないと、スクリプトは「版の組み合わせが揃っていない
可能性」という診断を出して終了コード 3 で止まります。

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

このマーケットプレイスの自動更新は既定で無効です。Claude Code はマーケットプレイスを登録した時点の内容を
手元に複製して使い、明示的に更新しない限りその複製は古いままです。そのため、**以前にマーケットプレイスを登録して
いた環境では、新しくインストールした場合でも、登録した時点の古い版が入ります**。
また、マーケットプレイスを更新しないまま `claude plugin update` だけを実行しても、
古い複製と比べて「最新版です」と表示され、更新されません。

インストール・更新の前と、`com.unity.pipeline` の版を上げたときは、**必ずマーケットプレイスの更新を先に**行ってください
（シェルで実行し、その後 Claude Code のセッションで `/reload-plugins` を実行するか、セッションを開き直します）。

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

### 版を固定してインストールする

上の手順はどちらも既定ブランチの最新を入れます。特定の版に固定するには、
[対応表](#版番号と対応する-comunitypipeline) で選んだタグ（以下は `v0.9.0` の例）を両方に付けます。

プラグインは、マーケットプレイスの登録時に `#<タグ>` を付けます。プラグイン本体はマーケットプレイスと同じリポジトリから
取り出されるため、これでプラグインもそのタグの版に固定されます。

```
/plugin marketplace add WarlockReport/unity-cli-test-runner#v0.9.0
/plugin install wr-unity-cli-tools
```

Unity 側パッケージは、git URL の末尾に `#<タグ>` を付けます（`Packages/manifest.json` に直接書いてもかまいません）。

```
https://github.com/WarlockReport/unity-cli-test-runner.git?path=/unity#v0.9.0
```

固定先のタグを変えるときは、マーケットプレイスは同じ名前で 2 つ登録できないため、一度削除してから新しいタグで登録し直します
（削除するとプラグインもアンインストールされるので、登録後に `/plugin install` をやり直します）。

```
claude plugin marketplace remove wr-unity-cli-tools-dev
claude plugin marketplace add WarlockReport/unity-cli-test-runner#<新しいタグ>
claude plugin install wr-unity-cli-tools@wr-unity-cli-tools-dev
```

Unity 側パッケージは、git URL の `#<タグ>` を書き換えます。

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
