import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';
import { Sha256 } from './Sha256';

/**
 * 家长锁：4 位数字 PIN，用来隐藏点播一级 / 二级分类里带敏感字样的项。
 *
 * 存储：文件里**不保存 PIN 本身**，只存随机盐 + 加盐迭代 SHA-256 摘要，
 * 校验时用同样的盐重新算一遍再比对。拿到文件也只能看到两串十六进制。
 *
 * 需要说清的边界：4 位数字只有 1 万种组合，摘要挡的是「一眼看到明文」，
 * 挡不住拿到文件后专门跑一遍 0000-9999 的暴力枚举（迭代轮数只是把这个成本
 * 乘上几千倍）。所以另加连续失败 5 次后锁定 60 秒的退避，正常人手输几乎
 * 不会碰到，脚本爆破会被拖慢。它面向的是「防小孩误点、防顺手翻到」，
 * 不是账户级安全边界。
 *
 * - 解锁状态不落盘，只存在进程内存里；**带 30 分钟有效期**。
 *   电视 App 进程可能连续挂好几天，早期只靠「冷启动 / 改 PIN」重新上锁，
 *   等于解锁一次＝长期解锁。
 *   现在解锁记时间戳，读的时候顺带查过期；首页另有 60s 巡检，停留不动也会自动上锁。
 * - **点播分类与播放历史是两份独立的解锁态**：在首页解锁受限分类，
 *   不等于允许别人翻历史记录，反之亦然；
 * - 关键词固定内置，不做编辑框：这几个词是站点分类的常见写法（「理论」是
 *   一些站对「伦理」的错写），放出来让人改反而容易漏。
 */
const F_PIN: string = 'tvbox_pin.json';
/** 解锁有效期：30 分钟。够看完一集，又不会让解锁态跟着长驻进程一起留好几天 */
const UNLOCK_TTL_MS: number = 30 * 60 * 1000;

/** 盐长度（字节） */
const SALT_BYTES: number = 16;
/**
 * 加盐之后再做多少轮 SHA-256。
 * 校验是同步的、跑在 UI 线程，电视 CPU 也弱，所以取「十毫秒级」的量，
 * 不追求密码学的理想参数 —— 4 位 PIN 的瓶颈在熵，不在轮数。
 */
const ROUNDS: number = 4000;
/** 连续错几次开始退避 */
const MAX_FAIL: number = 5;
/** 退避时长：60 秒 */
const LOCK_MS: number = 60 * 1000;

const WORDS: string[] = ['伦理', '理论', '福利', '三级', '性', '色情', '情色', '写真', '擦边'];

/** 落盘结构：只放盐与摘要，任何字段都不含 PIN 原文 */
interface PinRec {
  v?: number;      // 格式版本，当前 2
  s?: string;      // 盐（hex）
  h?: string;      // PBKDF2 摘要（hex）
  i?: number;      // 迭代次数
  f?: number;      // 连续失败次数
  u?: number;      // 锁定到的时刻（毫秒时间戳），0 = 未锁
}

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

  // ---------------- 摘要 ----------------

  /**
   * 生成盐。盐只要求「同一个 PIN 每次设置都不一样」，不要求不可预测，
   * 所以用 Math.random 就够 —— 而且 tv 设备上没有可用的系统随机数接口。
   */
  private static randomSalt(): Uint8Array {
    const salt: Uint8Array = new Uint8Array(SALT_BYTES);
    for (let i = 0; i < SALT_BYTES; i++) {
      salt[i] = Math.floor(Math.random() * 256);
    }
    return salt;
  }

  /** 读盘；文件不存在 / 不是本格式（含早期明文格式）都返回 null，按「没设 PIN」处理 */
  private static read(ctx: common.Context): PinRec | null {
    const txt: string = FileStore.readText(ctx, F_PIN) ?? '';
    if (txt.length === 0 || txt.charAt(0) !== '{') {
      return null;
    }
    try {
      const r = JSON.parse(txt) as PinRec;
      if ((r.s ?? '').length === 0 || (r.h ?? '').length === 0) {
        return null;
      }
      return r;
    } catch (e) {
      return null;
    }
  }

  private static write(ctx: common.Context, r: PinRec): boolean {
    return FileStore.writeText(ctx, F_PIN, JSON.stringify(r));
  }

  // ---------------- 对外接口 ----------------

  /**
   * PIN 的「指纹」：设过就返回摘要前 8 个字符，没设返回空串。
   *
   * 页面用它做两件事：判断有没有设置（长度 > 0），以及从设置页回来时
   * 判断 PIN 有没有被改过（指纹变了）。**拿不到 PIN 原文。**
   */
  static get(ctx: common.Context): string {
    const r: PinRec | null = PinStore.read(ctx);
    if (r === null) {
      return '';
    }
    const h: string = r.h ?? '';
    return h.length >= 8 ? h.substring(0, 8) : h;
  }

  /** 是否已设置 */
  static isSet(ctx: common.Context): boolean {
    return PinStore.get(ctx).length > 0;
  }

  /**
   * 校验输入。通过返回空串；不通过返回可以直接显示给用户的提示。
   * 连续错 MAX_FAIL 次锁定 LOCK_MS，期间直接拒绝，不再算摘要。
   */
  static verify(ctx: common.Context, input: string): string {
    const r: PinRec | null = PinStore.read(ctx);
    if (r === null) {
      return '还没有设置 PIN';
    }
    const now: number = Date.now();
    const until: number = r.u ?? 0;
    if (until > now) {
      const left: number = Math.ceil((until - now) / 1000);
      return '错误次数过多，请 ' + left + ' 秒后再试';
    }
    const v: string = (input ?? '').trim();
    const salt: Uint8Array = Sha256.fromHex(r.s ?? '');
    const rounds: number = (r.i ?? ROUNDS) > 0 ? (r.i as number) : ROUNDS;
    const calc: string = Sha256.toHex(Sha256.stretch(v, salt, rounds));
    if (calc === (r.h ?? '')) {
      if ((r.f ?? 0) > 0 || until !== 0) {
        r.f = 0;
        r.u = 0;
        PinStore.write(ctx, r);
      }
      return '';
    }
    // 失败：累计次数，够数就锁一段时间
    const fails: number = (r.f ?? 0) + 1;
    if (fails >= MAX_FAIL) {
      r.f = 0;
      r.u = now + LOCK_MS;
      PinStore.write(ctx, r);
      return '错误次数过多，请 ' + Math.ceil(LOCK_MS / 1000) + ' 秒后再试';
    }
    r.f = fails;
    PinStore.write(ctx, r);
    const left: number = MAX_FAIL - fails;
    return left <= 2 ? 'PIN 不对，还可以试 ' + left + ' 次' : 'PIN 不对，再试一次';
  }

  /** 设置 / 修改 PIN：生成新盐重新摘要，文件里只有盐和摘要 */
  static set(ctx: common.Context, pin: string): boolean {
    const v: string = (pin ?? '').trim();
    if (!/^\d{4}$/.test(v)) {
      return false;
    }
    const salt: Uint8Array = PinStore.randomSalt();
    const rec: PinRec = {
      v: 2,
      s: Sha256.toHex(salt),
      h: Sha256.toHex(Sha256.stretch(v, salt, ROUNDS)),
      i: ROUNDS,
      f: 0,
      u: 0
    };
    PinStore.relock();   // 改了 PIN 就重新上锁
    return PinStore.write(ctx, rec);
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

  static words(): string {
    let s: string = '';
    for (const w of WORDS) {
      s += (s.length > 0 ? ' / ' : '') + w;
    }
    return s;
  }
}
