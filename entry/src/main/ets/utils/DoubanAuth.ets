import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';

/**
 * 豆瓣登录态（可选功能）。
 *
 * 为什么需要：豆瓣的按名搜索接口（rexxar /v2/search/subjects）对未登录请求有
 * IP 级风控，密集查几十个片名后会直接回 403，整批倒退回「一个分都补不上」。
 * 带上登录 Cookie（dbcl2）后，豆瓣把你当正常用户，配额宽松得多。
 *
 * 为什么不做「账号密码登录」：
 *   豆瓣网页登录必须过滑块验证码，电视上用遥控器既不好输入、也没法拖滑块，
 *   任何非浏览器的登录接口都会回 1287 / 需要验证码，做不了。
 *   所以只接受「别处已登录，把 Cookie 带过来」这一条路：
 *   电脑/手机浏览器登录豆瓣 → 开发者工具 → Network → 任一请求 → 复制 Cookie 头。
 *   Cookie 很长，电视上打字痛苦，所以设置页同时提供「手机扫码推送」。
 *
 * 只挑需要的键：其余键（__utmz、_pk_ref 之类）带上去只会让请求头变脏，
 * 甚至触发服务端对异常 Cookie 的校验，所以按白名单过滤。
 */
const F_COOKIE: string = 'tvbox_douban_cookie.json';

/** 豆瓣登录态真正认的是 dbcl2；bid 是匿名浏览器 ID，登录后也有，一起带上更自然 */
const KEEP_KEYS: string[] = [
  'bid', 'dbcl2', 'ck', 'll', 'frodotk_db', 'push_notification_code',
  'push_notification_code_3', 'push_notification_code_2', 'ap_v', '_pk_id'
];

interface SavedCookie {
  /** 过滤后的 cookie 串，形如 bid=xxx; dbcl2="123:abc" */
  c?: string;
  /** 豆瓣用户名（验证通过后写入，仅用于界面显示） */
  u?: string;
  /** 豆瓣数字 ID（= dbcl2 冒号前的部分） */
  i?: string;
  /** 保存时间，用来提示"可能过期" */
  t?: number;
}

export class DoubanAuth {
  private static cookie: string = '';
  private static uname: string = '';
  private static uid: string = '';
  private static savedAt: number = 0;
  private static loaded: boolean = false;

  static init(ctx: common.Context): void {
    if (DoubanAuth.loaded) {
      return;
    }
    DoubanAuth.loaded = true;
    const txt: string = FileStore.readText(ctx, F_COOKIE);
    if (!txt) {
      return;
    }
    try {
      const d = JSON.parse(txt) as SavedCookie;
      DoubanAuth.cookie = (d.c ?? '').trim();
      DoubanAuth.uname = (d.u ?? '').trim();
      DoubanAuth.uid = (d.i ?? '').trim();
      DoubanAuth.savedAt = d.t ?? 0;
      if (DoubanAuth.uid.length === 0) {
        DoubanAuth.uid = DoubanAuth.uidOf(DoubanAuth.cookie);
      }
    } catch (e) {
      // 文件损坏：当作未登录
      DoubanAuth.cookie = '';
    }
  }

  /** 请求头用的 Cookie 串；没登录就是空串（调用方不要发空 Cookie 头） */
  static get(): string {
    return DoubanAuth.cookie;
  }

  /** 有登录态（dbcl2 存在）才算登录，光有 bid 只是匿名 */
  static has(): boolean {
    return DoubanAuth.uid.length > 0 && DoubanAuth.cookie.indexOf('dbcl2=') >= 0;
  }

  /** 用户名（只能叫 userName：static name() 会和 Function.name 撞） */
  static userName(): string {
    return DoubanAuth.uname;
  }

  static id(): string {
    return DoubanAuth.uid;
  }

  static savedTime(): number {
    return DoubanAuth.savedAt;
  }

  /** 界面上别把完整 Cookie 露出来：只显示用户名 + dbcl2 尾号 */
  static summary(): string {
    if (!DoubanAuth.has()) {
      return '未登录';
    }
    const who: string = DoubanAuth.uname.length > 0 ? DoubanAuth.uname : ('ID ' + DoubanAuth.uid);
    let tail: string = '';
    const i: number = DoubanAuth.cookie.indexOf('dbcl2=');
    if (i >= 0) {
      let v: string = DoubanAuth.cookie.substring(i + 6);
      const semi: number = v.indexOf(';');
      if (semi >= 0) {
        v = v.substring(0, semi);
      }
      v = v.replace(/"/g, '');
      tail = v.length > 4 ? v.substring(v.length - 4) : v;
    }
    return who + '（dbcl2 ****' + tail + '）';
  }

  /** dbcl2="123456:hash" → 123456；没有就是空串 */
  private static uidOf(cookie: string): string {
    const i: number = cookie.indexOf('dbcl2=');
    if (i < 0) {
      return '';
    }
    let v: string = cookie.substring(i + 6);
    const semi: number = v.indexOf(';');
    if (semi >= 0) {
      v = v.substring(0, semi);
    }
    v = v.trim().replace(/"/g, '');
    const colon: number = v.indexOf(':');
    const uid: string = colon > 0 ? v.substring(0, colon) : '';
    return /^\d+$/.test(uid) ? uid : '';
  }

  /**
   * 把粘贴来的文本收成一段干净 Cookie。
   * 兼容几种常见复制形态：整行 "Cookie: a=1; b=2"、多行（换行分隔）、
   * 带引号、全角分号、以及只贴了 dbcl2=... 的片段。
   * 返回空串表示这段文本里没有任何可用键。
   */
  static normalize(raw: string): string {
    let s: string = (raw ?? '').replace(/[\r\n\t]+/g, ';');
    s = s.replace(/cookie\s*:/i, '');
    s = s.replace(/[；]/g, ';');
    s = s.replace(/\u3000/g, ' ');
    const parts: string[] = s.split(';');
    const kept: string[] = [];
    const seen: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      const eq: number = p.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const k: string = p.substring(0, eq).trim();
      let v: string = p.substring(eq + 1).trim();
      v = v.replace(/^"+|"+$/g, '');
      if (k.length === 0 || v.length === 0) {
        continue;
      }
      if (KEEP_KEYS.indexOf(k) < 0 || seen.indexOf(k) >= 0) {
        continue;
      }
      seen.push(k);
      // dbcl2 必须带引号，豆瓣是这么判的；其他键原样
      kept.push(k + '=' + (k === 'dbcl2' ? '"' + v + '"' : v));
    }
    return kept.join('; ');
  }

  /**
   * 保存。返回 true 表示拿到了登录态（dbcl2 可解析出数字 ID），
   * false 表示这段文本里没有可用的登录信息。
   */
  static setRaw(ctx: common.Context, raw: string): boolean {
    const c: string = DoubanAuth.normalize(raw);
    if (c.length === 0) {
      return false;
    }
    const uid: string = DoubanAuth.uidOf(c);
    DoubanAuth.cookie = c;
    DoubanAuth.uid = uid;
    DoubanAuth.uname = '';
    DoubanAuth.savedAt = Date.now();
    DoubanAuth.save(ctx);
    return uid.length > 0;
  }

  /** 联网验证通过后回填用户名（只用于显示，不影响鉴权） */
  static confirmName(ctx: common.Context, name: string): void {
    DoubanAuth.uname = (name ?? '').trim();
    DoubanAuth.savedAt = Date.now();
    DoubanAuth.save(ctx);
  }

  private static save(ctx: common.Context): void {
    const d: SavedCookie = {
      c: DoubanAuth.cookie,
      u: DoubanAuth.uname,
      i: DoubanAuth.uid,
      t: DoubanAuth.savedAt
    };
    FileStore.writeText(ctx, F_COOKIE, JSON.stringify(d));
  }

  static clear(ctx: common.Context): void {
    DoubanAuth.cookie = '';
    DoubanAuth.uname = '';
    DoubanAuth.uid = '';
    DoubanAuth.savedAt = 0;
    FileStore.remove(ctx, F_COOKIE);
  }
}
