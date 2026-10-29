import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, Want } from '@kit.AbilityKit';
import { runCrashIsolation } from './CrashIsolation';

const DOMAIN = 0x5A4A; // arbitrary hilog domain
const TAG = 'JsBayCrashIso';

@Entry
@Component
struct Index {
  @State result: string = 'Running jsbay CrashIsolation…';
  private ctx: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    this.runAll();
  }

  private async runAll(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'JSBAY_CRASHISO_START');
    console.info('JSBAY_CRASHISO_START');
    let ok = false;
    try {
      // Worker path relative to module ets root (Harmony ThreadWorker URL).
      ok = await runCrashIsolation('entry/ets/workers/CrashIsolationWorker.ets');
    } catch (cause) {
      const msg = String(cause);
      hilog.error(DOMAIN, TAG, 'JSBAY_CRASHISO_FAIL thrown=%{public}s', msg);
      console.error(`FAIL: harmony crash-isolation harness thrown — ${msg}`);
      this.result = `FAIL: thrown ${msg}`;
      return;
    }

    // Multi-process sketch: start ProbeAbility in :jsbay_probe; UI process must stay alive.
    try {
      const want: Want = {
        bundleName: 'com.example.jsbay.eventwaiter',
        abilityName: 'ProbeAbility',
        parameters: { mode: 'doc-skip' }
      };
      await this.ctx!.startAbility(want);
      hilog.info(DOMAIN, TAG, 'PASS: multi-process-probe-ability-start — UI process alive after startAbility(ProbeAbility)');
      console.info('PASS: multi-process-probe-ability-start');
    } catch (cause) {
      hilog.warn(DOMAIN, TAG, 'SKIP: multi-process-probe-ability-start — %{public}s', String(cause));
      console.warn(`SKIP: multi-process-probe-ability-start — ${String(cause)}`);
    }

    const marker = ok ? 'JSBAY_CRASHISO_PASS' : 'JSBAY_CRASHISO_FAIL';
    hilog.info(DOMAIN, TAG, '%{public}s', marker);
    console.info(marker);
    this.result = ok ? 'PASS: jsbay CrashIsolation' : 'FAIL: jsbay CrashIsolation';
  }

  build() {
    Column() {
      Text(this.result).fontSize(22).padding(24)
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
