#!/usr/bin/env bash
#
# unity-cli-test-runner スキルの「0. エディタ起動確認」ステップを1コマンドにまとめる。
# `unity cmd editor_status --json` を実行し、起動中エディタが見つかり、状態が ready かどうかを
# 判定する。ensure-compile-clean.sh と同じ設計パターン（終了コードで状態を表現、jqでの解析）に揃える。
#
# 使い方: check-editor-ready.sh [プロジェクトパス(省略可)]
#
# 前提: `unity`（Pipelineサーバー経由で起動中エディタに接続するCLI）と `jq` がPATH上にあること。
#
# 第1引数は省略してよい（推奨: SKILL.mdのStep 0はリポジトリルートから引数なしで呼ぶ）。省略時は
# `unity cmd` 自身の自動検出に任せる。これはこのスキルの他スクリプト（ensure-compile-clean.sh等）が
# 既に依拠している機構であり、呼び出し元のカレントディレクトリ（リポジトリルート／Unityプロジェクトルート
# のどちらでも）に関わらず接続中のエディタを解決する。過去バージョンは `unity status --json` の
# 出力を自前でプロジェクトパス照合していたが、`$(pwd)` とUnityプロジェクトの実パスが一致しない
# 呼び出し（リポジトリルートからの引数なし呼び出し、まさにSKILL.mdの記載どおりの使い方）で
# 誤って「見つからない」と判定してしまう不具合があったため、`unity cmd editor_status` の自動検出に
# 一本化した。第1引数を渡した場合のみ `--project-path` として明示的に転送する（後方互換・明示指定用）。
#
# 終了コード:
#   0  `unity cmd editor_status` が成功し、状態(.data.result.status)が "ready"
#   1  `unity cmd editor_status` は成功したが、状態が "ready" 以外（生の値を標準出力に出す。
#      未知の状態値を決め打ちで再試行せず報告する）
#   2  `unity cmd editor_status` コマンド自体が失敗/タイムアウトした（起動中エディタが見つからない、
#      または未接続の場合を含む。Unity未起動または未接続）
#   3  応答は得られたが、想定した形状(.data.result.status)でパースできなかった（防御的フォールバック。
#      標準出力の生JSONを確認して手動判断する）

set -euo pipefail

PROJECT_PATH="${1:-}"

# `unity cmd` は対象エディタに接続できない場合、非ゼロ終了する。出力（JSON）は得られるので、
# CLI呼び出し自体の失敗を出力の中身で判定するため、終了コード無視で出力を取得する。
if [ -n "$PROJECT_PATH" ]; then
  raw="$(unity cmd editor_status --project-path "$PROJECT_PATH" --timeout 30 --json 2>/dev/null || true)"
else
  raw="$(unity cmd editor_status --timeout 30 --json 2>/dev/null || true)"
fi

# 出力が完全に空なら、本当のCLI呼び出し失敗（コマンド自体が実行できない等）
if [ -z "$raw" ]; then
  echo "unity cmd editor_status の実行に失敗しました。" >&2
  exit 2
fi

success="$(echo "$raw" | jq -r '.success // empty' 2>/dev/null || true)"

if [ "$success" != "true" ]; then
  message="$(echo "$raw" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"
  echo "unity cmd editor_status が失敗しました。起動中エディタが見つからないか、未接続です。${message:+（詳細: ${message}）}" >&2
  echo "$raw"
  exit 2
fi

state="$(echo "$raw" | jq -r '.data.result.status // empty' 2>/dev/null || true)"

if [ -z "$state" ]; then
  echo "unity cmd editor_status の応答形式が想定と異なり、状態を判定できませんでした。以下の生JSONを確認してください:" >&2
  echo "$raw"
  exit 3
fi

if [ "$state" != "ready" ]; then
  echo "起動中エディタは見つかりましたが、status が 'ready' ではありません（現在: ${state}）。" >&2
  exit 1
fi

echo "起動中エディタが見つかり、status は ready です。次のステップ（コンパイル状態の確定）へ進んでよい。" >&2
exit 0
