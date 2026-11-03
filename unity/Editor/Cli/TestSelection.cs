#if TESTRUNNER_CLI_AVAILABLE
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;
using UnityEditor.TestTools.TestRunner.Api;

namespace TestRunnerCli
{
    /// <summary>アセンブリ・含めるカテゴリ・除くカテゴリ・除く完全名による絞り込み条件。
    /// Unity Test Framework の <see cref="Filter"/> に変換して、1 回の実行で絞り込みを行う。</summary>
    internal sealed class TestSelection
    {
        /// <summary>基準のアセンブリ名。未指定なら null（その Mode の全アセンブリが基準になる）。</summary>
        internal string Assembly { get; private set; }
        /// <summary>含めるカテゴリ。いずれかに当たるテストを含める。</summary>
        internal string[] IncludeCategories { get; private set; }
        /// <summary>除くカテゴリ。いずれかに当たるテストを除く。</summary>
        internal string[] ExcludeCategories { get; private set; }
        /// <summary>除く完全名（クラス・メソッド等）。完全一致したノードとその配下を除く。</summary>
        internal string[] ExcludeNames { get; private set; }

        /// <summary>絞り込み条件が 1 つも指定されていなければ true。</summary>
        internal bool IsEmpty =>
            Assembly == null && IncludeCategories.Length == 0 && ExcludeCategories.Length == 0 && ExcludeNames.Length == 0;

        /// <summary>CLI 引数（カンマ区切り）から絞り込み条件を組み立てる。カンマ区切りの各要素は前後の空白を除き、
        /// 空の要素は捨てる（完全名一覧のバッチ実行と同じ規則）。</summary>
        internal static TestSelection Parse(string assembly, string includeCategories, string excludeCategories, string excludeNames)
        {
            var trimmedAssembly = assembly?.Trim();
            return new TestSelection
            {
                Assembly = string.IsNullOrEmpty(trimmedAssembly) ? null : trimmedAssembly,
                IncludeCategories = TestRunnerCliUtility.ParseFullNames(includeCategories),
                ExcludeCategories = TestRunnerCliUtility.ParseFullNames(excludeCategories),
                ExcludeNames = TestRunnerCliUtility.ParseFullNames(excludeNames)
            };
        }

        /// <summary>絞り込み条件を <see cref="Filter"/> に変換する。
        /// 除外は Filter の配列で先頭に「!」を付けた要素として表す（Unity Test Framework が NotFilter に変換する）。
        /// testNames は完全一致で照合され、除外は一致したノードの配下にも効く。
        /// categoryNames は正規表現の部分一致で照合されるため、名前をエスケープして ^…$ で囲み、
        /// 「Slow」で「SlowView」を巻き込まない完全一致にする。</summary>
        internal Filter ToFilter(TestMode mode)
        {
            var categoryNames = IncludeCategories.Select(ExactCategoryPattern)
                .Concat(ExcludeCategories.Select(category => "!" + ExactCategoryPattern(category)))
                .ToArray();

            return new Filter
            {
                testMode = mode,
                assemblyNames = Assembly == null ? null : new[] { Assembly },
                categoryNames = categoryNames.Length == 0 ? null : categoryNames,
                testNames = ExcludeNames.Length == 0 ? null : ExcludeNames.Select(name => "!" + name).ToArray()
            };
        }

        /// <summary>FilterApplied に載せる、指定された条件だけを並べた 1 行の説明。</summary>
        internal string Describe()
        {
            var parts = new List<string>();
            if (Assembly != null)
            {
                parts.Add($"assembly: {Assembly}");
            }
            AddPart(parts, "include_categories", IncludeCategories);
            AddPart(parts, "exclude_categories", ExcludeCategories);
            AddPart(parts, "exclude_names", ExcludeNames);
            return string.Join("; ", parts);
        }

        private static void AddPart(List<string> parts, string label, string[] values)
        {
            if (values.Length > 0)
            {
                parts.Add($"{label}: {string.Join(",", values)}");
            }
        }

        private static string ExactCategoryPattern(string category)
        {
            return "^" + Regex.Escape(category) + "$";
        }
    }
}
#endif
