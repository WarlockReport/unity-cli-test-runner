#if TESTRUNNER_CLI_AVAILABLE
using System;
using System.Collections.Generic;
using System.Linq;
using Unity.Pipeline;
using Unity.Pipeline.Editor.Testing;
using UnityEditor.TestTools.TestRunner.Api;

namespace TestRunnerCli
{
    /// <summary>run_tests_batch_editmode/run_tests_batch_playmode共通のフルネーム解析・
    /// レスポンス組み立てヘルパー。ロジックは持たず、パッケージのpublicモデルを組み立てるだけ。</summary>
    internal static class TestRunnerCliUtility
    {
        internal static string[] ParseFullNames(string fullNames)
        {
            if (string.IsNullOrWhiteSpace(fullNames))
            {
                return Array.Empty<string>();
            }

            return fullNames
                .Split(',')
                .Select(name => name.Trim())
                .Where(name => name.Length > 0)
                .ToArray();
        }

        internal static TestExecutionResponse CreateErrorResponse(string command, string message)
        {
            return new TestExecutionResponse
            {
                Success = false,
                Command = command,
                Error = message,
                ExecutedAt = DateTime.UtcNow
            };
        }

        internal static TestExecutionResponse BuildSuccessResponse(
            string command,
            string mode,
            double duration,
            string[] names,
            TestResultCollector collector,
            ITestResultAdaptor rootResult)
        {
            return new TestExecutionResponse
            {
                Success = true,
                Command = command,
                Mode = mode,
                Duration = Math.Round(duration, 2),
                Summary = new TestSummary
                {
                    Total = rootResult.PassCount + rootResult.FailCount + rootResult.SkipCount + rootResult.InconclusiveCount,
                    Passed = rootResult.PassCount,
                    Failed = rootResult.FailCount,
                    Skipped = rootResult.SkipCount,
                    Inconclusive = rootResult.InconclusiveCount
                },
                Results = collector.Results,
                Message = BuildMissingNamesMessage(names, collector),
                ExecutedAt = DateTime.UtcNow
            };
        }

        /// <summary>要求した完全名(FullName)のうち、結果に一件も現れなかったものを列挙したメッセージを
        /// 組み立てる。全件一致した場合はnullを返す（正常系にノイズを追加しない）。</summary>
        private static string BuildMissingNamesMessage(string[] names, TestResultCollector collector)
        {
            if (names == null || names.Length == 0)
            {
                return null;
            }

            var matchedFullNames = new HashSet<string>(collector.Results.Select(result => result.FullName));

            var missingNames = names
                .Where(name => !matchedFullNames.Contains(name))
                .ToArray();

            if (missingNames.Length == 0)
            {
                return null;
            }

            return $"要求した{names.Length}件のうち{missingNames.Length}件が見つかりませんでした: {string.Join(", ", missingNames)}";
        }
    }
}
#endif
