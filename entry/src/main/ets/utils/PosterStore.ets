import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { HttpUtil } from './HttpUtil';
import { DoubanAuth } from './DoubanAuth';
import { VodItem } from '../model/VodItem';

/**
 * 海报刮削（豆瓣）。
 *
 * 为什么选豆瓣而不是 TMDB / IMDb：
 *   - TMDB 是 Kodi / Jellyfin / Emby / Plex 这一类媒体库的行业标准源，海报质量最高，
 *     但 api.themoviedb.org 在国内网络直接不通（实测超时），image.tmdb.org 反而能连，
 *     没有 API 就查不到 tmdb id 和图床路径，等于废掉，故放弃。
 *   - IMDb 官方 API 早已关闭（现在只对商业合作方开 GraphQL），
 *     且它的标题体系是英文/原名，对国内聚合站点那种"流浪地球2 国语"的片名匹配极差。
 *   - 豆瓣是 TVBox 生态事实上的刮削源：站点接口本身就带 vod_douban_id，
 *     覆盖率约 88%，一次详情请求能同时拿到评分和海报，零额外成本。
 *
 * 两条抓取路径：
 *   A) 有 douban_id —— 不单独发请求，跟着 RatingStore 的 rexxar 详情一起回来
 *      （RatingStore 拿到 pic 后回调本类的 offer()）。豆瓣详情接口 6 秒 1 个才稳，
 *      所以绝对不能为了海报再查一遍，否则排队时间翻倍。
 *   B) 没有 douban_id —— 走 rexxar 搜索
 *      https://m.douban.com/rexxar/api/v2/search/subjects?q=片名&type=movie
 *      返回的每一条 target 同时带 id / title / year / rating / cover_url，
 *      一次请求就把「豆瓣 ID + 标准片名 + 年份 + 评分 + 海报」全拿齐，不需要再补查。
 *
 *      关于 403（实测结论，别再当成"必须登录"）：
 *        - 同一时刻 rexxar 搜索 403 / subject_suggest 静默返回 []，
 *          但 subject_abstract（取分）和 rexxar 详情（取图）**都还是 200**。
 *        - 带一个无效 dbcl2 的 Cookie 去搜，一样 403。
 *        → 豆瓣是按**接口**限流的，搜索类接口独立一套低配额，跟登录状态不是一回事。
 *      所以搜索只用来"补没有 douban_id 的片子"，节奏压到 4 秒一个；
 *      真被封了就长冷却 30 分钟，期间取分取图照常工作。登录 Cookie 能提高配额，
 *      但它是"更好"而不是"必须"。
 *
 *      限流处理：搜索被风控时是硬失败（403/429），空结果是「豆瓣没这号片」，
 *      所以 403 走 noteBlocked() 冷却退避，空结果走 noteEmpty() 探针区分，
 *      两者都不写 skip 文件——它们都是临时状态，不该永久拉黑一个片名。
 *      片名要先洗掉"国语/更新至12集/（2023）"这类噪声，
 *      匹配不上宁可放弃也不硬塞——错配的海报比没海报更难受。
 *
 *   C) 季号（"第二季" / "第20季"）：
 *      豆瓣的剧集标题自己就用汉字（"实习医生格蕾 第二十三季"），和站点写法一致，
 *      所以关键词本身不用换算；但同一部剧每一季是**独立条目**，
 *      以前把"第X季"整段删掉再比，结果是第 5 季永远拿到第 1 季的分（缓存 key 也一样）。
 *      现在把季号归一化成数字参与比较与缓存，汉字/阿拉伯数字都认（"二十" == "20"）。
 *
 * 图片必须由应用自己下载：
 *   豆瓣图床有防盗链，不带 Referer 直接回 418（响应体是 14 字节文本），
 *   而 ArkUI 的 Image 组件没法给网络请求加 Referer，所以只能下载到沙箱再按本地文件显示。
 *   实测 s_ratio 270x386/18KB、m_ratio 约 540x772、l_ratio 1080x1544/191KB，
 *   卡片用 m_ratio 在 4K 屏上够清晰，失败自动降级 s_ratio。
 *
 * 缓存：filesDir/posters/<key>.jpg，key 为 d<doubanId> 或 n<片名哈希>。
 *   目录本身就是索引（启动时 listFile 一次），超过 600 张按修改时间清掉最旧的。
 *   确认查不到图的 key 记进 tvbox_poster_skip.json，避免每次开机重复扑空。
 */
const TAG: string = 'PosterStore';
const DOMAIN: number = 0x0001;
const DIR: string = 'posters';
const SKIP_FILE: string = 'tvbox_poster_skip.json';
/** "豆瓣确实没开分"的片名，落盘复用，省掉重启后的重复搜索 */
const NO_SCORE_FILE: string = 'tvbox_noscore.txt';
/** 记多久：新剧常常晚于上线才开分，一周后重新问一次 */
const NO_SCORE_TTL_MS: number = 7 * 24 * 3600 * 1000;
const TICK_KEY: string = 'posterTick';
const CONCURRENCY: number = 3;
/**
 * 按片名搜索的间隔。rexxar 搜索免登录可用，但豆瓣对**搜索类**接口的配额很低：
 * 实测这台设备连查 5 条就 403，而同一时刻 subject_abstract / 详情接口仍然 200——
 * 说明风控是按接口分的，跟"有没有登录"不是一回事（带无效 Cookie 照样 403）。
 * 既然取分取图不受影响，就别为了快把搜索打封：4 秒一个，
 * 被封后冷却 30 分钟（IP 级封禁实测 3 分钟以上不恢复，短冷却只会白撞）。
 */
const SUGGEST_GAP: number = 4000;
/**
 * 登录豆瓣之后的间隔。
 * 未登录时搜索类接口是独立的低配额（实测连查 5 条就 403），只能 4 秒一个。
 * 带上 dbcl2 之后实测 6/6 连发全 200、单条约 0.3s，配额明显更宽，
 * 所以登录态放到 2 秒——首屏 20 张从 80 秒压到 40 秒，不至于慢到像卡住了。
 */
const SUGGEST_GAP_AUTH: number = 2000;
const GAP_MAX: number = 16000;
const GAP_STEP: number = 4000;
/** 定时器节拍：真正的间隔由 gapMs 动态控制，节拍只负责来"看一眼" */
const TICK_MS: number = 400;
/** 连续空结果/被风控时静默这么久再继续（时间太短会把会话彻底打废） */
const EMPTY_COOLDOWN_MS: number = 300000;
/** 被明确拒绝（403/429）时冷却更久：搜索接口一封就是小时级，硬顶只会更糟 */
const BLOCK_COOLDOWN_MS: number = 1800000;
/** 连续多少次空结果就认定被限流 */
const EMPTY_STREAK_MAX: number = 3;
/** 连续多少次有结果后，才允许把间隔调回一点 */
const RECOVER_STREAK: number = 15;
const MAX_FILES: number = 600;
const MAX_TRY: number = 2;
/** 被风控时允许的额外重试轮数：冷却完放回队首再试，避免一条都把队列堵死 */
const MAX_BLOCK_TRY: number = 4;

const UA_DOUBAN: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
const REFERER_DOUBAN: string = 'https://movie.douban.com/';

/** rexxar 搜索响应里的一条 target：rating 和 cover_url 是并列字段，别只要图不要分 */
interface SearchRating {
  value?: number;
  count?: number;
}

interface SearchTarget {
  id?: string;
  title?: string;
  year?: string;
  cover_url?: string;
  rating?: SearchRating;
  card_subtitle?: string;
}

interface SearchItem {
  layout?: string;
  target?: SearchTarget;
}

interface SearchBox {
  items?: SearchItem[];
}

interface SearchResp {
  /** 被风控时这里是原因文案，正常是空串 */
  banned?: string;
  subjects?: SearchBox;
}

/** 内部统一的候选结构（把搜索结果收敛成"能匹配的几个字段"） */
interface SuggestTarget {
  id?: string;
  title?: string;
  year?: string;
  cover_url?: string;
  ratingValue?: number;
}

/** movie.douban.com/j/subject_abstract 的返回，rate 是字符串（未开分是空串） */
interface AbstractSubject {
  title?: string;
  rate?: string | number;
  is_tv?: boolean;
}

interface AbstractResp {
  r?: number;
  subject?: AbstractSubject;
}

interface DlTask {
  key: string;
  url: string;
}

interface PosterEntry {
  key: string;
  mtime: number;
}

export class PosterStore {
  private static ctx: common.Context | null = null;
  private static dir: string = '';
  /** key -> 文件名（不含扩展名其实就等于 key，留着方便以后换命名规则） */
  private static files: Map<string, string> = new Map<string, string>();
  private static skip: Set<string> = new Set<string>();
  private static tried: Map<string, number> = new Map<string, number>();
  private static dlQueue: DlTask[] = [];
  private static pending: Set<string> = new Set<string>();
  private static dlBusy: number = 0;
  private static nameQueue: VodItem[] = [];
  private static nameTimer: number = -1;
  private static nameBusy: boolean = false;
  /** 连续空结果计数 + 冷却截止时间：豆瓣搜索限流时静默一段时间，别把会话打废 */
  private static emptyStreak: number = 0;
  private static cooldownUntil: number = 0;
  /** 当前实际间隔（会被限流推高、被稳定命中拉回） */
  private static gapMs: number = SUGGEST_GAP;
  private static lastRunAt: number = 0;
  private static okStreak: number = 0;

  /** 基准间隔：登录豆瓣后配额更宽按 2 秒跑，未登录只能 4 秒（否则连查几条就 403） */
  private static baseGap(): number {
    return DoubanAuth.has() ? SUGGEST_GAP_AUTH : SUGGEST_GAP;
  }

  /** 还有多少个按名搜索没跑完。首页「按评分排序」用它判断这一轮补分是否结束 */
  static namesPending(): number {
    return PosterStore.nameQueue.length + (PosterStore.nameBusy ? 1 : 0);
  }
  private static tick: number = 0;
  private static inited: boolean = false;
  /** 播放期间暂停，避免豆瓣搜索 / 海报下载跟视频分片抢带宽 */
  private static paused: boolean = false;

  /**
   * 按名搜索命中后把豆瓣分回填出去。
   * 用回调注入而不是 import RatingStore：RatingStore 已经 import 了本类，
   * 反向再 import 会形成循环依赖，运行时可能拿到 undefined。
   */
  static onSuggestHit: ((nameKey: string, score: number) => void) | null = null;
  /**
   * 搜过、且确认豆瓣没开分的片名（key -> 时间戳），别每次翻页/每次重启都重搜。
   * 落盘保存：一屏 20 部里有十几部是"豆瓣确实没收录/没开分"，只存在内存的话，
   * 每次重启又把同样的请求发一轮，纯粹是白白消耗豆瓣那点搜索配额。
   */
  private static noScore: Map<string, number> = new Map<string, number>();
  /** 本次运行里已经从搜索结果拿到过评分的片名，图可能早就有了，不必为补分再搜 */
  private static scored: Set<string> = new Set<string>();

  /** 进播放页时调：停掉按名搜索轮询，下载队列也不再发新请求 */
  static pause(): void {
    PosterStore.paused = true;
    if (PosterStore.nameTimer !== -1) {
      clearInterval(PosterStore.nameTimer);
      PosterStore.nameTimer = -1;
    }
  }

  /** 退出播放页时调：把积压的队列重新跑起来 */
  static resume(): void {
    if (!PosterStore.paused) {
      return;
    }
    PosterStore.paused = false;
    if (PosterStore.nameQueue.length > 0) {
      PosterStore.kickName();
    }
    if (PosterStore.dlQueue.length > 0) {
      PosterStore.pump();
    }
  }

  static init(ctx: common.Context): void {
    PosterStore.ctx = ctx;
    if (PosterStore.inited) {
      return;
    }
    PosterStore.inited = true;
    PosterStore.dir = ctx.filesDir + '/' + DIR;
    try {
      fs.mkdirSync(PosterStore.dir);
    } catch (e) {
      // 已存在
    }
    PosterStore.scan();
    PosterStore.loadSkip();
    PosterStore.loadNoScore();
    PosterStore.tick = 0;
    AppStorage.setOrCreate(TICK_KEY, 0);
    hilog.info(DOMAIN, TAG, 'ready: %{public}d posters, %{public}d skipped',
      PosterStore.files.size, PosterStore.skip.size);
  }

  // ---------------- key ----------------

  /** 豆瓣 ID：站点给的是数字或字符串，统一成非空纯数字串 */
  private static idOf(item: VodItem): string {
    const raw: string | number | undefined = item.vod_douban_id;
    if (raw === undefined || raw === null) {
      return '';
    }
    let s: string = '';
    if (typeof raw === 'number') {
      s = raw > 0 ? Math.floor(raw).toString() : '';
    } else {
      s = raw.trim();
    }
    if (s.length === 0 || s === '0') {
      return '';
    }
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c < 48 || c > 57) {
        return '';
      }
    }
    return s;
  }

  /**
   * 片名归一化：去掉括号段与画质/语言/集数尾巴。
   *
   * 注意「第X季」**不能**在这里删掉：豆瓣每季都是独立条目，删掉之后就分不清
   * 「实习医生格蕾 第二十三季」和「第一季」，缓存 key 也会撞在一起。
   * 需要去掉季号的场合统一走 baseOf()。
   */
  static cleanTitle(raw: string): string {
    let s: string = raw ?? '';
    // 零宽字符 / 方向标记：站点的片名里确实混着 \u200b（"京城十二时辰第6季"），
    // 豆瓣搜索结果里又常见 \u200e（"卧龙‎ (2026)"），不剔掉搜索必挂
    s = s.replace(/[\u200B-\u200F\uFEFF]/g, '');
    s = s.replace(/[（(【\[][^）)】\]]*[）)】\]]/g, ' ');
    s = s.replace(
      /(国语|粤语|英语|日语|韩语|中字|中文字幕|双语|无删减|未删减|导演剪辑版|高清|超清|蓝光|完整版|抢先版|HD|BD|DVD|TS|TC|4K|1080P|2160P|720P|HDR|杜比视界|更新至第?\d+集?|全\d+集|共\d+集|完结)/gi,
      ' ');
    s = s.replace(/[·:：\-—_/|,，.。!！?？'"“”‘’]/g, ' ');
    s = s.replace(/\s+/g, ' ').trim();
    return s;
  }

  /** 去掉「第X季」后的剧名，用于跨季比较（"法律与秩序第二十六季" → "法律与秩序"） */
  static baseOf(title: string): string {
    return title.replace(/第[0-9零一二三四五六七八九十百两]+季/g, ' ')
      .replace(/\s+/g, ' ').trim();
  }

  /** 片名里的季号：汉字 / 阿拉伯数字都认，没有季号返回 0 */
  static seasonOf(title: string): number {
    const m: RegExpMatchArray | null = title.match(/第([0-9零一二三四五六七八九十百两]+)季/);
    if (m === null) {
      return 0;
    }
    return PosterStore.cnNum(m[1]);
  }

  /**
   * 汉字数字转阿拉伯数字，只为比较季号：站点写"二十"、豆瓣写"20"时也能对上。
   * 只处理 1~999，剧的季数够用了。
   */
  private static cnNum(raw: string): number {
    const s: string = (raw ?? '').trim();
    if (s.length === 0) {
      return 0;
    }
    if (/^[0-9]+$/.test(s)) {
      return parseInt(s, 10);
    }
    const digits: string = '零一二三四五六七八九';
    let total: number = 0;
    let num: number = 0;
    for (let i = 0; i < s.length; i++) {
      const c: string = s.charAt(i);
      const d: number = digits.indexOf(c);
      if (d >= 0) {
        num = d;
        continue;
      }
      if (c === '两') {
        num = 2;
        continue;
      }
      if (c === '十') {
        total += (num === 0 ? 1 : num) * 10;
        num = 0;
        continue;
      }
      if (c === '百') {
        total += (num === 0 ? 1 : num) * 100;
        num = 0;
        continue;
      }
    }
    return total + num;
  }

  /** 片名哈希（djb2 + 36 进制），只做文件名，不追求防碰撞 */
  private static hashName(name: string): string {
    let h: number = 5381;
    for (let i = 0; i < name.length; i++) {
      h = (h * 33 + name.charCodeAt(i)) % 2147483647;
    }
    return h.toString(36);
  }

  /**
   * 缓存 key：剧名哈希 + 季号后缀（q3 = 第 3 季）。
   * 前缀 n2 是「片名缓存版本」：年份匹配规则改过一次（补搜「片名+年份」），
   * 旧缓存里只有哈希、没存年份，无法逐条校验是否配错片，只能整代作废重刮；
   * 带 douban_id 的缓存走 d+id，不受影响。
   * 带季号的片名换成新 key，正好把以前"错季"的缓存数据架空、重新取一遍正确的。
   */
  private static nameKey(item: VodItem): string {
    const full: string = PosterStore.cleanTitle(item.vod_name ?? '');
    const base: string = PosterStore.baseOf(full);
    if (base.length === 0) {
      return '';
    }
    const k: string = 'n2' + PosterStore.hashName(PosterStore.squash(base));
    const sn: number = PosterStore.seasonOf(full);
    return sn > 0 ? k + 'q' + sn.toString() : k;
  }

  /**
   * 对外暴露片名哈希 key，供 RatingStore 按片名存取分数。
   * 必须和海报用同一个 key，否则「按名搜索拿到的分」下一帧就查不到了。
   */
  static nameKeyOf(item: VodItem): string {
    return PosterStore.nameKey(item);
  }

  /** 有没有这个豆瓣 ID 的图（给 RatingStore 判断要不要重新查详情用） */
  static hasId(id: string): boolean {
    return PosterStore.files.get('d' + id) !== undefined;
  }

  /**
   * 这个 ID 还值得为海报去查一次详情吗？
   * 图已落地、已确认查不到、正在下载、失败次数到顶，都返回 false，
   * 避免 RatingStore 因为"有分没图"而把同一部片反复塞进队列。
   */
  static needsMeta(id: string): boolean {
    const key: string = 'd' + id;
    if (PosterStore.files.get(key) !== undefined) {
      return false;
    }
    if (PosterStore.skip.has(key)) {
      return false;
    }
    if (PosterStore.pending.has(key)) {
      return false;
    }
    return (PosterStore.tried.get(key) ?? 0) < MAX_TRY;
  }

  /** 记一次"查了但没有图"，累计到上限就彻底放弃 */
  static note(id: string): void {
    const key: string = 'd' + id;
    const c: number = (PosterStore.tried.get(key) ?? 0) + 1;
    PosterStore.tried.set(key, c);
    if (c >= MAX_TRY) {
      PosterStore.markSkip(key);
    }
  }

  // ---------------- 对外查询 ----------------

  /**
   * 卡片要用的本地海报地址。没有返回空串。
   * 优先 doubanId 命名的文件（精确），其次片名哈希（按名刮到的）。
   */
  static localOf(item: VodItem): string {
    const id: string = PosterStore.idOf(item);
    if (id.length > 0) {
      const f: string | undefined = PosterStore.files.get('d' + id);
      if (f !== undefined) {
        return 'file://' + PosterStore.dir + '/' + f + '.jpg';
      }
    }
    const nk: string = PosterStore.nameKey(item);
    if (nk.length > 0) {
      const f: string | undefined = PosterStore.files.get(nk);
      if (f !== undefined) {
        return 'file://' + PosterStore.dir + '/' + f + '.jpg';
      }
    }
    return '';
  }

  // ---------------- 入队 ----------------

  /**
   * 首页/搜索页拿到列表后调一次：把「没有 douban_id」的片子排进按名搜索队列，
   * 一次搜索同时补海报和评分（这两个是搜索响应的并列字段）。
   *
   * @param scoreOnly true = 这批片子已有本地海报，只为补评分入队。
   *        老版本刮削只存了图、没存分，光靠画像判断会把它们永久跳过，
   *        导致「有海报的片子永远没有评分角标」。
   */
  static request(items: VodItem[], scoreOnly: boolean = false): void {
    let added: number = 0;
    for (let i = 0; i < items.length; i++) {
      const it: VodItem = items[i];
      const hasLocal: boolean = PosterStore.localOf(it).length > 0;
      if (hasLocal && !scoreOnly) {
        continue;
      }
      const id: string = PosterStore.idOf(it);
      if (id.length > 0) {
        // 有 ID：交给 RatingStore 走 rexxar（同时拿评分和海报），这里不重复请求
        continue;
      }
      const nk: string = PosterStore.nameKey(it);
      if (nk.length === 0) {
        continue;
      }
      // skip 文件只代表「这张图刮不到」，不代表「这个片名在豆瓣查不到分」。
      // 以前这里把两者混在一起，结果 skip 里的 400 多个片名连评分也一起被永久封杀，
      // 表现就是「百度采集整屏一个分都没有」。补分路径（scoreOnly）必须绕过 skip。
      if (PosterStore.skip.has(nk) && !scoreOnly) {
        continue;
      }
      const ns: number | undefined = PosterStore.noScore.get(nk);
      const nsFresh: boolean = ns !== undefined && Date.now() - ns < NO_SCORE_TTL_MS;
      // scored / noScore 只代表「分这件事已经问过了」，**不代表封面拿到了**。
      // 以前这里只要 scored 就 continue，结果「取到分但封面下载失败 / cover_url 为空」
      // 的片名本会话再也不会被搜第二次，海报位就永远空着（评分却有）。
      // 现在把两件事拆开判：
      //   scoreOnly（补分路径）→ 只看分，问过就跳过；
      //   普通路径 → 能走到这里说明本地没图，缺图就必须再搜一次，哪怕分已经有了。
      if (scoreOnly && (PosterStore.scored.has(nk) || nsFresh)) {
        continue;   // 补分模式：这个片名的分已经问过（取到或确认没开分）
      }
      if ((PosterStore.tried.get(nk) ?? 0) >= MAX_TRY) {
        continue;
      }
      let dup: boolean = false;
      for (let j = 0; j < PosterStore.nameQueue.length; j++) {
        if (PosterStore.nameKey(PosterStore.nameQueue[j]) === nk) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      PosterStore.nameQueue.push(it);
      added++;
    }
    if (added > 0) {
      hilog.info(DOMAIN, TAG, 'name-queue +%{public}d (pending %{public}d)',
        added, PosterStore.nameQueue.length);
      PosterStore.kickName();
    }
  }

  /**
   * RatingStore 从 rexxar 详情里拿到 pic 后回调这里。
   * picUrl 可能是 s_ratio（270x386），下载时会自动换成 m_ratio。
   */
  static offer(id: string, picUrl: string): void {
    if (id.length === 0 || picUrl.length === 0) {
      return;
    }
    const u: string = picUrl.trim();
    if (u.indexOf('http') !== 0) {
      return;
    }
    const key: string = 'd' + id;
    if (PosterStore.files.get(key) !== undefined) {
      return;
    }
    PosterStore.enqueue(key, u);
  }

  private static enqueue(key: string, url: string): void {
    if (PosterStore.pending.has(key)) {
      return;
    }
    PosterStore.pending.add(key);
    PosterStore.dlQueue.push({ key: key, url: url } as DlTask);
    PosterStore.pump();
  }

  // ---------------- 图片下载 ----------------

  private static pump(): void {
    if (PosterStore.paused) {
      return;
    }
    while (PosterStore.dlBusy < CONCURRENCY && PosterStore.dlQueue.length > 0) {
      const t: DlTask | undefined = PosterStore.dlQueue.shift();
      if (t === undefined) {
        break;
      }
      PosterStore.dlBusy++;
      PosterStore.download(t).then(() => {
        PosterStore.dlBusy--;
        PosterStore.pump();
      }).catch(() => {
        PosterStore.dlBusy--;
        PosterStore.pump();
      });
    }
  }

  /**
   * 豆瓣详情接口给的图是 s_ratio（270x386），换成 m_ratio（约 540x772）更清晰；
   * 搜索接口给的签名地址已经处理成 h/800，不需要再动。
   * 大图拿不到时退回原地址，两者都失败才算这张刮不到。
   * 豆瓣 418 时会回一段小文本，downloadTo 已按体积挡掉，这里只看返回值。
   */
  private static async download(task: DlTask): Promise<void> {
    const dest: string = PosterStore.dir + '/' + task.key + '.jpg';
    const big: string = task.url.indexOf('/s_ratio_poster/') >= 0
      ? task.url.replace('/s_ratio_poster/', '/m_ratio_poster/')
      : task.url;
    let n: number = await HttpUtil.downloadTo(big, REFERER_DOUBAN, UA_DOUBAN, dest);
    if (n === 0 && big !== task.url) {
      n = await HttpUtil.downloadTo(task.url, REFERER_DOUBAN, UA_DOUBAN, dest);
    }
    PosterStore.pending.delete(task.key);
    if (n > 0) {
      PosterStore.files.set(task.key, task.key);
      PosterStore.tried.delete(task.key);
      hilog.info(DOMAIN, TAG, 'saved %{public}s (%{public}dB)', task.key, n);
      PosterStore.bump();
    } else {
      const c: number = (PosterStore.tried.get(task.key) ?? 0) + 1;
      PosterStore.tried.set(task.key, c);
      hilog.warn(DOMAIN, TAG, 'download fail %{public}s (%{public}d)', task.key, c);
      if (c >= MAX_TRY) {
        PosterStore.markSkip(task.key);
      }
    }
  }

  // ---------------- 按片名搜索 ----------------

  private static kickName(): void {
    if (PosterStore.paused || PosterStore.nameTimer !== -1) {
      return;
    }
    // 还没被限流拉高过：跟着登录态重定基准（登录 2s / 未登录 4s）
    if (PosterStore.gapMs === SUGGEST_GAP) {
      PosterStore.gapMs = PosterStore.baseGap();
    }
    PosterStore.nameTimer = setInterval(() => {
      PosterStore.nameStep();
    }, TICK_MS) as number;
  }

  private static nameStep(): void {
    if (PosterStore.paused || PosterStore.nameBusy) {
      return;
    }
    const now: number = Date.now();
    // 被限流了就先安静一会儿，队列和定时器都留着，冷却结束自动续上
    if (now < PosterStore.cooldownUntil) {
      return;
    }
    // 间隔是动态的：被限流就拉长、稳定命中再收回，节拍只管"来瞄一眼"
    if (now - PosterStore.lastRunAt < PosterStore.gapMs) {
      return;
    }
    if (PosterStore.nameQueue.length === 0) {
      if (PosterStore.nameTimer !== -1) {
        clearInterval(PosterStore.nameTimer);
        PosterStore.nameTimer = -1;
      }
      return;
    }
    const it: VodItem | undefined = PosterStore.nameQueue.shift();
    if (it === undefined) {
      return;
    }
    PosterStore.lastRunAt = now;
    PosterStore.nameBusy = true;
    PosterStore.searchOne(it).then(() => {
      PosterStore.nameBusy = false;
    }).catch(() => {
      PosterStore.nameBusy = false;
    });
  }

  private static async searchOne(item: VodItem): Promise<void> {
    const raw: string = PosterStore.cleanTitle(item.vod_name ?? '');
    const nk: string = PosterStore.nameKey(item);
    if (raw.length === 0 || nk.length === 0) {
      return;
    }
    const year: string = (item.vod_year ?? '').trim();
    try {
      // 依次尝试几种写法，前一种搜不到才试下一种（每次搜索都要花掉一个配额）：
      //   1) 完整片名（含"第X季"）——豆瓣标题本身也带季号，精确度最高
      //   2) 去掉季号的剧名——季号写法差异会让整条搜不到
      //   3) 去掉尾部年份——百度采集的片名几乎条条带年份，豆瓣标题却是干净的
      const tries: string[] = [raw];
      const base: string = PosterStore.baseOf(raw);
      if (base.length > 0 && base !== raw) {
        tries.push(base);
      }
      const noYear: string = raw.replace(/(19|20)\d{2}$/, '').trim();
      if (noYear.length > 0 && tries.indexOf(noYear) < 0) {
        tries.push(noYear);
      }
      let cands: SuggestTarget[] = [];
      for (let i = 0; i < tries.length; i++) {
        if (i > 0) {
          // 换写法重试也要留空隙：连着三次请求比"一条一条慢慢来"更容易触发风控
          await PosterStore.sleep(PosterStore.gapMs);
        }
        cands = await PosterStore.query(tries[i]);
        if (cands.length > 0) {
          break;
        }
      }
      if (cands.length === 0) {
        await PosterStore.noteEmpty();
        const c: number = (PosterStore.tried.get(nk) ?? 0) + 1;
        PosterStore.tried.set(nk, c);
        hilog.info(DOMAIN, TAG, 'no rows: %{public}s (%{public}d)', raw, c);
        if (c < MAX_TRY) {
          PosterStore.nameQueue.push(item);
        }
        return;
      }
      PosterStore.noteRows();
      let hit: SuggestTarget | null = PosterStore.pick(cands, raw, year);
      // 年份没对上就再补搜一次「片名+年份」。
      // 豆瓣会把同名重名片直接标进标题（《荒岛惊魂2018》就是独立条目 30320177），
      // 只搜「荒岛惊魂」只能拿到 1966 / 2005 那两部，于是中国的 2018 片被配成美国片。
      if (year.length > 0 && !PosterStore.yearOk(hit, year)) {
        const w2: string = PosterStore.withYear(raw, year);
        if (w2.length > 0 && tries.indexOf(w2) < 0) {
          await PosterStore.sleep(PosterStore.gapMs);
          const c2: SuggestTarget[] = await PosterStore.query(w2);
          if (c2.length > 0) {
            const h2: SuggestTarget | null = PosterStore.pick(c2, w2, year);
            if (PosterStore.yearOk(h2, year)) {
              hit = h2;
              hilog.info(DOMAIN, TAG, 'year retry: %{public}s -> %{public}s', raw, w2);
            }
          }
        }
      }
      if (hit === null) {
        // 只记本次运行不再试，不写 skip 文件：清理规则以后若调整，重启就能重新捞
        PosterStore.tried.set(nk, MAX_TRY);
        let brief: string = '';
        for (let i = 0; i < cands.length && i < 3; i++) {
          brief += '[' + (cands[i].title ?? '?') + ']';
        }
        hilog.info(DOMAIN, TAG, 'no match: %{public}s, candidates %{public}s', raw, brief);
        return;
      }
      // rexxar 搜索的 rating 和 cover_url 是并列字段，正常情况下这一步就拿到分了。
      // 只有字段缺失（-1）才补查摘要接口：0 分就是豆瓣没开分，补查纯属白烧配额。
      let rv: number = hit.ratingValue ?? -1;
      if (rv < 0) {
        rv = await PosterStore.rateOf(hit.id ?? '');
      }
      if (rv > 0) {
        PosterStore.scored.add(nk);
        const hitCb: ((k: string, s: number) => void) | null = PosterStore.onSuggestHit;
        if (hitCb !== null) {
          hitCb(nk, rv);
        }
      } else {
        // 豆瓣确实没开分，本会话别再为这个片名重复搜索
        PosterStore.markNoScore(nk);
      }
      hilog.info(DOMAIN, TAG, 'match %{public}s -> %{public}s (%{public}s) %{public}s',
        raw, hit.title ?? '?', hit.id ?? '?',
        rv > 0 ? '★' + rv.toFixed(1) : 'no score');
      const cover: string = hit.cover_url ?? '';
      if (cover.length === 0) {
        PosterStore.tried.set(nk, MAX_TRY);
        return;
      }
      // 图片按片名哈希存：即使以后站点补上了 douban_id，这份缓存也还能兜底
      PosterStore.enqueue(nk, PosterStore.bigCover(cover));
    } catch (e) {
      const msg: string = (e as Error).message;
      // 403/429/banned 是 IP 级风控，不是"豆瓣没这片"：冷却退避，冷却完把这条放回队首
      if (/403|429|banned|rate_limit/i.test(msg)) {
        PosterStore.noteBlocked();
        const bc: number = (PosterStore.tried.get(nk) ?? 0) + 1;
        PosterStore.tried.set(nk, bc);
        hilog.warn(DOMAIN, TAG, 'search blocked %{public}s (%{public}d): %{public}s', raw, bc, msg);
        if (bc < MAX_BLOCK_TRY) {
          PosterStore.nameQueue.unshift(item);
        }
        return;
      }
      const c: number = (PosterStore.tried.get(nk) ?? 0) + 1;
      PosterStore.tried.set(nk, c);
      hilog.warn(DOMAIN, TAG, 'search fail %{public}s (%{public}d): %{public}s',
        raw, c, msg);
      // 注意：这里**不能**写 markSkip。搜索失败多半是限流 / 网络抖，属于临时故障；
      // 以前把它当成「豆瓣没这个片名」写进 skip 文件（永久生效），一次网络抖动就能
      // 让一整个片名永远查不到分和海报。只记本次运行的重试次数就够了。
      if (c < MAX_TRY) {
        PosterStore.nameQueue.push(item);
      }
    }
  }

  /** 候选的年份是否等于目标年份；目标年份为空视为不用管年份，算对上 */
  private static yearOk(hit: SuggestTarget | null, year: string): boolean {
    if (hit === null) {
      return false;
    }
    const y: string = (year ?? '').trim();
    if (y.length === 0) {
      return true;
    }
    return (hit.year ?? '').trim() === y;
  }

  /**
   * 拼一个「剥掉尾部年份的片名 + 年份」的查询词，拼不出新词就返回空串。
   * 豆瓣对同名片常直接在标题里带年份，这是唯一能搜到它们的写法。
   */
  private static withYear(raw: string, year: string): string {
    const noYear: string = (raw ?? '').replace(/(19|20)\d{2}$/, '').trim();
    const base: string = PosterStore.baseOf(noYear);
    const stem: string = base.length > 0 ? base : noYear;
    if (stem.length === 0) {
      return '';
    }
    const out: string = stem + (year ?? '').trim();
    return out === raw ? '' : out;
  }

  /** 简单延时（重试之间留空隙用） */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * rexxar 搜索（免登录可用，见文件头 B 段）。
   * 一次请求就把候选的 id / 片名 / 年份 / 评分 / 海报全拿齐，
   * 不需要再按 ID 补查摘要接口——这是它比建议接口强的地方，不只是快。
   *
   * rating 缺失时记 -1（未知），和"确实 0 分"区分开：
   * 未知才值得补查一次，0 分补查是白烧配额。
   */
  private static async query(q: string): Promise<SuggestTarget[]> {
    const url: string = 'https://m.douban.com/rexxar/api/v2/search/subjects?q='
      + encodeURIComponent(q) + '&type=movie&start=0&count=5';
    const text: string = await HttpUtil.getTextWith(url, 'https://m.douban.com/search/', UA_DOUBAN);
    const t: string = text.trim();
    if (t.length === 0 || t.charAt(0) !== '{') {
      throw new Error('not json');
    }
    const d: SearchResp = JSON.parse(t) as SearchResp;
    const box: SearchBox | undefined = d.subjects;
    const items: SearchItem[] = box !== undefined && box.items !== undefined ? box.items : [];
    const out: SuggestTarget[] = [];
    for (let i = 0; i < items.length; i++) {
      const tg: SearchTarget | undefined = items[i].target;
      if (tg === undefined) {
        continue;
      }
      const title: string = (tg.title ?? '').trim();
      if (title.length === 0) {
        continue;
      }
      const r: SearchRating | undefined = tg.rating;
      out.push({
        id: (tg.id ?? '').trim(),
        title: title,
        year: (tg.year ?? '').trim(),
        cover_url: (tg.cover_url ?? '').trim(),
        ratingValue: r !== undefined && r.value !== undefined ? r.value : -1
      } as SuggestTarget);
    }
    if (out.length === 0) {
      const ban: string = (d.banned ?? '').trim();
      if (ban.length > 0) {
        // banned 非空 = 这次搜索被风控挡了，不能当成"豆瓣没这号片"
        throw new Error('banned: ' + ban);
      }
    }
    return out;
  }

  /** 按豆瓣 ID 取评分（subject_abstract；未开分时 rate 是空串） */
  private static async rateOf(id: string): Promise<number> {
    if (id.length === 0) {
      return 0;
    }
    try {
      const url: string = 'https://movie.douban.com/j/subject_abstract?subject_id=' + id;
      const text: string = await HttpUtil.getTextWith(url, 'https://movie.douban.com/', UA_DOUBAN);
      const t: string = text.trim();
      if (t.length === 0 || t.charAt(0) !== '{') {
        return 0;
      }
      const d: AbstractResp = JSON.parse(t) as AbstractResp;
      const s: AbstractSubject | undefined = d.subject;
      if (s === undefined || s.rate === undefined || s.rate === null) {
        return 0;
      }
      const raw: string | number = s.rate;
      const v: number = typeof raw === 'number' ? raw : parseFloat(raw.trim());
      return !isNaN(v) && v > 0 && v <= 10 ? v : 0;
    } catch (e) {
      return 0;
    }
  }

  /** 有结果：清掉空结果计数，连着稳定命中就把间隔往回收一点 */
  private static noteRows(): void {
    PosterStore.emptyStreak = 0;
    PosterStore.okStreak++;
    if (PosterStore.okStreak >= RECOVER_STREAK) {
      PosterStore.okStreak = 0;
      const floor: number = PosterStore.baseGap();
      if (PosterStore.gapMs > floor) {
        PosterStore.gapMs = Math.max(floor, PosterStore.gapMs - GAP_STEP);
        hilog.info(DOMAIN, TAG, 'search gap back to %{public}dms', PosterStore.gapMs);
      }
    }
  }

  /**
   * 连续空结果：先分清楚是「豆瓣本来就没收这些片」还是「被限流」。
   *
   * 搜索被限流时除了 403，也可能返回 200 但 items 为空，和"这片名豆瓣没有"
   * 的表现一样。百度采集的片子有很多豆瓣确实没收录，如果一律当成限流，
   * 就会一直白白冷却、整屏一个分都补不上。所以连空到上限时用一条**必定存在**的片名
   * 做探针：探针也返回空才是真被限流。
   */
  private static async noteEmpty(): Promise<void> {
    PosterStore.emptyStreak++;
    PosterStore.okStreak = 0;
    if (PosterStore.emptyStreak < EMPTY_STREAK_MAX) {
      return;
    }
    PosterStore.emptyStreak = 0;
    let alive: boolean = false;
    try {
      const probe: SuggestTarget[] = await PosterStore.query('肖申克的救赎');
      alive = probe.length > 0;
    } catch (e) {
      alive = false;
    }
    if (alive) {
      hilog.info(DOMAIN, TAG, 'empty results are real misses, not throttling');
      return;
    }
    PosterStore.cooldownUntil = Date.now() + EMPTY_COOLDOWN_MS;
    PosterStore.gapMs = Math.min(GAP_MAX, PosterStore.gapMs + GAP_STEP);
    hilog.warn(DOMAIN, TAG, 'search throttled, cooldown %{public}dms, gap %{public}dms',
      EMPTY_COOLDOWN_MS, PosterStore.gapMs);
  }

  /**
   * 被明确拒绝（403 / 429 / banned）：这是 IP 级风控，比"空结果"更硬，
   * 冷却时间更长、间隔直接顶到上限。冷却期间队列不动，结束后自动续上。
   */
  private static noteBlocked(): void {
    PosterStore.emptyStreak = 0;
    PosterStore.okStreak = 0;
    PosterStore.cooldownUntil = Date.now() + BLOCK_COOLDOWN_MS;
    PosterStore.gapMs = GAP_MAX;
    hilog.warn(DOMAIN, TAG, 'search blocked by douban, cooldown %{public}dms, gap %{public}dms',
      BLOCK_COOLDOWN_MS, PosterStore.gapMs);
  }

  /**
   * 搜索接口给的是 OSS 图片处理地址，末尾带 imageView2/.../h/120/format/jpg，
   * 那个 h/120 是列表缩略图（实测只有 7KB、120px 高），直接拿来当海报会糊成一片。
   * 换成 h/800 后约 100KB，和详情接口的 m_ratio 一个量级，够 4K 屏显示。
   * 签名在 query 前缀上（sa_cv / sa_ct），只动 imageView2 段不会破坏签名。
   */
  private static bigCover(u: string): string {
    return u.replace('/h/120/', '/h/800/');
  }

  /**
   * 从候选里挑一条。剧集要按**季**挑：同一部剧每季是独立条目，
   * 挑错季等于给用户看了别的剧的分数。
   *
   * 顺序按可信度：
   *   1) 剧名一致 + 季号一致 + 年份对上
   *   2) 剧名一致 + 季号一致
   *   3) 剧名一致 + 候选没有季号 + 年份对上（豆瓣把多季合并成一条的情况）
   *   4) 剧名一致 + 候选没有季号
   *   5) 剧名一致但季号不同（实在没得选，宁可给个近似分也不空着，会记日志）
   *   6) "标题 = 片名 + 纯年份"（"流浪地球2" 不会被配给 "流浪地球"）
   *
   * 站点的片名常自带年份（"黄金时段2026"、"龙在天涯1989"），豆瓣标题却是干净的，
   * 所以整组规则会再对"剥掉尾部年份的片名"跑一遍。
   *
   * 比较前统一 squash 掉所有空白：cleanTitle 把间隔号"·"变成了空格，
   * 于是"杯雪·一战成名"会变成"杯雪 一战成名"，跟片名"杯雪一战成名"对不上。
   */
  private static pick(list: SuggestTarget[], want: string, year: string): SuggestTarget | null {
    if (list.length === 0) {
      return null;
    }
    const wBase: string = PosterStore.squash(PosterStore.baseOf(want));
    if (wBase.length === 0) {
      return null;
    }
    const wSeason: number = PosterStore.seasonOf(want);
    const y: string = year.trim();
    const hit: SuggestTarget | null = PosterStore.scanCands(list, wBase, wSeason, y, false);
    if (hit !== null) {
      return hit;
    }
    // 严格匹配（季号必须对上）失败后，才允许用"季号不同但剧名一致"的条目兜底：
    // 豆瓣很多老剧只开了第一季的分，一点分都不显示不如给个同剧近似分
    const loose: SuggestTarget | null = PosterStore.scanCands(list, wBase, wSeason, y, true);
    if (loose !== null) {
      hilog.info(DOMAIN, TAG, 'season fallback: %{public}s -> %{public}s',
        want, loose.title ?? '?');
      return loose;
    }
    const wStripped: string = wBase.replace(/(19|20)\d{2}$/, '');
    if (wStripped.length > 0 && wStripped !== wBase) {
      const h2: SuggestTarget | null = PosterStore.scanCands(list, wStripped, wSeason, y, false);
      if (h2 !== null) {
        return h2;
      }
    }
    return null;
  }

  /** pick 的一轮：同一组候选按季号可信度从高到低扫（注意别和缓存扫描 scan() 重名） */
  private static scanCands(list: SuggestTarget[], wBase: string, wSeason: number,
    y: string, allowSeasonDiff: boolean): SuggestTarget | null {
    // 预先把每条候选的剧名/季号/年份算好，后面五轮直接比
    const bases: string[] = [];
    const seasons: number[] = [];
    const years: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const t: string = PosterStore.cleanTitle(list[i].title ?? '');
      bases.push(PosterStore.squash(PosterStore.baseOf(t)));
      seasons.push(PosterStore.seasonOf(t));
      years.push((list[i].year ?? '').trim());
    }
    const sameSeason: (i: number) => boolean = (i: number): boolean => {
      // 片名自己没季号时，先只认"同样没季号"的条目：
      // 否则"斗罗大陆"会先撞上"斗罗大陆 第二季"，而豆瓣本来有第一季的主条目
      return wSeason > 0 ? seasons[i] === wSeason : seasons[i] === 0;
    };
    // 1) 剧名 + 季号 + 年份
    for (let i = 0; i < list.length; i++) {
      if (bases[i] === wBase && sameSeason(i) && y.length > 0 && years[i] === y) {
        return list[i];
      }
    }
    // 2) 剧名 + 季号
    for (let i = 0; i < list.length; i++) {
      if (bases[i] === wBase && sameSeason(i)) {
        return list[i];
      }
    }
    // 3) 剧名 + 候选无季号 + 年份
    for (let i = 0; i < list.length; i++) {
      if (bases[i] === wBase && seasons[i] === 0 && y.length > 0 && years[i] === y) {
        return list[i];
      }
    }
    // 4) 剧名 + 候选无季号
    for (let i = 0; i < list.length; i++) {
      if (bases[i] === wBase && seasons[i] === 0) {
        return list[i];
      }
    }
    // 5) 剧名一致但季号不同（放最后，宁可用近似分也不留空）
    if (allowSeasonDiff) {
      for (let i = 0; i < list.length; i++) {
        if (bases[i] === wBase) {
          return list[i];
        }
      }
    }
    // 6) 剧名 + 纯年份尾巴
    for (let i = 0; i < list.length; i++) {
      if (bases[i].length > wBase.length && bases[i].indexOf(wBase) === 0
        && /^(19|20)\d{2}$/.test(bases[i].substring(wBase.length))) {
        return list[i];
      }
    }
    return null;
  }

  private static squash(s: string): string {
    return s.replace(/\s+/g, '');
  }

  // ---------------- 缓存维护 ----------------

  private static scan(): void {
    PosterStore.files.clear();
    try {
      const names: string[] = fs.listFileSync(PosterStore.dir) as string[];
      for (let i = 0; i < names.length; i++) {
        const n: string = names[i];
        if (!n.endsWith('.jpg')) {
          continue;
        }
        const key: string = n.substring(0, n.length - 4);
        PosterStore.files.set(key, key);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'scan fail');
    }
    PosterStore.trim();
  }

  /** 超过上限就按修改时间删最旧的，降到 80% 留点余量，避免每次开机都触发清理 */
  private static trim(): void {
    if (PosterStore.files.size <= MAX_FILES) {
      return;
    }
    const arr: PosterEntry[] = [];
    PosterStore.files.forEach((v: string, k: string) => {
      let t: number = 0;
      try {
        t = fs.statSync(PosterStore.dir + '/' + v + '.jpg').mtime * 1000;
      } catch (e) {
        t = 0;
      }
      arr.push({ key: k, mtime: t } as PosterEntry);
    });
    arr.sort((a: PosterEntry, b: PosterEntry) => a.mtime - b.mtime);
    const target: number = Math.floor(MAX_FILES * 0.8);
    let removed: number = 0;
    for (let i = 0; i < arr.length && PosterStore.files.size > target; i++) {
      try {
        fs.unlinkSync(PosterStore.dir + '/' + arr[i].key + '.jpg');
        PosterStore.files.delete(arr[i].key);
        removed++;
      } catch (e) {
        // 单张删不掉不影响整体
      }
    }
    hilog.info(DOMAIN, TAG, 'trim removed %{public}d', removed);
  }

  /** 读"没开分"名单，顺手把过期的清掉（一周前的结论不再可信，新剧随时会开分） */
  private static loadNoScore(): void {
    PosterStore.noScore.clear();
    const ctx: common.Context | null = PosterStore.ctx;
    if (ctx === null) {
      return;
    }
    try {
      const raw: string = fs.readTextSync(ctx.filesDir + '/' + NO_SCORE_FILE);
      const lines: string[] = raw.split('\n');
      const now: number = Date.now();
      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i].trim();
        const sep: number = line.indexOf(',');
        if (sep <= 0) {
          continue;
        }
        const key: string = line.substring(0, sep).trim();
        const ts: number = parseInt(line.substring(sep + 1).trim(), 10);
        if (key.length === 0 || isNaN(ts)) {
          continue;
        }
        if (now - ts < NO_SCORE_TTL_MS) {
          PosterStore.noScore.set(key, ts);
        }
      }
    } catch (e) {
      // 首次运行没有这个文件
    }
  }

  private static markNoScore(key: string): void {
    PosterStore.noScore.set(key, Date.now());
    const ctx: common.Context | null = PosterStore.ctx;
    if (ctx === null) {
      return;
    }
    const lines: string[] = [];
    PosterStore.noScore.forEach((ts: number, k: string) => {
      lines.push(k + ',' + ts.toString());
    });
    try {
      const f = fs.openSync(ctx.filesDir + '/' + NO_SCORE_FILE,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, lines.join('\n'));
      fs.closeSync(f);
    } catch (e) {
      // 写不进去最多下次多搜一遍，不影响功能
    }
  }

  private static loadSkip(): void {
    PosterStore.skip.clear();
    const ctx: common.Context | null = PosterStore.ctx;
    if (ctx === null) {
      return;
    }
    try {
      const raw: string = fs.readTextSync(ctx.filesDir + '/' + SKIP_FILE);
      const lines: string[] = raw.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const s: string = lines[i].trim();
        if (s.length > 0) {
          PosterStore.skip.add(s);
        }
      }
    } catch (e) {
      // 首次运行没有这个文件
    }
  }

  private static markSkip(key: string): void {
    PosterStore.skip.add(key);
    const ctx: common.Context | null = PosterStore.ctx;
    if (ctx === null) {
      return;
    }
    const lines: string[] = [];
    PosterStore.skip.forEach((k: string) => {
      lines.push(k);
    });
    try {
      const f = fs.openSync(ctx.filesDir + '/' + SKIP_FILE,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, lines.join('\n'));
      fs.closeSync(f);
    } catch (e) {
      // 写不进去就算了，下次重试一遍成本也不高
    }
  }

  private static bump(): void {
    PosterStore.tick++;
    AppStorage.setOrCreate(TICK_KEY, PosterStore.tick);
  }
}
