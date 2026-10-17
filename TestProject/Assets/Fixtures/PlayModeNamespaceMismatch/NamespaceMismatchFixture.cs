using System.Collections;
using NUnit.Framework;
using UnityEngine.TestTools;

namespace MismatchFixtures
{
    // e2e/run-all.sh の固定台: アセンブリ名（Fixtures.NamespaceMismatch.PlayMode）と名前空間が一致しない。
    // test_status の結果には FullName（名前空間始まり）しか出ないため、アセンブリ名を filter にした
    // PlayMode 実行の結果にアセンブリ名が現れない。その状態でも整合性チェックが誤検知しないかを確かめる
    public class NamespaceMismatchFixture
    {
        [UnityTest]
        public IEnumerator Pass_Only()
        {
            yield return null;
            Assert.Pass();
        }
    }
}
