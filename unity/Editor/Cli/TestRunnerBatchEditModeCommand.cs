#if TESTRUNNER_CLI_AVAILABLE
using System;
using System.Threading;
using System.Threading.Tasks;
using Unity.Pipeline;
using Unity.Pipeline.Commands;
using Unity.Pipeline.Editor.Testing;
using UnityEditor.TestTools.TestRunner.Api;
using UnityEngine;

namespace TestRunnerCli
{
    /// <summary>複数の完全名(FullName)をまとめてEditModeで実行するPipelineコマンド。</summary>
    public static class TestRunnerBatchEditModeCommand
    {
        [CliCommand("run_tests_batch_editmode", "複数の完全名(FullName)をカンマ区切りで受け取り、1回のExecuteでEditModeテストをまとめて実行する", MainThreadRequired = true, Tags = new[] { "tests" })]
        public static async Task<TestExecutionResponse> RunTestsBatchEditMode(
            [CliArg("full_names", "実行する完全名(FullName)のカンマ区切りリスト", Required = true)] string fullNames,
            [CliArg("timeout", "テスト実行タイムアウト秒(既定300)")] int timeout = 300)
        {
            var names = TestRunnerCliUtility.ParseFullNames(fullNames);
            if (names.Length == 0)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_batch_editmode",
                    "full_namesが空です。カンマ区切りの完全名を1件以上指定してください。");
            }

            var startTime = DateTime.UtcNow;
            var api = ScriptableObject.CreateInstance<TestRunnerApi>();
            var collector = new TestResultCollector();

            try
            {
                var tcs = new TaskCompletionSource<ITestResultAdaptor>();
                collector.OnRunFinished = () => tcs.TrySetResult(collector.RootResult);

                api.RegisterCallbacks(collector);
                api.Execute(new ExecutionSettings(new Filter
                {
                    testMode = TestMode.EditMode,
                    testNames = names
                }));

                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout)))
                using (cts.Token.Register(() =>
                       {
                           collector.Cancel();
                           tcs.TrySetCanceled();
                       }))
                {
                    var rootResult = await tcs.Task;
                    var duration = (DateTime.UtcNow - startTime).TotalSeconds;
                    return TestRunnerCliUtility.BuildSuccessResponse("run_tests_batch_editmode", "EditMode", duration, names, collector, rootResult);
                }
            }
            catch (TaskCanceledException)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_batch_editmode",
                    $"テスト実行が{timeout}秒でタイムアウトしました。");
            }
            finally
            {
                api.UnregisterCallbacks(collector);
            }
        }
    }
}
#endif
