#if TESTRUNNER_CLI_AVAILABLE
using System;

namespace TestRunnerCli
{
    /// <summary>個々のテスト結果。com.unity.pipeline 0.6.0-exp.1 で
    /// <c>Unity.Pipeline.TestResult</c> がinternal化されたため、同等のモデルを本パッケージ側で持つ
    /// （ADR-0012）。フィールド名はパッケージ本体と一致させてあり、JSONの形は0.5時代と変わらない。</summary>
    [Serializable]
    public sealed class TestResult
    {
        /// <summary>テストの完全名(FullName)。</summary>
        public string FullName { get; set; }
        /// <summary>結果。Passed / Failed / Skipped / Inconclusive のいずれか。</summary>
        public string Status { get; set; }
        /// <summary>所要時間（秒）。</summary>
        public double Duration { get; set; }
        /// <summary>失敗時のメッセージ。</summary>
        public string Message { get; set; }
        /// <summary>失敗時のスタックトレース。</summary>
        public string StackTrace { get; set; }
    }
}
#endif
