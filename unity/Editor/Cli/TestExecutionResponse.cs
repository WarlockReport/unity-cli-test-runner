#if TESTRUNNER_CLI_AVAILABLE
using System;
using System.Collections.Generic;
using Newtonsoft.Json;
using Unity.Pipeline.Models;

namespace TestRunnerCli
{
    /// <summary>テスト実行コマンドの戻り値。com.unity.pipeline 0.6.0-exp.1 で
    /// <c>Unity.Pipeline.TestExecutionResponse</c> がinternal化されたため、同等のモデルを
    /// 本パッケージ側で持つ。基底の <see cref="CommandExecutionResponse"/> は
    /// 0.6でもpublicのままなので、公式ドキュメント（Documentation~/creating-commands.md）が
    /// 正規の作法として挙げる「CommandExecutionResponseを継承した独自モデルを返す」形に沿う。
    ///
    /// パッケージ本体の同名型が持つ <c>StatusPath</c> は、本パッケージが独自のステータスファイル
    /// （Temp/testrunner_cli_batch_status.json、batch_test_statusで取得）を使うため持たない。
    ///
    /// 追加したプロパティのJSONキーは com.unity.pipeline 1.0 の test status と同じ camelCase にそろえる。
    /// スクリプトは本体の test status と自前コマンドの結果を同じ形（status・summary・results[].fullName）で読む。</summary>
    [Serializable]
    public sealed class TestExecutionResponse : CommandExecutionResponse
    {
        /// <summary>実行結果の集計。</summary>
        [JsonProperty("summary")]
        public TestSummary Summary { get; set; }
        /// <summary>個々のテスト結果。</summary>
        [JsonProperty("results")]
        public List<TestResult> Results { get; set; }
        /// <summary>実行全体の所要時間（秒）。</summary>
        [JsonProperty("duration")]
        public double Duration { get; set; }
        /// <summary>実行したモード。EditMode または PlayMode。</summary>
        [JsonProperty("mode")]
        public string Mode { get; set; }
        /// <summary>適用したフィルタの内容。</summary>
        [JsonProperty("filterApplied")]
        public string FilterApplied { get; set; }
        /// <summary>PlayMode の非同期実行を識別する ID。起動応答だけが値を持ち、完了ステータスの
        /// requestId と照合して、前回の実行結果を読んでいないかを確かめるために使う。</summary>
        [JsonProperty("requestId")]
        public string RequestId { get; set; }
        /// <summary>実行の状態。同期の EditMode 実行が結果を返すときだけ "completed" を入れる
        /// （test status の完了状態と同じ値）。拒否時・PlayMode の起動応答では null で、JSONに出さない。
        /// 基底の CommandExecutionResponse.Status（サーバーの状態を表す）とは別の意味なので、new で隠して別に持つ
        /// （基底のものに入れると、Pipeline や CLI がサーバー側の状態として解釈しうるため）。</summary>
        [JsonProperty("status", NullValueHandling = NullValueHandling.Ignore)]
        public new string Status { get; set; }

        /// <summary>コレクションを初期化した空のレスポンスを作る。</summary>
        public TestExecutionResponse()
        {
            Results = new List<TestResult>();
            Summary = new TestSummary();
        }
    }
}
#endif
