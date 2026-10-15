using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: クラス名の前方一致の罠を再現する。
    // PrefixFixtureExtra とクラス名の先頭が一致するため、境界を考慮しない照合では両方を巻き込む
    public class PrefixFixture
    {
        [Test]
        public void Pass_Only()
        {
            Assert.Pass();
        }
    }
}
