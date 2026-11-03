using NUnit.Framework;

namespace Fixtures.EditMode
{
    // e2e/run-all.sh の固定台: クラスに付けたカテゴリが配下のメソッドへ引き継がれることを確かめる。
    // カテゴリで含める・除く絞り込み実行の対象になる
    [Category("Slow")]
    public class CategorizedFixture
    {
        [Test]
        public void Pass_First()
        {
            Assert.Pass();
        }

        [Test]
        public void Pass_Second()
        {
            Assert.Pass();
        }
    }
}
