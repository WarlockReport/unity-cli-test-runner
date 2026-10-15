using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: 成功 3・失敗 1・スキップ 1 が混在する EditMode テスト（5 件）。
    // 失敗とスキップは意図的なもの。結果の集計と報告を検証するために置いている
    public class MixedResultFixture
    {
        [Test]
        public void Pass_One()
        {
            Assert.Pass();
        }

        [Test]
        public void Pass_Two()
        {
            Assert.That(true, Is.True);
        }

        [Test]
        public void Pass_Three()
        {
            Assert.That(new[] { 1, 2, 3 }, Has.Length.EqualTo(3));
        }

        [Test]
        [Category("ExpectedFailure")]
        public void Fail_Intentionally()
        {
            Assert.Fail("意図的な失敗（e2e の固定台）");
        }

        [Test]
        [Ignore("意図的なスキップ（e2e の固定台）")]
        public void Skip_Intentionally()
        {
        }
    }
}
