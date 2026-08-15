#if TESTRUNNER_CLI_AVAILABLE
using UnityEditor;

namespace TestRunnerCli
{
    /// <summary>Play Mode突入によるドメインリロード後、TestRunnerBatchPlayModeRunnerが開始した
    /// バッチ実行の結果コレクタを再登録する。com.unity.pipelineパッケージ本体のTestReloaderと
    /// 同じ理由（ドメインリロードでコールバック登録が失われるため）で必要。</summary>
    [InitializeOnLoad]
    public static class TestRunnerBatchPlayModeReloadHandler
    {
        static TestRunnerBatchPlayModeReloadHandler()
        {
            EditorApplication.delayCall += TestRunnerBatchPlayModeRunner.ReattachAfterReload;
        }
    }
}
#endif
