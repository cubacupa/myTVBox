import { common } from '@kit.AbilityKit';
import { HttpUtil } from './HttpUtil';
import { FileStore } from './FileStore';

/**
 * 网络电台库。
 *
 * 数据源是公开的电台总表（一份 JSON，两千多套台，每条带分类、地区、台标、
 * 以及多条直播流地址）。整表 1.2MB，一次拉完本地缓存 7 天，电视端只读本地文件，
 * 进页面不再等网络。
 *
 * 为什么不按台一个个查：那样要几百次请求，电视上光等就是几十秒；
 * 而直播流本来就自带多条线路，一次拿全反而更稳。
 *
 * 分类不做二次人工整理：数据的 category 是「中文流行 / 交通 / 综合 / 欧美流行」这种细分类，
 * 界面上归并成 新闻 / 音乐 / 交通 / 综合 / 国外 / 其他 六类就够用了（见 groupOf）。
 */

const F_CACHE: string = 'tvbox_radio.json';
const URL_ALL: string = 'https://cooltv.top/radio_public.json';
/** 电台表变化不快，7 天足够；过期了先用旧的，后台再换新的 */
const FRESH_MS: number = 7 * 24 * 3600000;
/** 站点是第三方聚合页，没有它能用的 UA 限制，但还是带浏览器的稳妥 */
const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';
const BASE: string = 'https://cooltv.top';

/**
 * 聚合表里失效的台，用公开直链顶上（key 是台名，新拉表和旧缓存都会替换）。
 * 上海交通广播的 4 条 cooltv 地址全 403，蜻蜓这条是 chunked 无 Content-Length，
 * 播放器不会被有界 Range 探测坑。
 */
const STREAM_FIX: Record<string, string> = {
  '上海交通广播': 'https://lhttp-hw.qtfm.cn/live/266/64k.mp3'
};

export interface RadioStation {
  /** 台 id，收藏/最近播放都按它记 */
  sid: string;
  name: string;
  /** 原始细分类（中文流行 / 交通 / 综合…） */
  cat: string;
  /** 地区（北京 / 国家台 / 空） */
  loc: string;
  country: string;
  logo: string;
  /** 直播流，按顺序试；可能一至三条 */
  streams: string[];
}

interface RawShazam {
  stream?: string;
}

interface RawStation {
  sid?: string;
  name?: string;
  category?: string;
  location?: string;
  country?: string;
  logo?: string;
  stream_url?: string;
  shazam?: RawShazam;
}

interface RawPack {
  update_time?: string;
  total?: number;
  data?: RawStation[];
}

interface CachePack {
  at: number;
  list: RadioStation[];
}

export class RadioApi {
  private static arr: RadioStation[] = [];
  private static loadedAt: number = 0;
  private static inited: boolean = false;
  private static loading: boolean = false;

  /** 内存里留一份：两千多条，翻分类/切 tab 不该反复读文件 */
  static init(ctx: common.Context): void {
    if (RadioApi.inited) {
      return;
    }
    RadioApi.inited = true;
    const txt: string = FileStore.readText(ctx, F_CACHE);
    if (txt.length === 0) {
      return;
    }
    try {
      const pack = JSON.parse(txt) as CachePack;
      if (pack !== null && Array.isArray(pack.list) && pack.list.length > 0) {
        // 旧缓存里还留着那些只能走 cooltv /proxy/ 的台（一律 403），读进来就丢掉，
        // 不用等 7 天缓存过期才生效
        const kept: RadioStation[] = [];
        for (const s of pack.list) {
          const good: string[] = RadioApi.streamsFor(s.name, s.streams);
          if (good.length > 0) {
            kept.push({ sid: s.sid, name: s.name, cat: s.cat, loc: s.loc,
              country: s.country, logo: s.logo, streams: good });
          }
        }
        RadioApi.arr = kept;
        RadioApi.loadedAt = (typeof pack.at === 'number') ? pack.at : 0;
      }
    } catch (e) {
      // 缓存坏了就当没有，下次 load() 会重下
    }
  }

  static has(): boolean {
    return RadioApi.arr.length > 0;
  }

  static list(): RadioStation[] {
    return RadioApi.arr;
  }

  static count(): number {
    return RadioApi.arr.length;
  }

  static ageText(): string {
    if (RadioApi.loadedAt <= 0) {
      return '';
    }
    const h: number = Math.floor((Date.now() - RadioApi.loadedAt) / 3600000);
    if (h < 1) {
      return '刚刚更新';
    }
    if (h < 24) {
      return h + ' 小时前更新';
    }
    return Math.floor(h / 24) + ' 天前更新';
  }

  static isFresh(): boolean {
    return RadioApi.loadedAt > 0 && (Date.now() - RadioApi.loadedAt) < FRESH_MS;
  }

  /**
   * 拉整表并落盘。返回空串表示成功，否则是给界面看的错误文案。
   * force=false 时，缓存还新鲜就直接跳过（不打扰用户）。
   */
  static async load(ctx: common.Context, force: boolean): Promise<string> {
    if (RadioApi.loading) {
      return '';
    }
    if (!force && RadioApi.has() && RadioApi.isFresh()) {
      return '';
    }
    RadioApi.loading = true;
    try {
      const text: string = await HttpUtil.getTextWith(URL_ALL, BASE + '/', UA);
      const raw = JSON.parse(text) as RawPack;
      const list: RadioStation[] = [];
      const src: RawStation[] = (raw !== null && Array.isArray(raw.data)) ? raw.data : [];
      for (const r of src) {
        const s: RadioStation | null = RadioApi.normalize(r);
        if (s !== null) {
          list.push(s);
        }
      }
      if (list.length === 0) {
        return '电台表为空';
      }
      RadioApi.arr = list;
      RadioApi.loadedAt = Date.now();
      const pack: CachePack = { at: RadioApi.loadedAt, list: list };
      FileStore.writeText(ctx, F_CACHE, JSON.stringify(pack));
      return '';
    } catch (e) {
      return (e as Error).message;
    } finally {
      RadioApi.loading = false;
    }
  }

  private static normalize(r: RawStation): RadioStation | null {
    const name: string = (r.name ?? '').trim();
    if (name.length === 0) {
      return null;
    }
    const streams: string[] = [];
    const raw: string = (r.stream_url ?? '');
    if (raw.length > 0) {
      for (const one of raw.split(';')) {
        const u: string = RadioApi.fullUrl(one);
        if (u.length > 0 && streams.indexOf(u) < 0) {
          streams.push(u);
        }
      }
    }
    const alt: string = RadioApi.fullUrl((r.shazam !== undefined ? (r.shazam.stream ?? '') : ''));
    if (alt.length > 0 && streams.indexOf(alt) < 0) {
      streams.unshift(alt);
    }
    const good: string[] = RadioApi.streamsFor(name, streams);
    if (good.length === 0) {
      // 没有可用流的台直接丢掉，列表里点不开的台是最烦人的
      return null;
    }
    const sid: string = (r.sid ?? '').trim();
    return {
      sid: sid.length > 0 ? sid : name,
      name: name,
      cat: (r.category ?? '').trim(),
      loc: (r.location ?? '').trim(),
      country: (r.country ?? '').trim(),
      logo: (r.logo ?? '').trim(),
      streams: good
    };
  }

  /**
   * 表里 707 条是 `/proxy/...` 这种相对地址，cooltv 的代理必须带 Referer 才给流，
   * 播放器带不过去（实测一律 403），这些台直接不要，免得用户点了全是「线路都连不上」。
   * `//host/...` 是协议相对地址，可以照常补 https。
   */
  private static fullUrl(u: string): string {
    const t: string = (u ?? '').trim();
    if (t.length === 0) {
      return '';
    }
    if (t.indexOf('//') === 0) {
      return 'https:' + t;
    }
    if (t.indexOf('/') === 0) {
      return '';
    }
    if (/^https?:\/\//i.test(t)) {
      return t;
    }
    return '';
  }

  /** 新拉表和读旧缓存都要过：失效台换成公开直链，其余剔除 cooltv 代理 */
  private static streamsFor(name: string, streams: string[]): string[] {
    const fix: string = STREAM_FIX[name] ?? '';
    if (fix.length > 0) {
      return [fix];
    }
    return RadioApi.usableStreams(streams);
  }

  /** 缓存里可能还有旧版本写进去的 /proxy/ 台，读盘和列表生成都过一遍 */
  private static usableStreams(streams: string[]): string[] {
    return streams.filter((u: string): boolean => u.indexOf('cooltv.top/proxy') < 0);
  }

  /**
   * 界面上的六个大类。原始分类是几十种细分类（中文流行 / 怀旧金曲 / 电子舞曲…），
   * 直接铺给用户选会变成一堵墙。归并规则宁粗不细：宁可少一个分类，也不要十个冷门类。
   */
  static groupOf(s: RadioStation): string {
    if (s.country.length > 0 && s.country !== '中国') {
      return '国外';
    }
    const c: string = s.cat;
    // 源里国内台没有单独的新闻类，news 都混在「综合」里，硬拆会得到一个只有 1 个台的分类，
    // 所以新闻/谈话并进综合，分类列表里也不再单列新闻。
    if (c.indexOf('交通') >= 0) {
      return '交通';
    }
    if (c.indexOf('音乐') >= 0 || c.indexOf('流行') >= 0 || c.indexOf('古典') >= 0
      || c.indexOf('爵士') >= 0 || c.indexOf('摇滚') >= 0 || c.indexOf('金曲') >= 0
      || c.indexOf('舞曲') >= 0 || c.indexOf('乡村') >= 0 || c.indexOf('嘻哈') >= 0) {
      return '音乐';
    }
    if (c.indexOf('综合') >= 0 || c.indexOf('网络') >= 0 || c.indexOf('电视') >= 0) {
      return '综合';
    }
    return '其他';
  }

  /** 分类下拉里的条目，顺序即展示顺序 */
  static groups(): string[] {
    return ['全部电台', '音乐', '交通', '综合', '国外', '其他'];
  }

  static countOf(group: string): number {
    if (group === '全部电台') {
      return RadioApi.arr.length;
    }
    let n: number = 0;
    for (const s of RadioApi.arr) {
      if (RadioApi.groupOf(s) === group) {
        n++;
      }
    }
    return n;
  }

  static find(sid: string): RadioStation | null {
    for (const s of RadioApi.arr) {
      if (s.sid === sid) {
        return s;
      }
    }
    return null;
  }

  /**
   * 精选六格。
   *
   * 不用「排行榜」——那种数据每天都在变，昨晚的第六名今天可能是个没人听的小台，
   * 而这几格是给用户当快捷键用的，稳定比新鲜重要。按名字挑，挑不到就顺位补。
   */
  private static readonly PRESET_NAMES: string[] = [
    '中国之声', '音乐之声', '经济之声', '环球资讯广播', '华语环球广播',
    '北京交通广播', '北京音乐广播', '北京新闻广播', '上海新闻广播', '上海交通广播',
    '第一财经广播', '动感101', '长三角之声', '经典947', 'BBC World Service'
  ];
  /** 精选格数：3 行 × 5 列 */
  private static readonly PRESET_N: number = 15;

  static presets(): RadioStation[] {
    const out: RadioStation[] = [];
    const used: Set<string> = new Set<string>();
    for (const want of RadioApi.PRESET_NAMES) {
      const hit: RadioStation | null = RadioApi.matchName(want);
      if (hit !== null && !used.has(hit.sid)) {
        out.push(hit);
        used.add(hit.sid);
      }
    }
    if (out.length < RadioApi.PRESET_N) {
      // 兜底：先补中央/国家台，再补任何有台标的台，保证格子不空
      for (const s of RadioApi.arr) {
        if (out.length >= RadioApi.PRESET_N) {
          break;
        }
        if (used.has(s.sid)) {
          continue;
        }
        if (s.logo.length > 0) {
          out.push(s);
          used.add(s.sid);
        }
      }
    }
    return out;
  }

  /** 名字匹配：先全等，再包含（「北京交通广播」vs「北京交通广播 FM103.9」） */
  private static matchName(want: string): RadioStation | null {
    for (const s of RadioApi.arr) {
      if (s.name === want) {
        return s;
      }
    }
    for (const s of RadioApi.arr) {
      if (s.name.indexOf(want) >= 0 || want.indexOf(s.name) >= 0) {
        return s;
      }
    }
    return null;
  }
}
