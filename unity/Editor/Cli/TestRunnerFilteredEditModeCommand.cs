#if TESTRUNNER_CLI_AVAILABLE
using System;
using System.Threading;
using System.Threading.Tasks;
using Unity.Pipeline.Commands;
using UnityEditor.TestTools.TestRunner.Api;
using UnityEngine;

namespace TestRunnerCli
{
    /// <summary>アセンブリ・カテゴリ・除く完全名で絞り込んで EditMode で実行する Pipeline コマンド。</summary>
    public static class TestRunnerFilteredEditModeCommand
    {
        [CliCommand("wr.testrunner", "run_tests_filtered_editmode", "アセンブリ・含めるカテゴリ・除くカテゴリ・除く完全名(FullName)を組み合わせて絞り込み、1回のExecuteでEditModeテストを実行する。名前・カテゴリ・アセンブリはすべて完全一致で照合する", MainThreadRequired = true, Tags = new[] { "tests" })]
        public static async Task<TestExecutionResponse> RunTestsFilteredEditMode(
            [CliArg("assembly", "基準のアセンブリ名（完全一致、大文字小文字は区別しない）。省略時はEditModeの全アセンブリ")] string assembly = null,
            [CliArg("include-categories", "含めるカテゴリのカンマ区切りリスト（いずれかに当たれば含める）")] string includeCategories = null,
            [CliArg("exclude-categories", "除くカテゴリのカンマ区切りリスト（いずれかに当たれば除く）")] string excludeCategories = null,
            [CliArg("exclude-names", "除く完全名(FullName)のカンマ区切りリスト。クラスの完全名ならクラス全体、メソッドの完全名ならそのメソッドを除く")] string excludeNames = null,
            [CliArg("timeout", "テスト実行タイムアウト秒(既定300)")] int timeout = 300)
        {
            var selection = TestSelection.Parse(assembly, includeCategories, excludeCategories, excludeNames);
            if (selection.IsEmpty)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_filtered_editmode",
                    "絞り込み条件が指定されていません。assembly・include-categories・exclude-categories・exclude-names のいずれかを指定してください。");
            }

            var startTime = DateTime.UtcNow;
            var api = ScriptableObject.CreateInstance<TestRunnerApi>();
            var collector = new TestResultCollector();

            try
            {
                var tcs = new TaskCompletionSource<ITestResultAdaptor>();
                collector.OnRunFinished = () => tcs.TrySetResult(collector.RootResult);

                api.RegisterCallbacks(collector);
                api.Execute(new ExecutionSettings(selection.ToFilter(TestMode.EditMode)));

                using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout)))
                using (cts.Token.Register(() =>
                       {
                           collector.Cancel();
                           tcs.TrySetCanceled();
                       }))
                {
                    var rootResult = await tcs.Task;
                    var duration = (DateTime.UtcNow - startTime).TotalSeconds;
                    // 要求した名前の欠落チェックは、完全名を「含める」指定のときだけ意味を持つので空配列を渡す
                    var response = TestRunnerCliUtility.BuildSuccessResponse("run_tests_filtered_editmode", "EditMode", duration, Array.Empty<string>(), collector, rootResult);
                    response.FilterApplied = selection.Describe();
                    return response;
                }
            }
            catch (TaskCanceledException)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_filtered_editmode",
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
