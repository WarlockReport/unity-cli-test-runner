using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: PrefixFixture の名前を先頭に含む別クラス（前方一致の罠の相方）
    public class PrefixFixtureExtra
    {
        [Test]
        public void Pass_Only()
        {
            Assert.Pass();
        }
    }
}
