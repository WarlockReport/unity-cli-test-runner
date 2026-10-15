# ADR-0021: 「ensure-compile-clean.sh が get_console_logs を呼んで exit 2 で止まる」報告への対応

## Status

Accepted (2026-10-15)

## Context

- プラグインの最新版が 0.5.0 だった期間に、複数の利用プロジェクトから「`ensure-compile-clean.sh` の最終段が、
  今の CLI に存在しない `get_console_logs` を呼んで失敗し、コンパイルが成功していても終了コード 2 で止まる」という
  報告があった
- 0.5.0 と現行版の `ensure-compile-clean.sh` は `get_console_logs` を呼ばない。コンパイル成否の判定は
  `recompile_status` で行い、`console` はコンパイルエラーを検出したときの詳細取得にだけ使う（ADR-0015・ADR-0016）。
  `get_console_logs` を最終段で呼んでいたのは、`com.unity.pipeline` 0.7 で同コマンドが削除される前の
  プラグイン 0.3.x である
- 開発者の手元の利用プロジェクト 2 つのセッションログ（サブエージェントを含む 593 ファイル）を解析したところ、
  `ensure-compile-clean.sh` の出力に `get_console_logs` が現れるのは 2026-09-17〜20 の実行だけで、0.5.0 公開
  （2026-10-04）以降の実行 305 件には、`get_console_logs` の呼び出しも終了コード 2 も無かった
- サードパーティのマーケットプレイスは自動更新が既定で無効で、明示的に更新しない限り導入時点の版のキャッシュが
  使われ続ける

## Decision

- 報告の症状は、利用者の環境で古いプラグイン（0.3.x）が動いていたことによるものと判断し、スクリプトは変更しない
- README に、プラグインの更新手順（`claude plugin marketplace update` → `claude plugin update`）、自動更新の
  有効化の方法、導入済みの版の確認方法（`claude plugin details wr-unity-cli-tools`）、古い版のまま使い続けた場合の
  この症状を書く

## Consequences

- 同じ症状に遭遇した利用者が、README から原因（古い版）と対処（更新）にたどり着ける
- 報告元の環境で実際に導入されていた版は未確認（後日確認する）。確認の結果、0.5.0 以降で再現した場合は、
  この判断を見直す
