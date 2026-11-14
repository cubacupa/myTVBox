import { AbilityConstant, UIAbility, Want, ConfigurationConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN: number = 0x0000;
const TAG: string = 'MovieBox';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    // 本应用全部页面都是深色底，强制深色配色。
    // 否则设备处于浅色模式时，按钮/文字的默认颜色是近黑色，深色底上会看不清。
    try {
      this.context.getApplicationContext()
        .setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setColorMode failed: %{public}s', (e as Error).message);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Home', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
        return;
      }
      // TV 大屏：强制横屏，并隐藏状态栏，给视频/海报最大可用空间
      windowStage.getMainWindow().then((win: window.Window) => {
        win.setPreferredOrientation(window.Orientation.LANDSCAPE);
        win.setWindowLayoutFullScreen(true).catch((e: Error) => {
          hilog.error(DOMAIN, TAG, 'setFullScreen failed: %{public}s', e.message);
        });
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }
}
