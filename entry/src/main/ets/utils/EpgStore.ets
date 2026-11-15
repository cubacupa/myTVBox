import { common } from '@kit.AbilityKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { HttpUtil } from './HttpUtil';
import { FileStore } from './FileStore';

/**
 * EPG（节目单）：解析 XMLTV，供直播页显示「正在播 / 接下来」。
 *
 * 为什么自己写扫描而不上 XmlPullParser：
 *   1) xmltv 是极规整的扁平结构（<channel> 与 <programme> 两个元素，属性在开始标签里），
 *      用「找 '<programme' → 找下一个 '</programme>' → 只在这小段里取属性」足够，
 *      不需要处理命名空间、嵌套、实体转义那些边角；
 *   2) 一份 xmltv 解压后十几到几十 MB，事件式解析要遍历全部节点，
 *      而扫描只对命中 '<programme' 的位置做局部 substring，快一个量级；
 *   3) 不依赖 attributeValueCallbackFunction 的触发顺序（那个顺序在文档里没保证）。
 *
 * gzip：`.xml.gz` 用 zlib.GZip 的 gzopen/gzread 流式读。官方文档明确写「非 gzip 文件
 *   会按原始数据直接读出」，所以 .xml 与 .xml.gz 共用一个读取路径，不用先嗅探魔数。
 *
 * 缓存：只留 [now-6h, now+36h] 的节目（再往上没意义，还占内存），
 *   存成 filesDir/tvbox_epg.json，12 小时内不重复下载。
 *   channel 只存 id 与 display-name：匹配 tvg-id 为主，匹配不上再按名字归一化兜底。
 */

const F_CACHE: string = 'tvbox_epg.json';
const F_RAW: string = 'tvbox_epg_raw.bin';
const TAG: string = 'EpgStore';

/**
 * 内置 xmltv 源，按顺序尝试，前一个拉不到 / 解析不出频道就自动换下一个。
 * 不暴露给用户配置；加源减源只改这个数组。
 *
 * 顺序原则：先小后大、先稳后补。
 *   1) laobaiepg：gzip 只有 400KB 左右，国内直连最稳，正常一次就成；
 *   2) 51zmt：明文 http，频道 100 个左右、节目量足，作为第二道；
 *   3) jsdelivr 上的 fanmingming/e.xml：7~8MB 纯 xml，覆盖广但最大最慢，留最后兜底。
 * 前一个成功后会把成功地址写进缓存，缓存里的地址只用于判断新鲜度。
 */
const EPG_SOURCES: string[] = [
  'https://laobaiepg.laobaitv.net/guide.xml.gz',
  'http://epg.51zmt.top:8000/e.xml',
  'https://gcore.jsdelivr.net/gh/fanmingming/live@main/e.xml'
];

const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

const HOUR: number = 3600000;
/** 节目表保留窗口：往前 6 小时（刚播完的还能看到「正在播」尾巴）、往后 36 小时 */
const KEEP_BEFORE: number = 6 * HOUR;
const KEEP_AFTER: number = 36 * HOUR;
/** 缓存有效期：过了就重下（xmltv 一般每天更新几次） */
const FRESH_MS: number = 12 * HOUR;
/** 解压后的上限，防止异常文件把内存吃光 */
const MAX_TEXT: number = 48 * 1024 * 1024;

export interface EpgProg {
  /** 开始时间（毫秒时间戳） */
  s: number;
  /** 结束时间 */
  e: number;
  /** 节目名 */
  t: string;
}

export interface EpgChan {
  id: string;
  name: string;
  /** 同一个频道的其它 display-name（AnhuiTV / 安徽卫视 / AHTV…），只用于名字兜底匹配 */
  aliases: string[];
  progs: EpgProg[];
}

/**
 * 英文台名 → 标准中文台名。
 *
 * 为什么需要这张表：iptv-org 这类直播源用的是英文台名（Hunan TV / Nei Monggol TV / Jade），
 * 而国内公共 xmltv 用的是中文台名（湖南卫视 / 内蒙古卫视 / TVB 翡翠台），
 * 两边 norm 之后再比也对不上 —— 归一化只能抹平写法差异，抹不平语言差异。
 *
 * 匹配顺序：tvg-id → tvg-id 去国家后缀 → 频道名（含全部 display-name 别名）→ **本表**。
 * 键写**裸名**（小写、去空格标点），匹配时会先剥掉末尾的 tv / television / satellite 再试，
 * 所以一条 `hunan` 就能覆盖 "Hunan TV" / "Hunan Satellite TV"。
 * 值用 laobaiepg 与 epg.pw 都认的中文台名写法。
 *
 * 注意只收**确实能从英文名唯一确定**的台。「Hunan Economy Channel」（湖南经视）、
 * 「Qingdao TV」（青岛台）这种带副标题的地方台不要往里塞，塞了就会配错台。
 */
interface EnAlias {
  en: string;
  cn: string;
}

const EN_ALIASES: EnAlias[] = [
  // ---- 央视：CCTV1~17 靠 tvg-id 去掉 .cn 就能命中，这里只补带地区/语言后缀的 ----
  { en: 'cctv4asia', cn: 'CCTV-4 中文国际' },
  { en: 'cctv4europe', cn: 'CCTV-4 欧洲' },
  { en: 'cctv4america', cn: 'CCTV-4 美洲' },
  { en: 'cctv4k', cn: 'CCTV-4K 超高清' },
  { en: 'cctv5plus', cn: 'CCTV-5+ 体育赛事' },
  { en: 'cgtndocumentary', cn: 'CGTN 纪录' },
  { en: 'cgtnarabic', cn: 'CGTN 阿语' },
  { en: 'cgtnfrench', cn: 'CGTN 法语' },
  { en: 'cgtnrussian', cn: 'CGTN 俄语' },
  { en: 'cgtnspanish', cn: 'CGTN 西语' },

  // ---- 省级卫视 ----
  { en: 'hunan', cn: '湖南卫视' },
  { en: 'zhejiang', cn: '浙江卫视' },
  { en: 'jiangsu', cn: '江苏卫视' },
  { en: 'dragon', cn: '东方卫视' },
  { en: 'shanghai', cn: '东方卫视' },
  { en: 'anhui', cn: '安徽卫视' },
  { en: 'shandong', cn: '山东卫视' },
  { en: 'sichuan', cn: '四川卫视' },
  { en: 'henan', cn: '河南卫视' },
  { en: 'guangdong', cn: '广东卫视' },
  { en: 'chongqing', cn: '重庆卫视' },
  { en: 'liaoning', cn: '辽宁卫视' },
  { en: 'hubei', cn: '湖北卫视' },
  { en: 'jiangxi', cn: '江西卫视' },
  { en: 'shanxi', cn: '山西卫视' },
  { en: 'shaanxi', cn: '陕西卫视' },
  { en: 'yunnan', cn: '云南卫视' },
  { en: 'guizhou', cn: '贵州卫视' },
  { en: 'gansu', cn: '甘肃卫视' },
  { en: 'heilongjiang', cn: '黑龙江卫视' },
  { en: 'jilin', cn: '吉林卫视' },
  { en: 'tianjin', cn: '天津卫视' },
  { en: 'hainan', cn: '海南卫视' },
  { en: 'neimonggol', cn: '内蒙古卫视' },
  { en: 'innermongolia', cn: '内蒙古卫视' },
  { en: 'xinjiang', cn: '新疆卫视' },
  { en: 'xizang', cn: '西藏卫视' },
  { en: 'xizangtvchinese', cn: '西藏卫视' },
  { en: 'xizangtvtibetan', cn: '西藏卫视' },
  { en: 'tibet', cn: '西藏卫视' },
  { en: 'ningxia', cn: '宁夏卫视' },
  { en: 'qinghai', cn: '青海卫视' },
  { en: 'guangxi', cn: '广西卫视' },
  { en: 'beijing', cn: '北京卫视' },
  { en: 'btv', cn: '北京卫视' },
  { en: 'shenzhen', cn: '深圳卫视' },
  { en: 'sztv', cn: '深圳卫视' },
  { en: 'xiamen', cn: '厦门卫视' },
  { en: 'hebei', cn: '河北卫视' },
  { en: 'setv', cn: '东南卫视' },
  { en: 'southeast', cn: '东南卫视' },
  { en: 'fujian', cn: '东南卫视' },
  { en: 'dawanqu', cn: '大湾区卫视' },
  { en: 'greaterbay', cn: '大湾区卫视' },
  { en: 'gba', cn: '大湾区卫视' },

  // ---- 港澳台 ----
  { en: 'jade', cn: 'TVB 翡翠台' },
  { en: 'tvbjade', cn: 'TVB 翡翠台' },
  { en: 'pearl', cn: 'TVB 明珠台' },
  { en: 'tvbpearl', cn: 'TVB 明珠台' },
  { en: 'tvbnews', cn: 'TVB 无线新闻台' },
  { en: 'tvbplus', cn: 'TVB Plus' },
  { en: 'tvbs', cn: 'TVBS' },
  { en: 'tvbsasia', cn: 'TVBS' }
];

interface EpgPack {
  url: string;
  /** 抓取时间 */
  ts: number;
  chans: EpgChan[];
}

/** 「正在播 / 接下来」一次取两个，界面一次调用就够 */
export interface EpgNowNext {
  cur: EpgProg | null;
  next: EpgProg | null;
}

export class EpgStore {
  private static pack: EpgPack | null = null;
  private static byId: Map<string, EpgChan> = new Map();
  /** 归一化频道名 → 频道，tvg-id 对不上时用 */
  private static byName: Map<string, EpgChan> = new Map();
  /** 正在下载：防止设置页和直播页同时触发两次拉取 */
  private static loading: boolean = false;

  static init(ctx: common.Context): void {
    if (EpgStore.pack !== null) {
      return;
    }
    const raw: string = FileStore.readText(ctx, F_CACHE);
    if (raw.length === 0) {
      return;
    }
    try {
      const p: EpgPack = JSON.parse(raw) as EpgPack;
      EpgStore.setPack(p);
    } catch (e) {
      EpgStore.pack = null;
    }
  }

  /** 有没有可用节目单（界面据此决定显示「正在播」还是「N 条线路」） */
  static hasData(): boolean {
    return EpgStore.pack !== null && EpgStore.byId.size > 0;
  }

  static summary(): string {
    if (EpgStore.pack === null || EpgStore.pack.chans.length === 0) {
      return '';
    }
    let n: number = 0;
    for (const c of EpgStore.pack.chans) {
      n += c.progs.length;
    }
    return EpgStore.pack.chans.length.toString() + ' 个频道 · ' + n.toString() + ' 条节目 · '
      + EpgStore.ageText(EpgStore.pack.ts);
  }

  private static ageText(ts: number): string {
    if (ts <= 0) {
      return '未更新';
    }
    const d: number = Date.now() - ts;
    if (d < HOUR) {
      return '刚刚更新';
    }
    if (d < 24 * HOUR) {
      return Math.floor(d / HOUR).toString() + ' 小时前更新';
    }
    return Math.floor(d / (24 * HOUR)).toString() + ' 天前更新';
  }

  private static setPack(p: EpgPack): void {
    EpgStore.pack = p;
    EpgStore.byId = new Map();
    EpgStore.byName = new Map();
    for (const c of p.chans) {
      const id: string = c.id.trim().toLowerCase();
      if (id.length > 0) {
        EpgStore.byId.set(id, c);
      }
      // 一个频道常带好几个 display-name（央视台尤其多），全部进索引才能对上
      // 各种写法：「CCTV-1」「CCTV1」「央视一套」「AnhuiTV」「安徽卫视」
      const cand: string[] = [c.name];
      if (c.aliases !== undefined) {
        for (const a of c.aliases) {
          cand.push(a);
        }
      }
      for (const nm0 of cand) {
        const nm: string = EpgStore.norm(nm0);
        if (nm.length > 0 && !EpgStore.byName.has(nm)) {
          EpgStore.byName.set(nm, c);
        }
      }
    }
  }

  /**
   * 懒加载：进直播页（或设置页）时自动跑，内置源，无需任何配置。
   * 有缓存且没过期就什么都不做，否则后台拉一次。
   * 返回是否发生了网络更新（界面据此决定要不要重绘）。
   */
  static async ensure(ctx: common.Context): Promise<boolean> {
    EpgStore.init(ctx);
    const ts: number = EpgStore.pack === null ? 0 : EpgStore.pack.ts;
    // 缓存里的源必须在内置列表里：老版本手填过别家地址的，直接当过期重拉
    const stale: boolean = EpgStore.pack !== null && EPG_SOURCES.indexOf(EpgStore.pack.url) < 0;
    if (!stale && EpgStore.hasData() && Date.now() - ts < FRESH_MS) {
      return false;
    }
    try {
      await EpgStore.refreshAny(ctx);
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 按内置顺序依次尝试，第一个成功的就用它，并把地址记进缓存。
   * 全部失败才 throw（带上最后一个失败原因）。
   *
   * 不优先用「上次成功的那个源」：那样一旦临时掉到后面的源就再也回不来，
   * 会长期拿着 8MB 的兜底源每 12 小时重下一次。固定顺序能自动回到最轻的源。
   */
  static async refreshAny(ctx: common.Context): Promise<string> {
    if (EpgStore.loading) {
      return '正在拉取节目单…';
    }
    let last: string = '';
    for (const u of EPG_SOURCES) {
      try {
        const ret: string = await EpgStore.refresh(ctx, u);
        console.info(TAG + ' 节目单命中：' + u);
        return ret;
      } catch (e) {
        last = (e as Error).message;
        console.warn(TAG + ' 节目单源失败：' + u + ' → ' + last);
      }
    }
    throw new Error(last.length > 0 ? last : '所有节目单源都失败了');
  }

  /**
   * 拉取并解析一份 xmltv（.xml / .xml.gz 都行），成功后落盘。
   * 失败会 throw，界面拿 message 显示。
   */
  static async refresh(ctx: common.Context, url: string): Promise<string> {
    const u: string = (url ?? '').trim();
    if (u.length === 0) {
      throw new Error('节目单地址为空');
    }
    if (EpgStore.loading) {
      return '正在拉取节目单…';
    }
    EpgStore.loading = true;
    try {
      const dest: string = FileStore.path(ctx, F_RAW);
      const bytes: number = await HttpUtil.downloadTo(u, '', UA, dest);
      if (bytes <= 0) {
        throw new Error('下载失败，检查地址是否可访问');
      }
      const text: string = await EpgStore.readMaybeGz(dest);
      FileStore.remove(ctx, F_RAW);
      if (text.length === 0) {
        throw new Error('节目单是空的');
      }
      const p: EpgPack = EpgStore.parse(text, u);
      if (p.chans.length === 0) {
        throw new Error('没解析到频道，可能不是 xmltv 格式');
      }
      FileStore.writeText(ctx, F_CACHE, JSON.stringify(p));
      EpgStore.setPack(p);
      return EpgStore.summary();
    } finally {
      EpgStore.loading = false;
    }
  }

  /** 读文件：gzip 会透明解压，普通 xml 直接读原字节 */
  private static async readMaybeGz(path: string): Promise<string> {
    const gz: zlib.GZip = zlib.createGZipSync();
    const chunks: Uint8Array[] = [];
    let total: number = 0;
    try {
      await gz.gzopen(path, 'rb');
      const CHUNK: number = 256 * 1024;
      while (total < MAX_TEXT) {
        const buf: ArrayBuffer = new ArrayBuffer(CHUNK);
        const n: number = await gz.gzread(buf);
        if (n <= 0) {
          break;
        }
        chunks.push(new Uint8Array(buf, 0, n));
        total += n;
      }
    } finally {
      try {
        await gz.gzcloser();
      } catch (e) {
        // 关不掉不影响已经读到的数据
      }
    }
    if (total === 0) {
      return '';
    }
    const all: Uint8Array = new Uint8Array(total);
    let off: number = 0;
    for (const c of chunks) {
      all.set(c, off);
      off += c.length;
    }
    try {
      return util.TextDecoder.create('utf-8').decodeToString(all);
    } catch (e) {
      return '';
    }
  }

  // ---------------- 解析 ----------------

  private static parse(text: string, url: string): EpgPack {
    const now: number = Date.now();
    const from: number = now - KEEP_BEFORE;
    const to: number = now + KEEP_AFTER;

    // 1) 频道：id → 全部 display-name，用来在 tvg-id 缺失时按名字兜底
    const names: Map<string, string[]> = new Map();
    let pos: number = 0;
    while (true) {
      const a: number = text.indexOf('<channel', pos);
      if (a < 0) {
        break;
      }
      const b: number = text.indexOf('</channel>', a);
      if (b < 0) {
        break;
      }
      const seg: string = text.substring(a, b);
      const id: string = EpgStore.attr(seg, 'id');
      if (id.length > 0) {
        const al: string[] = EpgStore.innerAll(seg, 'display-name');
        names.set(id.trim().toLowerCase(), al.length > 0 ? al : [id]);
      }
      pos = b + 10;
    }

    // 2) 节目：只留窗口内的，按频道归组
    const map: Map<string, EpgProg[]> = new Map();
    pos = 0;
    while (true) {
      const a: number = text.indexOf('<programme', pos);
      if (a < 0) {
        break;
      }
      const b: number = text.indexOf('</programme>', a);
      if (b < 0) {
        break;
      }
      // 属性只在开始标签里，从 '<programme' 到第一个 '>' 就够
      const gt: number = text.indexOf('>', a);
      if (gt < 0 || gt > b) {
        pos = a + 10;
        continue;
      }
      const head: string = text.substring(a, gt + 1);
      const ch: string = EpgStore.attr(head, 'channel').trim().toLowerCase();
      const start: number = EpgStore.timeOf(EpgStore.attr(head, 'start'));
      const stop: number = EpgStore.timeOf(EpgStore.attr(head, 'stop'));
      if (ch.length > 0 && start > 0 && stop > start && stop > from && start < to) {
        const title: string = EpgStore.inner(text.substring(a, b), 'title');
        if (title.length > 0) {
          let arr: EpgProg[] | undefined = map.get(ch);
          if (arr === undefined) {
            arr = [];
            map.set(ch, arr);
          }
          arr.push({ s: start, e: stop, t: title });
        }
      }
      pos = b + 12;
    }

    // 3) 组装 + 按开始时间排序
    const chans: EpgChan[] = [];
    map.forEach((progs: EpgProg[], id: string) => {
      progs.sort((x: EpgProg, y: EpgProg) => x.s - y.s);
      const al: string[] | undefined = names.get(id);
      const first: string = al === undefined || al.length === 0 ? id : al[0];
      const rest: string[] = al === undefined || al.length === 0 ? [] : al.slice(1);
      chans.push({ id: id, name: first, aliases: rest, progs: progs });
    });
    return { url: url, ts: Date.now(), chans: chans };
  }

  /** 从标签文本里取属性：要求前面有一个空格，避免 stop= 命中到 start= 里 */
  private static attr(tag: string, name: string): string {
    const key: string = ' ' + name + '="';
    let i: number = tag.indexOf(key);
    if (i < 0) {
      // 标签名后面直接跟属性时，第一个属性的前面不是空格而是标签名，兜一层
      const alt: string = name + '="';
      i = tag.indexOf(alt);
      if (i < 0) {
        return '';
      }
      const s0: number = i + alt.length;
      const e0: number = tag.indexOf('"', s0);
      return e0 < 0 ? '' : tag.substring(s0, e0);
    }
    const s: number = i + key.length;
    const e: number = tag.indexOf('"', s);
    return e < 0 ? '' : tag.substring(s, e);
  }

  /** 取元素的内文本（第一个同名元素），顺手去掉 CDATA 与首尾空白 */
  private static inner(seg: string, name: string): string {
    const open: string = '<' + name;
    let a: number = seg.indexOf(open);
    if (a < 0) {
      return '';
    }
    const gt: number = seg.indexOf('>', a);
    if (gt < 0) {
      return '';
    }
    const close: number = seg.indexOf('</' + name + '>', gt);
    if (close < 0) {
      return '';
    }
    let v: string = seg.substring(gt + 1, close);
    if (v.startsWith('<![CDATA[') && v.endsWith(']]>')) {
      v = v.substring(9, v.length - 3);
    }
    v = v.replace(/<[^>]*>/g, '');
    return v.trim();
  }

  /** 取某个元素的**全部**内文本（xmltv 的 <channel> 里常有多个 display-name 别名） */
  private static innerAll(seg: string, name: string): string[] {
    const out: string[] = [];
    const re: RegExp = new RegExp('<' + name + '[^>]*>([^<]*)</' + name + '>', 'g');
    let m: RegExpExecArray | null = re.exec(seg);
    while (m !== null) {
      let v: string = m[1];
      if (v.startsWith('<![CDATA[') && v.endsWith(']]>')) {
        v = v.substring(9, v.length - 3);
      }
      v = EpgStore.unescape(v.trim());
      if (v.length > 0 && out.indexOf(v) < 0) {
        out.push(v);
      }
      m = re.exec(seg);
    }
    return out;
  }

  private static unescape(s: string): string {
    if (s.indexOf('&') < 0) {
      return s;
    }
    return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/&apos;/g, '\'').replace(/&amp;/g, '&');
  }


  /**
   * xmltv 时间：`20261114200000 +0800`（偏移可省略）。
   * 不能直接 new Date(str)：各引擎对无分隔格式的容错不一样，手算最稳。
   */
  private static timeOf(v: string): number {
    const s: string = (v ?? '').trim();
    if (s.length < 12) {
      return 0;
    }
    const y: number = parseInt(s.substring(0, 4), 10);
    const mo: number = parseInt(s.substring(4, 6), 10);
    const d: number = parseInt(s.substring(6, 8), 10);
    const h: number = parseInt(s.substring(8, 10), 10);
    const mi: number = parseInt(s.substring(10, 12), 10);
    const se: number = s.length >= 14 ? parseInt(s.substring(12, 14), 10) : 0;
    if (isNaN(y) || isNaN(mo) || isNaN(d) || isNaN(h) || isNaN(mi)) {
      return 0;
    }
    let ms: number = Date.UTC(y, mo - 1, d, h, mi, isNaN(se) ? 0 : se, 0);
    // 偏移量：' +0800' / ' -0530'
    const sp: number = s.indexOf(' ');
    if (sp > 0) {
      const off: string = s.substring(sp + 1).trim();
      if (off.length >= 5) {
        const sign: number = off.charAt(0) === '-' ? -1 : 1;
        const oh: number = parseInt(off.substring(1, 3), 10);
        const om: number = parseInt(off.substring(3, 5), 10);
        if (!isNaN(oh) && !isNaN(om)) {
          ms -= sign * (oh * 60 + om) * 60000;
        }
      }
    }
    return ms;
  }

  // ---------------- 查询 ----------------

  /**
   * 频道名归一化：不同源的同一个台写法差得远（CCTV1 / cctv-1 / CCTV1高清 / CCTV1HD），
   * 统一去掉大小写、空格、标点和高清后缀再比。
   */
  private static norm(name: string): string {
    let s: string = (name ?? '').toLowerCase();
    s = s.replace(/[\s\-_·•|｜:：,，.。'"“”()（）\[\]【】]/g, '');
    // 高清 / 超清 / HD 是同一个台的画质后缀，去掉；但 4K / 8K 是**独立频道**
    // （CCTV-4K 超高清 与 CCTV-8K 是两个台），一律剥掉会让它们都变成 "cctv" 互相错配
    const stripped: string = s.replace(/高清|超清|蓝光|标清|uhd|fhd|hd/g, '');
    s = stripped.length >= 3 ? stripped : s;
    s = s.replace(/频道$/, '');
    return s;
  }

  /** 英文名映射表：懒构建一次，别在直播页每次 nowNext 都重建 */
  private static enCache: Map<string, string> | null = null;

  private static enMap(): Map<string, string> {
    if (EpgStore.enCache !== null) {
      return EpgStore.enCache;
    }
    const m: Map<string, string> = new Map();
    for (const a of EN_ALIASES) {
      if (!m.has(a.en)) {
        m.set(a.en, a.cn);
      }
    }
    EpgStore.enCache = m;
    return m;
  }

  /**
   * 英文台名 → 中文台名（查不到返回空串）。
   *
   * 只剥「单位词」tv / television，再允许剥一次 satellite（"Hunan Satellite TV" 就是湖南卫视）。
   * **不**继续剥 channel / international / economy / news —— 那些是有实义的限定词，
   * 一路剥下去会把「Zhejiang International Channel」（浙江国际）错配成浙江卫视。
   */
  private static enToCn(n: string): string {
    const m: Map<string, string> = EpgStore.enMap();
    const whole: string | undefined = m.get(n);
    if (whole !== undefined) {
      return whole;
    }
    const core: string = n.replace(/(television|tv)$/, '');
    if (core === n || core.length < 3) {
      return '';
    }
    const hit: string | undefined = m.get(core);
    if (hit !== undefined) {
      return hit;
    }
    const core2: string = core.replace(/satellite$/, '');
    if (core2 !== core && core2.length >= 3) {
      const hit2: string | undefined = m.get(core2);
      if (hit2 !== undefined) {
        return hit2;
      }
    }
    return '';
  }

  /** 找频道：tvg-id → 去国家后缀 → 频道名（含别名）→ 英文名映射 */
  private static chanOf(id: string, name: string): EpgChan | null {
    const k: string = (id ?? '').trim().toLowerCase();
    if (k.length > 0) {
      const c: EpgChan | undefined = EpgStore.byId.get(k);
      if (c !== undefined) {
        return c;
      }
      // iptv-org 的 tvg-id 形如 CCTV1.cn / HunanTV.cn，而多数 xmltv 的 id 就是
      // CCTV1 / hunanweishi：去掉最后一段国家码再碰一次，能救回一大片
      const dot: number = k.lastIndexOf('.');
      if (dot > 0) {
        const c2: EpgChan | undefined = EpgStore.byId.get(k.substring(0, dot));
        if (c2 !== undefined) {
          return c2;
        }
      }
    }
    const n: string = EpgStore.norm(name);
    if (n.length > 0) {
      const c3: EpgChan | undefined = EpgStore.byName.get(n);
      if (c3 !== undefined) {
        return c3;
      }
      // 最后一层：英文台名翻成中文台名再找（Hunan TV → 湖南卫视）
      const cn: string = EpgStore.enToCn(n);
      if (cn.length > 0) {
        const c4: EpgChan | undefined = EpgStore.byName.get(EpgStore.norm(cn));
        if (c4 !== undefined) {
          return c4;
        }
      }
    }
    return null;
  }

  /** 当前在播与接下来一条；没有节目单或该频道没有节目时返回 null */
  static nowNext(id: string, name: string): EpgNowNext | null {
    if (!EpgStore.hasData()) {
      return null;
    }
    const c: EpgChan | null = EpgStore.chanOf(id, name);
    if (c === null || c.progs.length === 0) {
      return null;
    }
    const now: number = Date.now();
    let cur: EpgProg | null = null;
    let next: EpgProg | null = null;
    for (const p of c.progs) {
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
}
