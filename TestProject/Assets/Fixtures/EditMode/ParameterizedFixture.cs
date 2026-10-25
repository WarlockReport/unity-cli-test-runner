using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: 引数が 2 つある [TestCase] のテスト（4 ケース、すべて成功）。
    // NUnit はケースの FullName に引数をカンマ区切りで入れる（例: Multiplier_DependsOnPhase(First,2)）。
    // カンマ区切りで FullName を渡すバッチ実行で、この名前が途中で割れないことを確かめるために置いている
    public class ParameterizedFixture
    {
        public enum Phase
        {
            First,
            Second,
            Third,
            Fourth
        }

        [TestCase(Phase.First, 2)]
        [TestCase(Phase.Second, 3)]
        [TestCase(Phase.Third, 3)]
        [TestCase(Phase.Fourth, 2)]
        public void Multiplier_DependsOnPhase(Phase phase, int expected)
        {
            var actual = phase == Phase.Second || phase == Phase.Third ? 3 : 2;
            Assert.That(actual, Is.EqualTo(expected));
        }
    }
}
