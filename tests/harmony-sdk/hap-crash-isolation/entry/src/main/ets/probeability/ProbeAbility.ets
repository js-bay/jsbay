import { UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x5A4A;
const TAG = 'JsBayCrashIso';

/**
 * Runs in process `:jsbay_probe`.
 * Same-process Zig abort kills THIS process only; EntryAbility's process must survive.
 * Default product HAR has no jsbay_test_trigger_native_fault — we SKIP honestly.
 */
export default class ProbeAbility extends UIAbility {
  onCreate(want: Want): void {
    const mode = (want.parameters?.['mode'] as string) ?? 'doc-skip';
    hilog.info(DOMAIN, TAG, 'JSBAY_PROBE_START mode=%{public}s pid-process=jsbay_probe', mode);
    if (mode === 'abort' || mode === 'segfault') {
      hilog.warn(DOMAIN, TAG,
        'SKIP: JSBAY_PROBE_NATIVE — product HAP has no fault-injection symbol; ' +
          'rebuild with -Dfault-injection=true test core + Probe native bridge to exercise real abort in :jsbay_probe');
      hilog.info(DOMAIN, TAG, 'JSBAY_PROBE_SKIP reason=no-fault-injection-in-product-hap');
    } else {
      hilog.info(DOMAIN, TAG, 'JSBAY_PROBE_SKIP reason=doc-only-multi-process-sketch');
    }
    // Exit this Ability's process cleanly so parent can observe survival.
    this.context.terminateSelf().catch(() => {
      hilog.error(DOMAIN, TAG, 'terminateSelf failed');
    });
  }
}
