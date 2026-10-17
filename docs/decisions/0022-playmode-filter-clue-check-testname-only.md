# ADR-0022: PlayMode 実行の filter 文字列の整合性チェックを `testName` 指定時だけに限る

## Status

Accepted (2026-10-17)

## Context

- スキルを利用しているプロジェクトから、PlayMode のアセンブリ全体の実行（`run-playmode-test.sh <アセンブリ名> assembly`）で
  `run-playmode-test.sh` が exit 3（「test_statusの結果に指定filter「…」の手がかりが見当たりません」）を返したと報告があった。
  実行件数は `list_tests` で数えた件数と一致し、`summary` と `results` の集計にも食い違いはなかった。報告元では、
  この exit 3 が以前から繰り返し出ていた
- `run-playmode-test.sh` は最後に、`test_status` の生 JSON に filter 文字列がそのまま含まれるかを `grep -F` で確かめ、
  含まれなければ「異なる filter への取り違えの疑い」として exit 3 にしていた
- `com.unity.pipeline` 0.8.0-exp.1 の `PipelineTestRunner.WriteCompletedResults` がステータスファイルに書くのは
  `status` / `duration` / `summary` / `results` だけで、filter 自体は含まれない（`FilterApplied` は同期実行のレスポンスにしか付かない）。
  手がかりになり得るのは `results[].FullName`（名前空間.クラス.メソッド）だけである
- そのため、filter 種別ごとに次のようになる
  - `assembly`: アセンブリ名と名前空間が一致しないプロジェクトでは、正常な結果でも必ず exit 3 になる。
    TestProject の固定台（`Fixtures.PlayMode`）はアセンブリ名と `rootNamespace` が同じだったため、これまで表面化しなかった
  - `category`: カテゴリ名は結果に現れないため、必ず exit 3 になる
  - `testName`: Unity は大文字小文字を区別しない部分一致で照合する（ADR-0020）のに対し、`grep -F` は区別するため、
    表記揺れだけで exit 3 になり得る
- ADR-0020 で `run-playmode-test.sh` の用途がアセンブリ全体の実行に限られたため、スキルの手順で PlayMode のアセンブリ全体を
  実行するたびにこの誤判定に当たる状態になっていた
- 古い結果の取り違えは、その手前のベースライン比較（`run_tests` 発行直前の `test_status` と完全一致するか）で、
  filter の種類によらず検知できる。filter 文字列のチェックだけが拾えるのは、ベースライン取得後に別の実行が割り込んだ場合に限られる

## Decision

- filter 文字列のチェックは `--filter_type testName` のときだけ行い、`grep -qiF`（大文字小文字を区別しない）で照合する
- `assembly` / `category` のときはチェックを省き、省いたことを標準エラーに出す。古い結果の検知はベースライン比較に任せる
- `list_tests` の `Assembly` を使って結果の `FullName` の所属を照合する案は採らない。`list_tests` の呼び出しが 1 回増えるわりに、
  ベースライン比較に対して上乗せできる検知範囲が小さいため
- 回帰テスト（モック）に、アセンブリ名が結果に現れない `assembly` 指定・大文字小文字違いの `testName` 指定が exit 0 になること、
  手がかりの無い `testName` 指定が引き続き exit 3 になることのケースを加える
- TestProject にアセンブリ名（`Fixtures.NamespaceMismatch.PlayMode`）と名前空間（`MismatchFixtures`）が一致しない PlayMode の
  固定台を加え、E2E の段階 7 でそのアセンブリ全体の実行を照合する
- UPM パッケージは変更しない。プラグインの版を 0.7.0 → 0.7.1 に上げる

## Consequences

- PlayMode のアセンブリ全体の実行で、正常な結果が exit 3 にならなくなる
- `assembly` / `category` 指定では、ベースライン取得後に別の実行が割り込んで結果が差し替わった場合を検知できなくなる。
  スキルはテスト実行の主体をコントローラーか専用サブエージェントに限っており、同時実行は想定していない
- 終了コード 3 の意味（結果が信用できない）は変わらないため、SKILL.md の手順・報告ルールは変更しない
