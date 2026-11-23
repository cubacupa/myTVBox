import { common } from '@kit.AbilityKit';
import { HttpUtil } from './HttpUtil';
import { FileStore } from './FileStore';
import { EpgNowNext, EpgProg } from './EpgStore';
import { RadioApi } from './RadioApi';

/**
 * 电台节目单。
 *
 * 直播页那套 EpgStore 吃的是 xmltv（公开源），里面只有电视台，一条电台都没有，
 * 所以电台的「正在播」一直是空的。电台节目单得单独取。
 *
 * 数据是一份整站的 EPG：1744 个频道、每个频道几十条 [开始, 结束, 节目名]。
 * 频道名带频率后缀（「北京交通广播 FM103.9」），和我们库里的「北京交通广播」不是同一个串，
 * 所以匹配前两边都过一遍 norm()：去掉 FM/AM 及后面数字、去掉空格和分隔符。
 *
 * 整份 6.5MB 不适合电视每次拉，也不适合整份落盘：
 * 只留「今天 00:00 以后、到明天中午」这段，并按频道名归一化后存成本地小文件，电视只读它。
 */

const F_CACHE: string = 'tvbox_radio_epg.json';
const URL_EPG: string = 'https://cooltv.top/epg.json';
const BASE: string = 'https://cooltv.top';
const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

/** 节目单一天更新几次，12 小时够了；过期先用旧的，后台再换 */
const FRESH_MS: number = 12 * 3600000;
/** 往后留 36 小时，够看到明天中午 */
const AHEAD_MS: number = 36 * 3600000;

interface RawPack {
  /** id → 频道名（就是字符串，不是 {name} 对象） */
  channels?: Record<string, string>;
  /** id → [[开始, 结束, 节目名, ...], ...]，时间形如 20261122000000 */
  data?: Record<string, string[][]>;
}

/** 落盘用：编号式分列，比 [{s,e,t}] 省三成体积 */
interface PackChan {
  n: string;
  s: number[];
  e: number[];
  t: string[];
}

interface CachePack {
  at: number;
  ch: PackChan[];
}

export class RadioEpg {
  private static map: Map<string, EpgProg[]> = new Map<string, EpgProg[]>();
  private static at: number = 0;
  private static inited: boolean = false;
  private static loading: boolean = false;

  /** 读本地缓存到内存；没有就等 ensure 去拉 */
  static init(ctx: common.Context): void {
    if (RadioEpg.inited) {
      return;
    }
    RadioEpg.inited = true;
    const txt: string = FileStore.readText(ctx, F_CACHE);
    if (txt.length === 0) {
      return;
    }
    RadioEpg.apply(txt);
  }

  private static apply(txt: string): void {
    try {
      const pack = JSON.parse(txt) as CachePack;
      if (pack === null || !Array.isArray(pack.ch)) {
        return;
      }
      const m: Map<string, EpgProg[]> = new Map<string, EpgProg[]>();
      for (const c of pack.ch) {
        const arr: EpgProg[] = [];
        for (let i = 0; i < c.s.length; i++) {
          arr.push({ s: c.s[i], e: c.e[i], t: c.t[i] });
        }
        if (arr.length > 0) {
          m.set(c.n, arr);
        }
      }
      RadioEpg.map = m;
      RadioEpg.at = (typeof pack.at === 'number') ? pack.at : 0;
    } catch (e) {
      // 缓存坏了当没有
    }
  }

  static hasData(): boolean {
    return RadioEpg.map.size > 0;
  }

  static isFresh(): boolean {
    return RadioEpg.at > 0 && (Date.now() - RadioEpg.at) < FRESH_MS;
  }

  /** 后台准备：本地有新鲜的就不动，否则拉一份。返回是否拿到了新数据 */
  static async ensure(ctx: common.Context): Promise<boolean> {
    if (RadioEpg.loading) {
      return false;
    }
    if (RadioEpg.hasData() && RadioEpg.isFresh()) {
      return false;
    }
    RadioEpg.loading = true;
    try {
      // 整份 6.5MB，默认 12 秒读取超时不够用，这里放宽到 60 秒
      const text: string = await HttpUtil.getTextWithTimeout(URL_EPG, BASE + '/', UA, 15000, 60000);
      console.info('RADIO_EPG fetch ok, chars=' + text.length);
      const raw = JSON.parse(text) as RawPack;
      if (raw === null || raw.channels === undefined || raw.data === undefined) {
        console.info('RADIO_EPG shape unexpected');
        return false;
      }
      const now: number = Date.now();
      const d: Date = new Date(now);
      const todayStart: number = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      const horizon: number = now + AHEAD_MS;

      // 整站一万多条节目里，我们能播的只有库里那两千多个台：只留名字对得上的频道，
      // 落盘体积从 2.8MB 降到一兆出头，电视端建索引也快。
      const keep: Set<string> = new Set<string>();
      const pool = RadioApi.list();
      for (const st of pool) {
        const k: string = RadioEpg.norm(st.name);
        if (k.length > 0) {
          keep.add(k);
        }
      }
      const restrict: boolean = keep.size > 0;

      const out: PackChan[] = [];
      const chans: Record<string, string> = raw.channels;
      const datas: Record<string, string[][]> = raw.data;
      for (const id of Object.keys(chans)) {
        const nm: string = (chans[id] ?? '').trim();
        if (nm.length === 0) {
          continue;
        }
        if (restrict && !keep.has(RadioEpg.norm(nm))) {
          continue;
        }
        const list: string[][] | undefined = datas[id];
        if (list === undefined || list.length === 0) {
          continue;
        }
        const sArr: number[] = [];
        const eArr: number[] = [];
        const tArr: string[] = [];
        for (const row of list) {
          if (row.length < 3) {
            continue;
          }
          const st: number = RadioEpg.stamp(row[0]);
          const en: number = RadioEpg.stamp(row[1]);
          if (st <= 0 || en <= st) {
            continue;
          }
          // 只要今天已经播过的（节目单面板要能回看）和未来 36 小时
          if (en < todayStart || st > horizon) {
            continue;
          }
          sArr.push(st);
          eArr.push(en);
          tArr.push(row[2].trim());
        }
        if (sArr.length > 0) {
          out.push({ n: RadioEpg.norm(nm), s: sArr, e: eArr, t: tArr });
        }
      }
      if (out.length === 0) {
        console.info('RADIO_EPG no channel kept');
        return false;
      }
      const pack: CachePack = { at: now, ch: out };
      const json: string = JSON.stringify(pack);
      RadioEpg.apply(json);
      try {
        FileStore.writeText(ctx, F_CACHE, json);
      } catch (e) {
        // 落盘失败不影响本次使用
      }
      console.info('RADIO_EPG kept=' + out.length + ' bytes=' + json.length);
      return true;
    } catch (e) {
      console.info('RADIO_EPG failed: ' + (e as Error).message);
      return false;
    } finally {
      RadioEpg.loading = false;
    }
  }

  /**
   * 频道名归一：去掉 FM/AM 频率、空格、常见分隔符，统一小写。
   * 「北京交通广播 FM103.9」和「北京交通广播」归一到同一个 key。
   */
  static norm(name: string): string {
    let s: string = (name ?? '').trim();
    if (s.length === 0) {
      return '';
    }
    s = s.replace(/([FA]M)\s*\d+(\.\d+)?/gi, '');
    s = s.replace(/[\s\u3000·\-—_]+/g, '');
    return s.toLowerCase();
  }

  /** 20261122000000 → 本地时间毫秒 */
  private static stamp(v: string): number {
    if (v === undefined || v === null || v.length < 14) {
      return 0;
    }
    const y: number = Number(v.substring(0, 4));
    const mo: number = Number(v.substring(4, 6));
    const d: number = Number(v.substring(6, 8));
    const h: number = Number(v.substring(8, 10));
    const mi: number = Number(v.substring(10, 12));
    const se: number = Number(v.substring(12, 14));
    if (isNaN(y) || isNaN(mo) || isNaN(d)) {
      return 0;
    }
    return new Date(y, mo - 1, d, h, mi, se).getTime();
  }

  private static progsOf(name: string): EpgProg[] {
    if (!RadioEpg.hasData()) {
      return [];
    }
    const k: string = RadioEpg.norm(name);
    if (k.length === 0) {
      return [];
    }
    const hit: EpgProg[] | undefined = RadioEpg.map.get(k);
    if (hit !== undefined) {
      return hit;
    }
    // 少量台名会多带「广播/电台」这类尾巴，退一步按前缀找一次
    const keys: string[] = Array.from(RadioEpg.map.keys());
    for (const kk of keys) {
      if (kk.length >= 4 && (kk.indexOf(k) === 0 || k.indexOf(kk) === 0)) {
        const v: EpgProg[] | undefined = RadioEpg.map.get(kk);
        if (v !== undefined) {
          return v;
        }
      }
    }
    return [];
  }

  /** 当前在播与下一档；没有节目单返回 null */
  static nowNext(name: string): EpgNowNext | null {
    const list: EpgProg[] = RadioEpg.progsOf(name);
    if (list.length === 0) {
      return null;
    }
    const now: number = Date.now();
    let cur: EpgProg | null = null;
    let next: EpgProg | null = null;
    for (const p of list) {
      if (p.s <= now && now < p.e) {
        cur = p;
      } else if (p.s > now) {
        next = p;
        break;
      }
    }
    if (cur === null && next === null) {
      return null;
    }
    return { cur: cur, next: next };
  }

  /** 接下来 n 档 */
  static upcoming(name: string, n: number): EpgProg[] {
    const ret: EpgProg[] = [];
    const now: number = Date.now();
    for (const p of RadioEpg.progsOf(name)) {
      if (p.s > now) {
        ret.push(p);
        if (ret.length >= n) {
          break;
        }
      }
    }
    return ret;
  }

  /** 今天全天（含已经播完的），节目单面板用 */
  static day(name: string): EpgProg[] {
    const d: Date = new Date();
    const start: number = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    const end: number = start + 86400000;
    const ret: EpgProg[] = [];
    for (const p of RadioEpg.progsOf(name)) {
      // 只留今天：缓存里还有明天凌晨的节目，混进来会把「今日节目单」拖出一条尾巴
      if (p.s < end && p.e > start) {
        ret.push(p);
      }
    }
    return ret;
  }
}
