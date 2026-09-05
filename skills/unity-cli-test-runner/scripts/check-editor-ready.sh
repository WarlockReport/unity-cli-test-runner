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
#      または未接続の場合を含む。Unity未起動または未接続。ドメインリロード中の一時的な切断は
#      リトライ予算15秒以内で自動リトライ済みのため、ここに到達した場合は本当に未起動/未接続の
#      可能性が高い）
#   3  応答は得られたが、想定した形状(.data.result.status)でパースできなかった（防御的フォールバック。
#      標準出力の生JSONを確認して手動判断する）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "${SCRIPT_DIR}/_lib.sh"

PROJECT_PATH="${1:-}"
CLI_TIMEOUT=30
ONESHOT_RETRY_BUDGET_SECONDS=15

# `unity cmd` は対象エディタに接続できない場合、非ゼロ終了する。出力（JSON）は得られるので、
# CLI呼び出し自体の失敗を出力の中身で判定するため、終了コード無視で出力を取得する。
# ドメインリロード中は一時的にPipelineサーバーが不通になる（_lib.sh参照）ため、
# その間だけは「未起動」と即断せず有限のリトライ予算内でリトライする。
if [ -n "$PROJECT_PATH" ]; then
  raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" editor_status --project-path "$PROJECT_PATH" --json 2>/dev/null || true)"
else
  raw="$(run_unity_cmd_resilient "$CLI_TIMEOUT" "$ONESHOT_RETRY_BUDGET_SECONDS" editor_status --json 2>/dev/null || true)"
fi

# 出力が完全に空なら、CLI呼び出し自体が失敗したか、応答前にタイムアウトした。
# 後者はモーダルダイアログによるメインスレッドブロックでも起こるため、下の判別へ回せるよう
# 空のJSONを詰めて処理を続ける（success != "true" の枝で判別する）。
if [ -z "$raw" ]; then
  raw='{"success":false,"errors":[{"message":"editor_status の応答が得られませんでした（タイムアウトの可能性）"}]}'
fi

success="$(echo "$raw" | jq -r '.success // empty' 2>/dev/null || true)"

if [ "$success" != "true" ]; then
  message="$(echo "$raw" | jq -r '.errors[0].message // empty' 2>/dev/null || true)"

  # editor_status は MainThreadRequired なので、モーダルダイアログでエディタのメインスレッドが
  # 塞がっていると「未起動」と区別が付かない形で失敗する（実測: Unity 6000.3.14f1 +
  # com.unity.pipeline 0.6.0-exp.1 では 503 busy ではなく単にタイムアウトする。0.6 の
  # blocked_by_dialog 検出は「recent enough trunk build」が前提で、この版には入っていない）。
  # メインスレッド不要のコマンドが応答するかどうかで両者を判別する。
  #   応答する = Pipelineサーバーは生きている → メインスレッドだけが塞がれている（ダイアログ）
  #   応答しない = 本当に未起動/未接続
  if run_unity_cmd_capture recompile_status --json --timeout "$CLI_TIMEOUT" >/dev/null 2>&1 &&
     [ "$(echo "$UNITY_CMD_OUT" | jq -r '.success // empty' 2>/dev/null || true)" = "true" ]; then
    echo "エディタは起動していますが、メインスレッドが塞がっています（editor_status は失敗する一方、メインスレッド不要の recompile_status は正常応答しました）。" >&2
    echo "モーダルダイアログが開いたままになっている可能性が高いです。Unityエディタを確認し、開いているダイアログを閉じてもらってください（エディタの再起動は不要です）。${message:+（editor_statusの詳細: ${message}）}" >&2
    echo "$raw"
    exit 1
  fi

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
