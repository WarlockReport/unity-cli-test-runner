using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: PlayMode 側（Fixtures.PlayMode.SameNameFixture）と同じクラス名。
    // クラス名だけで指定されたときに、モードを取り違えずに解決できるかを確かめるために置いている
    public class SameNameFixture
    {
        [Test]
        public void Pass_Only()
        {
            Assert.Pass();
        }
    }
}
