# ADR-0021: 「ensure-compile-clean.sh が get_console_logs を呼んで exit 2 で止まる」報告への対応

## Status

Accepted (2026-10-15)

## Context

- プラグインの最新版が 0.5.0 だった期間に、複数の利用プロジェクトから「`ensure-compile-clean.sh` の最終段が、
  今の CLI に存在しない `get_console_logs` を呼んで失敗し、コンパイルが成功していても終了コード 2 で止まる」という
  報告があった。報告元では、プラグインのインストールは今週（2026-10-12 の週）に入ってからだったとのこと
- 0.5.0 と現行版の `ensure-compile-clean.sh` は `get_console_logs` を呼ばない。コンパイル成否の判定は
  `recompile_status` で行い、`console` はコンパイルエラーを検出したときの詳細取得にだけ使う（ADR-0015・ADR-0016）。
  `get_console_logs` を最終段で呼んでいたのは、`com.unity.pipeline` 0.7 で同コマンドが削除される前の
  プラグイン 0.3.x である
- 開発者の手元の利用プロジェクト 2 つのセッションログ（サブエージェントを含む 593 ファイル）を解析したところ、
  `ensure-compile-clean.sh` の出力に `get_console_logs` が現れるのは 2026-09-17〜20 の実行だけで、0.5.0 公開
  （2026-10-04）以降の実行 305 件には、`get_console_logs` の呼び出しも終了コード 2 も無かった
- サードパーティのマーケットプレイスは自動更新が既定で無効で、Claude Code は登録時に複製したマーケットプレイスを
  明示的に更新するまで使い続ける

## 実地検証（再現）

実地検証済み（2026-10-15、Claude Code 2.1.300、`CLAUDE_CONFIG_DIR` で隔離した環境）。

- 一時ブランチを 0.3.2 の時点で push し、`claude plugin marketplace add 'WarlockReport/unity-cli-test-runner#<一時ブランチ>'`
  で登録だけを行った。その後、一時ブランチを現在の main（0.6.0）まで進めた
- マーケットプレイスを更新せずに `claude plugin install` を実行すると、**0.3.2 が入った**（`get_console_logs` を
  9 か所で使うスクリプト）。インストールした日付に関係なく、マーケットプレイスを登録した時点の版が入る
- この状態で `claude plugin update` だけを実行すると、「already at the latest version (0.3.2)」と表示され、更新されなかった
- `claude plugin marketplace update` の後に `claude plugin update` を実行すると、0.6.0 に更新され、
  `get_console_logs` の呼び出しは無くなった
- 一時ブランチは検証後に削除した

## Decision

- 報告の症状は、以前（0.3.x の時期）に登録したマーケットプレイスの古い複製から、今週プラグインをインストールした
  ことによるものと判断し、スクリプトは変更しない
- README に、マーケットプレイスの複製が古いままだと新規インストールでも古い版が入ること、`claude plugin update`
  だけでは更新されないこと、マーケットプレイスの更新を先に行う手順、自動更新の有効化の方法、導入済みの版の確認方法
  （`claude plugin details wr-unity-cli-tools`）、古い版のまま使い続けた場合のこの症状を書く

## Consequences

- 同じ症状に遭遇した利用者が、README から原因（古いマーケットプレイスの複製）と対処（マーケットプレイスの更新を先に
  行ってからプラグインを更新する）にたどり着ける
- 報告元の環境で実際に導入されていた版は未確認（後日確認する）。0.3.x 以外の版で再現した場合は、この判断を見直す
