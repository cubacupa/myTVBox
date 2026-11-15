import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';

/**
 * 家长锁：4 位数字 PIN，用来隐藏点播一级 / 二级分类里带敏感字样的项。
 *
 * 设计取舍：
 * - PIN 只存本地私有目录，明文即可（这是防误触的家长锁，不是金融级凭据）；
 * - 解锁状态不落盘，只存在进程内存里；**带 30 分钟有效期**。
 *   电视 App 进程可能几周不被杀，早期版本只靠「冷启动 / 改 PIN」才重新上锁，
 *   实测解锁一次后 PID 连挂 6 天，等于永久解锁（用户报的「锁定失效」即此）。
 *   现在解锁记时间戳，读的时候顺带查过期；首页另有 60s 巡检，停留不动也会自动上锁。
 * - **点播分类与播放历史是两份独立的解锁态**：在首页解锁受限分类，
 *   不等于允许别人翻历史记录，反之亦然；
 * - 关键词固定内置，不做编辑框：这几个词是站点分类的常见写法（「理论」是
 *   一些站对「伦理」的错写），放出来让人改反而容易漏。
 */
const F_PIN: string = 'tvbox_pin.json';
/** 解锁有效期：30 分钟。够看完一集，又不会让解锁态跟着长驻进程一起留好几天 */
const UNLOCK_TTL_MS: number = 30 * 60 * 1000;
const WORDS: string[] = ['伦理', '理论', '福利', '三级', '性', '色情', '情色', '写真', '擦边'];

export class PinStore {
  /** 点播分类 / 历史页各自的解锁态与解锁时刻（进程内存，不落盘） */
  private static vodUnlocked: boolean = false;
  private static vodAt: number = 0;
  private static hisUnlocked: boolean = false;
  private static hisAt: number = 0;

  /** 输对 PIN 时开一个有时效的解锁窗口；两边各开各的 */
  static unlockVod(): void {
    PinStore.vodUnlocked = true;
    PinStore.vodAt = Date.now();
  }

  static unlockHistory(): void {
    PinStore.hisUnlocked = true;
    PinStore.hisAt = Date.now();
  }

  /** 读解锁态时顺带做过期检查：超时就当场清掉，不需要额外定时器兜底 */
  static isVodUnlocked(): boolean {
    if (PinStore.vodUnlocked && Date.now() - PinStore.vodAt > UNLOCK_TTL_MS) {
      PinStore.vodUnlocked = false;
      PinStore.vodAt = 0;
    }
    return PinStore.vodUnlocked;
  }

  static isHistoryUnlocked(): boolean {
    if (PinStore.hisUnlocked && Date.now() - PinStore.hisAt > UNLOCK_TTL_MS) {
      PinStore.hisUnlocked = false;
      PinStore.hisAt = 0;
    }
    return PinStore.hisUnlocked;
  }

  /** 手动「重新上锁」：只收点播分类，不影响历史页 */
  static lockVod(): void {
    PinStore.vodUnlocked = false;
    PinStore.vodAt = 0;
  }

  /** 手动「重新上锁」：只收历史页 */
  static lockHistory(): void {
    PinStore.hisUnlocked = false;
    PinStore.hisAt = 0;
  }

  /** 改 / 清 PIN、或检测到 PIN 被改动时，两处一起重新上锁 */
  static relock(): void {
    PinStore.lockVod();
    PinStore.lockHistory();
  }

  /** 返回已设置的 4 位 PIN；没设置或内容不合法都返回空串 */
  static get(ctx: common.Context): string {
    const v: string = (FileStore.readText(ctx, F_PIN) ?? '').trim();
    return /^\d{4}$/.test(v) ? v : '';
  }

  static set(ctx: common.Context, pin: string): boolean {
    const v: string = (pin ?? '').trim();
    if (!/^\d{4}$/.test(v)) {
      return false;
    }
    PinStore.relock();   // 改了 PIN 就重新上锁
    return FileStore.writeText(ctx, F_PIN, v);
  }

  static clear(ctx: common.Context): void {
    FileStore.remove(ctx, F_PIN);
    PinStore.relock();
  }

  /** 分类名里含任一词就归为受限分类 */
  static isRestricted(name: string): boolean {
    const n: string = name ?? '';
    for (const w of WORDS) {
      if (n.indexOf(w) >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 界面统一判定：这个名字现在该不该藏。
   * 只有「已设 PIN 且当前没解锁」才藏；没设 PIN 等于没开家长锁，一律放行。
   * pin 传 PinStore.get() 的结果（没设置就是空串）。
   */
  static shouldHide(name: string, pin: string, unlocked: boolean): boolean {
    return (pin ?? '').length === 4 && !unlocked && PinStore.isRestricted(name);
  }

  static words(): string {
    let s: string = '';
    for (const w of WORDS) {
      s += (s.length > 0 ? ' / ' : '') + w;
    }
    return s;
  }
}
