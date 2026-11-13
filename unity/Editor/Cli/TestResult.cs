#if TESTRUNNER_CLI_AVAILABLE
using System;
using Newtonsoft.Json;

namespace TestRunnerCli
{
    /// <summary>個々のテスト結果。com.unity.pipeline 0.6.0-exp.1 で
    /// <c>Unity.Pipeline.TestResult</c> がinternal化されたため、同等のモデルを本パッケージ側で持つ。
    /// JSONのキーは com.unity.pipeline 1.0 の test status と同じ camelCase にそろえる
    /// （スクリプトが本体のテストと自前コマンドの結果を同じ形で読めるようにするため）。</summary>
    [Serializable]
    public sealed class TestResult
    {
        /// <summary>テストの完全名(FullName)。</summary>
        [JsonProperty("fullName")]
        public string FullName { get; set; }
        /// <summary>結果。Passed / Failed / Skipped / Inconclusive のいずれか。</summary>
        [JsonProperty("status")]
        public string Status { get; set; }
        /// <summary>所要時間（秒）。</summary>
        [JsonProperty("duration")]
        public double Duration { get; set; }
        /// <summary>失敗時のメッセージ。</summary>
        [JsonProperty("message")]
        public string Message { get; set; }
        /// <summary>失敗時のスタックトレース。</summary>
        [JsonProperty("stackTrace")]
        public string StackTrace { get; set; }
    }
}
#endif
