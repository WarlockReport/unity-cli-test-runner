# ADR-0001: Unity MCP経由からCLI経由への移行

## Status

Accepted

## Context

当初は unity-mcp-test-runner（Unity MCP経由）を利用していたが、以下の理由でCLI経由へ移行した。

- MCP固有の制約
  - ドメインリロード前提の設計になっている
  - 結果ファイルの置き場所に問題がある
  - `Filter.groupNames` が動作しない
- ライセンス費用の問題（MCP利用のみでもサブスクリプションが必要）

## Decision

CLI経由（unity-cli-test-runner）へ移行する。

## Consequences

以降のADR（[ADR-0002](0002-playmode-invalidoperationexception-accumulation.md)、
[ADR-0003](0003-ensure-compile-clean-json-field-names.md)、
[ADR-0004](0004-domain-reload-transient-failures.md)、
[ADR-0005](0005-subagent-nested-invocation-completion-routing.md)、
[ADR-0006](0006-batch-test-execution.md)）はすべてCLI経由の利用を前提とする。