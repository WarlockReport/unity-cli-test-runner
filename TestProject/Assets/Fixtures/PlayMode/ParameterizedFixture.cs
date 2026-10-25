using NUnit.Framework;

namespace Fixtures.PlayMode
{
    // e2e/run-all.sh の固定台: 引数が 2 つある [TestCase] の PlayMode テスト（2 ケース、すべて成功）。
    // NUnit はケースの FullName に引数をカンマ区切りで入れるため、カンマ区切りで FullName を渡す
    // バッチ実行で名前が途中で割れないことを PlayMode でも確かめるために置いている
    public class ParameterizedFixture
    {
        [TestCase(1, 2)]
        [TestCase(2, 3)]
        public void Increment_AddsOne(int value, int expected)
        {
            Assert.That(value + 1, Is.EqualTo(expected));
        }
    }
}
