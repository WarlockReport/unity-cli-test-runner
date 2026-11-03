#if TESTRUNNER_CLI_AVAILABLE
using System;
using System.IO;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEditor;
using UnityEditor.TestTools.TestRunner.Api;
using UnityEngine;

namespace TestRunnerCli
{
    /// <summary>PlayModeバッチ実行のオーケストレーション。Play Mode突入によるドメインリロードを
    /// 越えて完了通知を受け取るため、リクエスト/ステータスをTemp/配下のファイルへ永続化する。
    /// com.unity.pipelineパッケージ本体のPipelineTestRunnerと同型のパターンだが、結果収集自体は
    /// 本パッケージの <see cref="TestResultCollector"/>（同パッケージ0.6版からの移植）に任せる。</summary>
    internal static class TestRunnerBatchPlayModeRunner
    {
        private const string RequestFilePath = "Temp/testrunner_cli_batch_request.json";
        private const string StatusFilePath = "Temp/testrunner_cli_batch_status.json";

        private static TestRunnerApi _activeApi;
        private static TestResultCollector _activeCollector;

        /// <summary>完全名(FullName)の一覧を完全一致で実行する（run_tests_batch_playmode）。</summary>
        internal static string StartBatch(string[] fullNames)
        {
            return StartBatch(
                new Filter { testMode = TestMode.PlayMode, testNames = fullNames },
                $"full_names: {string.Join(",", fullNames)}",
                fullNames);
        }

        /// <summary>任意の <see cref="Filter"/> で PlayMode テストを非同期実行する。戻り値は今回の実行の requestId。
        /// requestId は完了ステータスに載り、起動応答の RequestId と照合して前回の結果を読んでいないかを確かめるのに使う。
        /// ドメインリロードを越えて持ち回るため、リクエストファイルにも保存する。</summary>
        internal static string StartBatch(Filter filter, string description)
        {
            return StartBatch(filter, description, null);
        }

        private static string StartBatch(Filter filter, string description, string[] fullNames)
        {
            InvalidatePreviousRun();

            var requestId = Guid.NewGuid().ToString("N");
            File.WriteAllText(RequestFilePath, JsonConvert.SerializeObject(new BatchTestRequest
            {
                requestId = requestId,
                filter = description,
                fullNames = fullNames
            }));
            if (File.Exists(StatusFilePath))
            {
                File.Delete(StatusFilePath);
            }

            var api = ScriptableObject.CreateInstance<TestRunnerApi>();
            var collector = new TestResultCollector();
            _activeApi = api;
            _activeCollector = collector;

            collector.OnRunFinished = () => OnRunFinished(api, collector, requestId);

            api.RegisterCallbacks(collector);
            api.Execute(new ExecutionSettings(filter));
            return requestId;
        }

        internal static string GetStatusJson()
        {
            if (File.Exists(StatusFilePath))
            {
                return File.ReadAllText(StatusFilePath);
            }

            if (File.Exists(RequestFilePath))
            {
                return "{\"status\":\"running\"}";
            }

            return "{\"status\":\"no_tests\",\"message\":\"バッチ実行はまだ開始されていません。\"}";
        }

        /// <summary>batch_test_status の返り値。ステータスJSONを <see cref="JToken"/> にして返す。
        /// 文字列のまま返すとコマンド結果の直列化で二重エンコードされ、クライアントが2回パースする
        /// 必要がある（com.unity.pipeline 0.8 で本体の *_status も同じ理由でJSONを返す形に揃えられた）。</summary>
        internal static JToken GetStatus()
        {
            return ParseStatus(GetStatusJson());
        }

        /// <summary>ステータスJSON文字列を1つの完全なJSON文書として読む。空・パース不能・
        /// 文書の後ろに余計な文字が残っている場合は例外にせず status="malformed" を返す。
        /// ステータスファイルは File.WriteAllText で書かれるため、ポーリングが書き込みの途中に
        /// 当たると空や途中までの文字列を読むことがあり、それを例外にするとポーリングごと失敗するため。</summary>
        internal static JToken ParseStatus(string text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return Malformed(text);
            }

            try
            {
                // DateParseHandling.None: ISO-8601 文字列を Date 型に変換させず、ファイルの値をそのまま通す
                using (var reader = new JsonTextReader(new StringReader(text)) { DateParseHandling = DateParseHandling.None })
                {
                    var document = JToken.ReadFrom(reader);

                    // 短い書き込みが長い旧ファイルを上書きした場合、先頭の文書だけ読めて後ろに残骸が残る。
                    // それを現在のステータスとして返さないよう、文書の後ろが終端であることを確かめる
                    return reader.Read() ? Malformed(text) : document;
                }
            }
            catch (JsonReaderException)
            {
                return Malformed(text);
            }
        }

        private static JObject Malformed(string text)
        {
            return new JObject { ["status"] = "malformed", ["raw"] = text ?? string.Empty };
        }

        internal static object CancelBatch()
        {
            if (_activeCollector == null && !File.Exists(RequestFilePath))
            {
                return new { status = "no_tests", message = "実行中のバッチテストはありません。" };
            }

            InvalidatePreviousRun();
            WriteStatus(new { status = "cancelled", message = "バッチテスト実行をキャンセルしました。" });
            CleanupRequestFile();

            if (EditorApplication.isPlaying)
            {
                Debug.Log("[TestRunnerCli] バッチテストキャンセルのためPlay Modeを終了します。");
                EditorApplication.ExitPlaymode();
            }

            return new { status = "cancelled", message = "バッチテスト実行をキャンセルしました。" };
        }

        /// <summary>Play Mode突入によるドメインリロード後、再開待ちのリクエストがあれば結果コレクタを
        /// 再登録する。Unity Test Frameworkが実行中のジョブを自動再開する（TestJobDataHolder）ため、
        /// ここではapi.Executeを再度呼ばない。再登録するのは、ドメインリロードで失われたコールバック
        /// 登録を復元し、再開された実行の完了通知（RunFinished）を受け取れるようにするためだけである。
        /// com.unity.pipelineパッケージ本体のReattachResultCollectorと同じ理由。</summary>
        internal static void ReattachAfterReload()
        {
            if (!File.Exists(RequestFilePath) || File.Exists(StatusFilePath))
            {
                return;
            }

            TestRunnerApi api = null;
            TestResultCollector collector = null;
            var requestId = ReadRequestId();
            try
            {
                api = ScriptableObject.CreateInstance<TestRunnerApi>();
                collector = new TestResultCollector();
                _activeApi = api;
                _activeCollector = collector;
    
                collector.OnRunFinished = () => OnRunFinished(api, collector, requestId);
                api.RegisterCallbacks(collector);
            }
            catch (Exception ex)
            {
                // 再接続に失敗した場合、リクエストファイルだけが残ると、対応するステータスファイルが
                // 永遠に書かれず GetStatusJson() が "running" を返し続け、ポーラーが無限に待ち続ける。
                // com.unity.pipelineパッケージ本体のCheckForPendingTests/ReattachResultCollectorと
                // 同じ方針で、エラーステータスを書き込みリクエストファイルを削除してから終了する。
                Debug.LogError($"[TestRunnerCli] Play Modeバッチ再接続に失敗しました: {ex.Message}");
                WriteStatus(new { status = "error", message = ex.Message, requestId });
                CleanupRequestFile();
                UnregisterCollector(api, collector);
            }
        }

        private static void OnRunFinished(TestRunnerApi api, TestResultCollector collector, string requestId)
        {
            if (!collector.IsComplete)
            {
                WriteStatus(new { status = "error", message = "テストが完了しませんでした。", requestId });
            }
            else
            {
                var root = collector.RootResult;
                WriteStatus(new
                {
                    status = "completed",
                    duration = Math.Round(root.Duration, 2),
                    summary = new
                    {
                        total = root.PassCount + root.FailCount + root.SkipCount + root.InconclusiveCount,
                        passed = root.PassCount,
                        failed = root.FailCount,
                        skipped = root.SkipCount,
                        inconclusive = root.InconclusiveCount
                    },
                    results = collector.Results.ToArray(),
                    requestId
                });
            }

            CleanupRequestFile();
            UnregisterCollector(api, collector);
        }

        private static void InvalidatePreviousRun()
        {
            if (_activeCollector != null)
            {
                _activeCollector.Cancel();
                UnregisterCollector(_activeApi, _activeCollector);
            }
        }

        private static void UnregisterCollector(TestRunnerApi api, TestResultCollector collector)
        {
            if (api != null && collector != null)
            {
                try
                {
                    api.UnregisterCallbacks(collector);
                }
                catch (Exception ex)
                {
                    Debug.LogWarning($"[TestRunnerCli] コレクタ解除に失敗しました: {ex.Message}");
                }
            }

            if (ReferenceEquals(_activeCollector, collector))
            {
                _activeApi = null;
                _activeCollector = null;
            }
        }

        private static void WriteStatus(object data)
        {
            File.WriteAllText(StatusFilePath, JsonConvert.SerializeObject(data, Formatting.Indented));
        }

        private static void CleanupRequestFile()
        {
            if (File.Exists(RequestFilePath))
            {
                File.Delete(RequestFilePath);
            }
        }

        /// <summary>リクエストファイルから requestId を読む。旧形式（requestId を持たない）や読めない場合は null。</summary>
        private static string ReadRequestId()
        {
            try
            {
                return JsonConvert.DeserializeObject<BatchTestRequest>(File.ReadAllText(RequestFilePath))?.requestId;
            }
            catch (Exception ex)
            {
                Debug.LogWarning($"[TestRunnerCli] バッチ実行のリクエストファイルを読めませんでした: {ex.Message}");
                return null;
            }
        }

        [Serializable]
        private sealed class BatchTestRequest
        {
            /// <summary>今回の実行の識別子。</summary>
            public string requestId;
            /// <summary>適用したフィルタの説明（診断用）。</summary>
            public string filter;
            /// <summary>完全名一覧の実行のときだけ値を持つ。</summary>
            public string[] fullNames;
        }
    }
}
#endif
