using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace Fixtures.PlayMode
{
    // e2e/run-all.sh の固定台: フレームをまたぐ PlayMode テスト（成功 2・失敗 1）。
    // 失敗は意図的なもの。非同期実行とドメインリロードを越えた結果の回収を検証するために置いている
    public class PlayModeFixture
    {
        [UnityTest]
        public IEnumerator Pass_AfterOneFrame()
        {
            var startFrame = Time.frameCount;
            yield return null;
            Assert.That(Time.frameCount, Is.GreaterThan(startFrame));
        }

        [UnityTest]
        public IEnumerator Pass_AfterSeveralFrames()
        {
            for (var i = 0; i < 5; i++)
            {
                yield return null;
            }
            Assert.Pass();
        }

        [UnityTest]
        [Category("ExpectedFailure")]
        public IEnumerator Fail_Intentionally()
        {
            yield return null;
            Assert.Fail("意図的な失敗（e2e の固定台）");
        }
    }
}
