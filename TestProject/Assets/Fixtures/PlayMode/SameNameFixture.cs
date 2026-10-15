using System.Collections;
using NUnit.Framework;
using UnityEngine.TestTools;

namespace Fixtures.PlayMode
{
    // e2e/run-all.sh の固定台: EditMode 側（Fixtures.EditMode.SameNameFixture）と同じクラス名。
    // クラス名だけで指定されたときに、モードを取り違えずに解決できるかを確かめるために置いている
    public class SameNameFixture
    {
        [UnityTest]
        public IEnumerator Pass_Only()
        {
            yield return null;
            Assert.Pass();
        }
    }
}
