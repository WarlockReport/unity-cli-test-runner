#if TESTRUNNER_CLI_AVAILABLE
using System;

namespace TestRunnerCli
{
    /// <summary>テスト実行結果の集計。com.unity.pipeline 0.6.0-exp.1 で
    /// <c>Unity.Pipeline.TestSummary</c> がinternal化されたため、同等のモデルを本パッケージ側で持つ
    /// （ADR-0012）。</summary>
    [Serializable]
    public sealed class TestSummary
    {
        /// <summary>実行したテストの総数。</summary>
        public int Total { get; set; }
        /// <summary>成功した数。</summary>
        public int Passed { get; set; }
        /// <summary>失敗した数。</summary>
        public int Failed { get; set; }
        /// <summary>スキップされた数。</summary>
        public int Skipped { get; set; }
        /// <summary>実行されたが判定が付かなかった数。</summary>
        public int Inconclusive { get; set; }
    }
}
#endif
