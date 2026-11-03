#if TESTRUNNER_CLI_AVAILABLE
using System;
using Newtonsoft.Json.Linq;
using Unity.Pipeline.Commands;
using UnityEditor.TestTools.TestRunner.Api;

namespace TestRunnerCli
{
    /// <summary>PlayModeバッチ実行のPipelineコマンド層。ロジックは持たず
    /// TestRunnerBatchPlayModeRunnerを呼ぶだけ。</summary>
    public static class TestRunnerBatchPlayModeCommands
    {
        [CliCommand("wr.testrunner", "run_tests_batch_playmode", "複数の完全名(FullName)をカンマ区切りで受け取り、1回のExecuteでPlayModeテストをまとめて非同期実行する。完了確認はwr.testrunner batch_test_statusをポーリングする。", MainThreadRequired = true, Tags = new[] { "tests" })]
        public static TestExecutionResponse RunTestsBatchPlayMode(
            [CliArg("full_names", "実行する完全名(FullName)のカンマ区切りリスト", Required = true)] string fullNames,
            [CliArg("async_tests", "非同期実行するかどうか。PlayModeはPlay Mode突入でドメインリロードが発生するため、falseのままではエラーになる。", Required = true)] bool asyncTests = false)
        {
            if (!asyncTests)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_batch_playmode",
                    "PlayModeのバッチテストは同期実行できません。Play Mode突入がドメインリロードを伴いHTTPリクエストが失われるため、" +
                    "--async_tests trueを指定し、wr.testrunner batch_test_statusをポーリングしてください。");
            }

            var names = TestRunnerCliUtility.ParseFullNames(fullNames);
            if (names.Length == 0)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_batch_playmode",
                    "full_namesが空です。カンマ区切りの完全名を1件以上指定してください。");
            }

            TestRunnerBatchPlayModeRunner.StartBatch(names);

            return new TestExecutionResponse
            {
                Success = true,
                Command = "run_tests_batch_playmode",
                Result = "running",
                Mode = "PlayMode",
                FilterApplied = $"full_names: {fullNames}",
                Message = "PlayModeバッチテストを開始しました。wr.testrunner batch_test_statusをポーリングしてください。",
                ExecutedAt = DateTime.UtcNow
            };
        }

        [CliCommand("wr.testrunner", "run_tests_filtered_playmode", "アセンブリ・含めるカテゴリ・除くカテゴリ・除く完全名(FullName)を組み合わせて絞り込み、1回のExecuteでPlayModeテストを非同期実行する。名前・カテゴリ・アセンブリはすべて完全一致で照合する。完了確認はwr.testrunner batch_test_statusをポーリングし、応答のRequestIdとステータスのrequestIdを照合する。", MainThreadRequired = true, Tags = new[] { "tests" })]
        public static TestExecutionResponse RunTestsFilteredPlayMode(
            [CliArg("async_tests", "非同期実行するかどうか。PlayModeはPlay Mode突入でドメインリロードが発生するため、falseのままではエラーになる。", Required = true)] bool asyncTests = false,
            [CliArg("assembly", "基準のアセンブリ名（完全一致、大文字小文字は区別しない）。省略時はPlayModeの全アセンブリ")] string assembly = null,
            [CliArg("include_categories", "含めるカテゴリのカンマ区切りリスト（いずれかに当たれば含める）")] string includeCategories = null,
            [CliArg("exclude_categories", "除くカテゴリのカンマ区切りリスト（いずれかに当たれば除く）")] string excludeCategories = null,
            [CliArg("exclude_names", "除く完全名(FullName)のカンマ区切りリスト。クラスの完全名ならクラス全体、メソッドの完全名ならそのメソッドを除く")] string excludeNames = null)
        {
            if (!asyncTests)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_filtered_playmode",
                    "PlayModeのテストは同期実行できません。Play Mode突入がドメインリロードを伴いHTTPリクエストが失われるため、" +
                    "--async_tests trueを指定し、wr.testrunner batch_test_statusをポーリングしてください。");
            }

            var selection = TestSelection.Parse(assembly, includeCategories, excludeCategories, excludeNames);
            if (selection.IsEmpty)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_filtered_playmode",
                    "絞り込み条件が指定されていません。assembly・include_categories・exclude_categories・exclude_names のいずれかを指定してください。");
            }

            var description = selection.Describe();
            var requestId = TestRunnerBatchPlayModeRunner.StartBatch(selection.ToFilter(TestMode.PlayMode), description);

            return new TestExecutionResponse
            {
                Success = true,
                Command = "run_tests_filtered_playmode",
                Result = "running",
                Mode = "PlayMode",
                FilterApplied = description,
                RequestId = requestId,
                Message = "PlayModeテストを開始しました。wr.testrunner batch_test_statusをポーリングしてください。",
                ExecutedAt = DateTime.UtcNow
            };
        }

        [CliCommand("wr.testrunner", "batch_test_status", "run_tests_batch_playmodeの実行状況を取得する", MainThreadRequired = false, Tags = new[] { "tests" })]
        public static JToken BatchTestStatus()
        {
            return TestRunnerBatchPlayModeRunner.GetStatus();
        }

        [CliCommand("wr.testrunner", "batch_cancel_tests", "実行中のPlayModeバッチテストをキャンセルする（パッケージ本体のtest cancelはこのバッチ実行には作用しない）", MainThreadRequired = true, Tags = new[] { "tests" })]
        public static object BatchCancelTests()
        {
            return TestRunnerBatchPlayModeRunner.CancelBatch();
        }
    }
}
#endif
