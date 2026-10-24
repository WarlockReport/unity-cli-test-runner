# ADR-0024: プラグインと Unity 側パッケージの版番号を揃え、`com.unity.pipeline` の版に合わせる

## Status

Accepted (2026-10-24)

## Context

- `com.unity.pipeline` は experimental で、版ごとに破壊的な変更が入る（0.6 の型の `internal` 化、0.7 の
  `get_console_logs` 削除、0.8 の属性のアセンブリ移動、0.9 のコマンドのグループ化と全面改名）。こちらが新しい版へ
  対応すると、`main` は古い版の Pipeline では動かなくなる
- それまで git タグを 1 つも打っていなかったため、利用者は古い版の Pipeline 向けの状態に固定する手段が無かった
- 版番号が 2 系統あった（プラグイン 0.7.1、Unity 側パッケージ 0.4.0）。両者は `unity cmd` のコマンド名・引数・
  応答の形で結合しているのに、どの組み合わせが正しいかを版番号から読み取れなかった
- 固定の手段は両方とも git の ref で用意されている
  - プラグイン: `/plugin marketplace add <owner>/<repo>#<ref>` でマーケットプレイスを ref に固定できる。プラグインの
    `source` は相対パス（`./claude-plugin`）なので、プラグイン本体も同じ ref のチェックアウトから取り出される
  - Unity 側パッケージ: git URL の末尾 `?path=/unity#<ref>` で固定できる

## Decision

- プラグイン（`plugin.json`・`marketplace.json`）と Unity 側パッケージ（`unity/package.json`）の版番号を常に同じ値にする
- 版の major.minor を、対応する `com.unity.pipeline` の major.minor に合わせる。patch はこのリポジトリ側の修正番号とし、
  Pipeline の patch には合わせない（Pipeline の patch に合わせると、同じ Pipeline 版に対する自前の修正を出す番号が無くなり、
  次の番号が存在しない Pipeline 版を指しているように見えるため）
- リリースごとに、両方を含むコミットへ共通の git タグ `vX.Y.Z` を打ち、GitHub Release を作る
- README に「Pipeline の版 → 使うタグ」の対応表と、両方を同じタグに固定するインストール手順を載せる
- 0.8 系の最初のリリースとして、プラグイン 0.7.1・Unity 側パッケージ 0.4.0 と同じ内容のまま、両方の版を 0.8.0 に上げて
  `v0.8.0` を打つ。0.9 系への対応はこのタグの後に始める

## Consequences

- 利用者は Pipeline の版から使うタグを 1 つ選び、プラグインと Unity 側パッケージをそのタグに固定すれば、こちらが新しい
  Pipeline 版へ対応した後も動作を維持できる
- Unity 側パッケージは 0.4.0 から 0.8.0 へ番号が飛ぶ。プラグインも 0.7.1 から 0.8.0 へ上がる。どちらも番号は戻らないので、
  更新検知（版の比較）は従来どおり働く
- 片方だけを変更するリリースでも、もう片方の版を同じ値へ上げる（版の更新は常に 3 箇所を揃える）
- 固定先のタグを変えるには、マーケットプレイスを削除して登録し直す必要がある（同じ名前で 2 つ登録できないため）
- Pipeline の版が 1.0 を超えた場合も同じ規則（major.minor を合わせる）を続ける
