#if TESTRUNNER_CLI_AVAILABLE
using System;
using System.Collections.Generic;
using Unity.Pipeline.Models;

namespace TestRunnerCli
{
    /// <summary>テスト実行コマンドの戻り値。com.unity.pipeline 0.6.0-exp.1 で
    /// <c>Unity.Pipeline.TestExecutionResponse</c> がinternal化されたため、同等のモデルを
    /// 本パッケージ側で持つ（ADR-0012）。基底の <see cref="CommandExecutionResponse"/> は
    /// 0.6でもpublicのままなので、公式ドキュメント（Documentation~/creating-commands.md）が
    /// 正規の作法として挙げる「CommandExecutionResponseを継承した独自モデルを返す」形に沿う。
    ///
    /// パッケージ本体の同名型が持つ <c>StatusPath</c> は、本パッケージが独自のステータスファイル
    /// （Temp/testrunner_cli_batch_status.json、batch_test_statusで取得）を使うため持たない。</summary>
    [Serializable]
    public sealed class TestExecutionResponse : CommandExecutionResponse
    {
        /// <summary>実行結果の集計。</summary>
        public TestSummary Summary { get; set; }
        /// <summary>個々のテスト結果。</summary>
        public List<TestResult> Results { get; set; }
        /// <summary>実行全体の所要時間（秒）。</summary>
        public double Duration { get; set; }
        /// <summary>実行したモード。EditMode または PlayMode。</summary>
        public string Mode { get; set; }
        /// <summary>適用したフィルタの内容。</summary>
        public string FilterApplied { get; set; }

        /// <summary>コレクションを初期化した空のレスポンスを作る。</summary>
        public TestExecutionResponse()
        {
            Results = new List<TestResult>();
            Summary = new TestSummary();
        }
    }
}
#endif
