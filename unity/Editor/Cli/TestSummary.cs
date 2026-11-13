#if TESTRUNNER_CLI_AVAILABLE
using System;
using Newtonsoft.Json;

namespace TestRunnerCli
{
    /// <summary>テスト実行結果の集計。com.unity.pipeline 0.6.0-exp.1 で
    /// <c>Unity.Pipeline.TestSummary</c> がinternal化されたため、同等のモデルを本パッケージ側で持つ。
    /// JSONのキーは com.unity.pipeline 1.0 の test status と同じ camelCase。</summary>
    [Serializable]
    public sealed class TestSummary
    {
        /// <summary>実行したテストの総数。</summary>
        [JsonProperty("total")]
        public int Total { get; set; }
        /// <summary>成功した数。</summary>
        [JsonProperty("passed")]
        public int Passed { get; set; }
        /// <summary>失敗した数。</summary>
        [JsonProperty("failed")]
        public int Failed { get; set; }
        /// <summary>スキップされた数。</summary>
        [JsonProperty("skipped")]
        public int Skipped { get; set; }
        /// <summary>実行されたが判定が付かなかった数。</summary>
        [JsonProperty("inconclusive")]
        public int Inconclusive { get; set; }
    }
}
#endif
