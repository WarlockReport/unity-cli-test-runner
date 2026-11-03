using System.Collections;
using NUnit.Framework;
using UnityEngine.TestTools;

namespace Fixtures.PlayMode
{
    // e2e/run-all.sh の固定台: クラスにカテゴリを付けた PlayMode テスト。
    // PlayMode の絞り込み実行で、カテゴリによる除外が効くことを確かめるために置いている
    [Category("Slow")]
    public class CategorizedPlayModeFixture
    {
        [UnityTest]
        public IEnumerator Pass_AfterOneFrame()
        {
            yield return null;
            Assert.Pass();
        }
    }
}
