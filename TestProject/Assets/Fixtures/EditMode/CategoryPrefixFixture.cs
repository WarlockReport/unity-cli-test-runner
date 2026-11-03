using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: カテゴリ名の前方一致の罠を再現する。
    // カテゴリ「SlowView」は「Slow」を先頭に含むため、完全一致でない照合では巻き込まれる
    public class CategoryPrefixFixture
    {
        [Test]
        [Category("SlowView")]
        public void Pass_Only()
        {
            Assert.Pass();
        }
    }
}
