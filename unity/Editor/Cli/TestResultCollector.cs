#if TESTRUNNER_CLI_AVAILABLE
using System;
using System.Collections.Generic;
using UnityEditor.TestTools.TestRunner.Api;
using UnityEngine;

namespace TestRunnerCli
{
    /// <summary>Unity Test Runner APIのコールバックからテスト結果を収集する。
    /// com.unity.pipeline 0.6.0-exp.1 で <c>Unity.Pipeline.Editor.Testing.TestResultCollector</c> が
    /// internal化されたため、同パッケージ0.6版の実装を本パッケージへ移植したもの（ADR-0012）。
    ///
    /// 本体からの差分は2点だけで、いずれも本パッケージでの用途に合わせた削減:
    /// - 同期モード（WaitForCompletionAsync / SetError / TaskCompletionSource）を持たない。
    ///   本パッケージのEditModeコマンドは自前のTaskCompletionSourceと<see cref="OnRunFinished"/>で
    ///   待ち合わせており、PlayModeはステータスファイル経由なので、いずれも使っていない
    /// - 上記に伴い、二重完了ガードの根拠をTaskCompletionSourceの完了状態から
    ///   <see cref="m_HasCompleted"/> に置き換えた（後述）
    ///
    /// ログのprefixはパッケージ本体（[TestResultCollector]）と区別できるよう [TestRunnerCli] にしてある。</summary>
    internal sealed class TestResultCollector : ICallbacks
    {
        /// <summary><see cref="RunFinished"/>が（重複でもキャンセルでもない）実行を処理し終えたらtrue。</summary>
        public bool IsComplete { get; private set; }
        /// <summary><see cref="Cancel"/>が立てる。trueになって以降のコールバックは無視される。</summary>
        public bool IsCancelled { get; set; }
        /// <summary>ここまでに収集した個々のテスト結果。</summary>
        public List<TestResult> Results { get; } = new List<TestResult>();
        /// <summary>完了した実行の結果ツリーのルート。<see cref="RunFinished"/>が設定する。</summary>
        public ITestResultAdaptor RootResult { get; private set; }

        /// <summary><see cref="RunFinished"/>が実行の完了を処理したときに呼ばれる。</summary>
        public Action OnRunFinished { get; set; }

        /// <summary>二重完了ガード。<see cref="IsComplete"/>と違い<see cref="RunStarted"/>で
        /// リセットされないことが重要である。TestRunnerApiに登録されたまま残った古いコレクタは、
        /// 後続の実行のRunStarted（IsCompleteをfalseに戻す）とRunFinishedを受け取ってしまうため、
        /// IsCompleteでは「自分は既に完了済みなので、これは自分の実行の通知ではない」を判別できない。
        /// パッケージ本体0.6版がTaskCompletionSourceの完了状態で行っているガードと同じ役割を、
        /// 同期モードを持たない本実装ではこのフラグが担う。</summary>
        private bool m_HasCompleted;

        /// <summary>ICallbacks: 実行が開始された。</summary>
        /// <param name="testsToRun">これから実行されるテスト。</param>
        public void RunStarted(ITestAdaptor testsToRun)
        {
            if (IsCancelled) return;

            IsComplete = false;
            Results.Clear();
            Debug.Log($"[TestRunnerCli] Run started: {testsToRun.TestCaseCount} test(s)");
        }

        /// <summary>ICallbacks: 個々のテストが開始された。何もしない。</summary>
        /// <param name="test">これから実行されるテスト。</param>
        public void TestStarted(ITestAdaptor test)
        {
            // テスト開始時に行うことはない
        }

        /// <summary>ICallbacks: 個々の（スイートでない）テストが完了した。</summary>
        /// <param name="result">完了したテストの結果。</param>
        public void TestFinished(ITestResultAdaptor result)
        {
            if (IsCancelled) return;
            if (result.Test.IsSuite) return;

            Results.Add(BuildTestResult(result));
        }

        /// <summary>ICallbacks: 実行全体が完了した。</summary>
        /// <param name="result">実行の結果ツリーのルート。</param>
        public void RunFinished(ITestResultAdaptor result)
        {
            if (IsCancelled)
            {
                Debug.Log("[TestRunnerCli] Ignoring RunFinished from cancelled run");
                return;
            }

            // 古いコレクタが後続の実行のRunFinishedを受け取りうる（m_HasCompletedの説明を参照）。
            // ここで弾かないとOnRunFinishedが二重に発火し、呼び出し元の待ち合わせを壊す。
            if (m_HasCompleted)
            {
                Debug.Log("[TestRunnerCli] Ignoring duplicate RunFinished (already completed)");
                return;
            }

            RootResult = result;
            IsComplete = true;
            m_HasCompleted = true;

            // テストが走り終わった後に登録した場合（PlayModeはドメインリロードのたびに新しい
            // コレクタを登録し直すため、逐次のTestFinishedは前のドメインのコレクタに配られている）、
            // 正となる結果ツリーから組み立て直す。通常のドメイン内の経路ではResultsは既に埋まっている。
            if (Results.Count == 0)
            {
                CollectLeafResults(result);
            }

            var total = result.PassCount + result.FailCount + result.SkipCount + result.InconclusiveCount;
            Debug.Log($"[TestRunnerCli] Run finished: {total} total, {result.PassCount} passed, {result.FailCount} failed");

            OnRunFinished?.Invoke();
        }

        /// <summary>結果の収集をキャンセルする。以降のコールバックは無視される。</summary>
        public void Cancel()
        {
            IsCancelled = true;
        }

        /// <summary>結果ツリーから葉（スイートでない）のテスト結果を再帰的に集める。
        /// 逐次のTestFinishedを受け取れないタイミングで登録された場合（PlayModeのドメインリロード後の
        /// 再開）に、RunFinishedでResultsを組み立て直すために使う。</summary>
        private void CollectLeafResults(ITestResultAdaptor result)
        {
            if (result == null) return;

            if (!result.Test.IsSuite && !result.Test.HasChildren)
            {
                Results.Add(BuildTestResult(result));
                return;
            }

            if (result.Children != null)
            {
                foreach (var child in result.Children)
                {
                    CollectLeafResults(child);
                }
            }
        }

        private static TestResult BuildTestResult(ITestResultAdaptor result)
        {
            return new TestResult
            {
                FullName = result.Test.FullName,
                Status = result.TestStatus.ToString(),
                Duration = result.Duration,
                Message = Truncate(result.Message, 10000),
                StackTrace = Truncate(result.StackTrace, 10000)
            };
        }

        private static string Truncate(string s, int maxLength)
        {
            if (s == null || s.Length <= maxLength) return s;
            return s.Substring(0, maxLength) + "\n... (truncated)";
        }
    }
}
#endif
