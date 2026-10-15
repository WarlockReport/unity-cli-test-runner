using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: すべて成功する EditMode テスト（2 件）
    public class AllPassFixture
    {
        [Test]
        public void Pass_First()
        {
            Assert.That(1 + 1, Is.EqualTo(2));
        }

        [Test]
        public void Pass_Second()
        {
            Assert.That("fixture", Is.Not.Empty);
        }
    }
}
