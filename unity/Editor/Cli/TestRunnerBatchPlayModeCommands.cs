#if TESTRUNNER_CLI_AVAILABLE
using System;
using Unity.Pipeline;
using Unity.Pipeline.Commands;

namespace TestRunnerCli
{
    /// <summary>PlayModeバッチ実行のPipelineコマンド層。ロジックは持たず
    /// TestRunnerBatchPlayModeRunnerを呼ぶだけ。</summary>
    public static class TestRunnerBatchPlayModeCommands
    {
        [CliCommand("run_tests_batch_playmode", "複数の完全名(FullName)をカンマ区切りで受け取り、1回のExecuteでPlayModeテストをまとめて非同期実行する。完了確認はbatch_test_statusをポーリングする。", MainThreadRequired = true, Tags = new[] { "tests" })]
        public static TestExecutionResponse RunTestsBatchPlayMode(
            [CliArg("full_names", "実行する完全名(FullName)のカンマ区切りリスト", Required = true)] string fullNames,
            [CliArg("async_tests", "非同期実行するかどうか。PlayModeはPlay Mode突入でドメインリロードが発生するため、falseのままではエラーになる。", Required = true)] bool asyncTests = false)
        {
            if (!asyncTests)
            {
                return TestRunnerCliUtility.CreateErrorResponse(
                    "run_tests_batch_playmode",
                    "PlayModeのバッチテストは同期実行できません。Play Mode突入がドメインリロードを伴いHTTPリクエストが失われるため、" +
                    "--async_tests trueを指定し、batch_test_statusをポーリングしてください。");
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
                Message = "PlayModeバッチテストを開始しました。batch_test_statusをポーリングしてください。",
                ExecutedAt = DateTime.UtcNow
            };
        }

        [CliCommand("batch_test_status", "run_tests_batch_playmodeの実行状況を取得する", MainThreadRequired = false, Tags = new[] { "tests" })]
        public static string BatchTestStatus()
        {
            return TestRunnerBatchPlayModeRunner.GetStatusJson();
        }

        [CliCommand("batch_cancel_tests", "実行中のPlayModeバッチテストをキャンセルする（パッケージ本体のcancel_testsはこのバッチ実行には作用しない）", MainThreadRequired = true, Tags = new[] { "tests" })]
        public static object BatchCancelTests()
        {
            return TestRunnerBatchPlayModeRunner.CancelBatch();
        }
    }
}
#endif
