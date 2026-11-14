import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FileStore } from './FileStore';
import { HttpUtil } from './HttpUtil';
import { VodItem } from '../model/VodItem';
import { PosterStore } from './PosterStore';

/**
 * 豆瓣评分：两级来源 + 本地缓存。
 *
 * 一级（零成本）：站点接口本身就带 vod_douban_score / vod_douban_id。
 *   实测 ac=videolist 与 ac=detail 返回同样的 85 个字段，所以列表页直接有分可显示。
 *   注意各站差别极大：暴风带分，百度/虎牙基本只给 ID、分全是 0。
 *
 * 二级（后台补）：有 ID 但没有分数的，逐个查豆瓣。
 *
 *   ⚠️ 这里踩过一个坑：以前统一走 rexxar 详情 /rexxar/api/v2/movie/{id}，
 *   那个接口 IP 限流极严（连发几个就 1309 subject_ip_rate_limit，能持续几十分钟），
 *   于是「一屏 20 部片只能零星蹦出两三个分」，还得好几分钟。
 *   实测同一 IP 下：
 *     - /rexxar/api/v2/movie/{id}        → 立刻 1309
 *     - /j/subject_abstract?subject_id=  → 0.3 秒一个连发 37 次全成功
 *   所以取分改走 subject_abstract（GAP 400ms，一屏十来秒就能补齐），
 *   rexxar 详情只留给「还缺海报」的片子（那个接口一次能同时给图和分，图只有它有）。
 *
 * 缓存文件：tvbox_ratings.json，一行一条 "doubanId,score"（不用 JSON 对象是为了绕开
 * ArkTS 对索引访问的限制，读写都更省事）。
 */
const TAG: string = 'RatingStore';
const DOMAIN: number = 0x0001;
const FILE: string = 'tvbox_ratings.json';
const META_FILE: string = 'tvbox_meta.txt';
const TICK_KEY: string = 'ratingTick';
/** rexxar 详情（顺带拿海报）的间隔：这个接口限流最狠，只能慢慢来 */
const GAP_MS: number = 6000;
/** subject_abstract 取分的间隔：实测 0.3 秒连发都不限流，取 400ms 留点余量 */
const SCORE_GAP_MS: number = 400;
/** 取分队列上限：用户快速翻页时别把几十页的 ID 全堆进来，反而拖死当前屏 */
const SCORE_QUEUE_MAX: number = 80;
const MAX_TRY: number = 2;
const SAVE_MIN_GAP: number = 10000;

// 必须是浏览器 UA：okhttp 之类会被豆瓣判为非法请求（1287）
const UA_DOUBAN: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';

interface DoubanRating {
  value?: number;
  count?: number;
}

interface DoubanPic {
  large?: string;
  normal?: string;
}

interface DoubanSubject {
  title?: string;
  year?: string | number;
  type?: string;
  rating?: DoubanRating;
  pic?: DoubanPic;
  /** 豆瓣类型标签，如 ["悬疑","犯罪","剧情"]；比采集站的「欧美动漫」有用得多 */
  genres?: string[];
  /** 片长，如 ["120分钟"]；剧集是单集时长 */
  durations?: string[];
  /** 制片地区，如 ["美国"] */
  countries?: string[];
}

/** 详情页要展示的豆瓣元信息（类型 / 片长 / 地区），单独缓存 */
export class DoubanMeta {
  genres: string[] = [];
  durations: string[] = [];
  countries: string[] = [];
}

/** movie.douban.com/j/subject_abstract 的返回（rate 是字符串，可能为空串） */
interface AbstractSubject {
  title?: string;
  rate?: string | number;
  /** 剧集标记：详情接口对剧集要走 /v2/tv/{id}，靠这个字段提前知道 */
  is_tv?: boolean;
}

interface AbstractResp {
  r?: number;
  subject?: AbstractSubject;
}

export class RatingStore {
  private static ctx: common.Context | null = null;
  private static scores: Map<string, number> = new Map<string, number>();
  /** 豆瓣元信息缓存：id → 类型 / 片长 / 地区 */
  private static metas: Map<string, DoubanMeta> = new Map<string, DoubanMeta>();
  private static tried: Map<string, number> = new Map<string, number>();
  private static queue: string[] = [];
  private static timer: number = -1;
  private static busy: boolean = false;
  /** 取分专用队列（走 subject_abstract，400ms 一个，见文件头注释） */
  private static scoreQueue: string[] = [];
  private static scoreTimer: number = -1;
  private static scoreBusy: boolean = false;
  /** 取分失败次数：和 rexxar 详情那条链路的 tried 分开算，互不干扰 */
  private static scoreTried: Map<string, number> = new Map<string, number>();
  private static tick: number = 0;
  private static lastSave: number = 0;
  private static inited: boolean = false;
  /**
   * 已知是剧集的豆瓣 ID。摘要接口会带 is_tv，先知道的先记下来：
   * 剧集详情在 /v2/movie/{id} 上是 301 跳到 /v2/tv/{id}，而电影接口对剧集限流更狠
   * （实测大量 1309 subject_ip_rate_limit），直连 tv 接口能省掉一次 301 和一半失败率。
   */
  private static tvIds: Set<string> = new Set<string>();
  /** 播放期间暂停，避免豆瓣评分请求跟视频分片抢带宽 */
  private static paused: boolean = false;

  /** 应用启动时调一次：读缓存 + 初始化刷新信号 */
  static init(ctx: common.Context): void {
    RatingStore.ctx = ctx;
    if (RatingStore.inited) {
      return;
    }
    RatingStore.inited = true;
    RatingStore.scores.clear();
    const raw: string = FileStore.readText(ctx, FILE);
    if (raw.length > 0) {
      const lines: string[] = raw.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i].trim();
        const sep: number = line.indexOf(',');
        if (sep <= 0) {
          continue;
        }
        const id: string = line.substring(0, sep).trim();
        const v: number = parseFloat(line.substring(sep + 1));
        if (id.length > 0 && !isNaN(v) && v > 0) {
          RatingStore.scores.set(id, v);
        }
      }
    }
    RatingStore.tick = 0;
    AppStorage.setOrCreate(TICK_KEY, 0);
    RatingStore.loadMeta(ctx);
    // 按名搜索命中时 PosterStore 会把豆瓣分回填过来。
    // 用回调注入：本类已经 import 了 PosterStore，反向 import 会形成循环依赖。
    PosterStore.onSuggestHit = (nameKey: string, score: number): void => {
      RatingStore.offerByName(nameKey, score);
    };
    hilog.info(DOMAIN, TAG, 'cache loaded: %{public}d entries', RatingStore.scores.size);
  }

  /** 豆瓣 ID（站点给的是数字或字符串，统一成非空数字串；0 / 空视为没有） */
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
        return '';   // 非纯数字视为脏数据
      }
    }
    return s;
  }

  private static siteScore(item: VodItem): number {
    const raw: string | number | undefined = item.vod_douban_score;
    if (raw === undefined || raw === null) {
      return 0;
    }
    const v: number = typeof raw === 'number' ? raw : parseFloat(raw);
    if (isNaN(v) || v <= 0 || v > 10) {
      return 0;
    }
    return v;
  }

  /**
   * 三级取分，从准到疏：
   *   1) douban_id 精确缓存（详情接口拿到的）
   *   2) 片名哈希缓存（没有 douban_id 的片子只能靠按名搜索，key 与海报共用）
   *   3) 站点自带的 vod_douban_score
   * 只做第 1 级的话，没 ID 的片子即使按名搜到了分也永远显示不出来。
   */
  static scoreOf(item: VodItem): number {
    const id: string = RatingStore.idOf(item);
    if (id.length > 0) {
      const c: number | undefined = RatingStore.scores.get(id);
      if (c !== undefined && c > 0) {
        return c;
      }
    }
    const nk: string = PosterStore.nameKeyOf(item);
    if (nk.length > 0) {
      const c2: number | undefined = RatingStore.scores.get(nk);
      if (c2 !== undefined && c2 > 0) {
        return c2;
      }
    }
    return RatingStore.siteScore(item);
  }

  /**
   * 按名搜索命中后回填评分。
   * key 是 PosterStore 的片名哈希（'n' + 36 进制），和 douban_id 的纯数字 key
   * 混存在同一个 scores 里——两者格式不会撞。
   */
  static offerByName(nameKey: string, score: number): void {
    const k: string = (nameKey ?? '').trim();
    if (k.length === 0 || score <= 0 || score > 10) {
      return;
    }
    const old: number | undefined = RatingStore.scores.get(k);
    if (old !== undefined && Math.abs(old - score) < 0.05) {
      return;
    }
    RatingStore.scores.set(k, score);
    RatingStore.bump();
    hilog.info(DOMAIN, TAG, 'by-name %{public}s -> %{public}s', k, score.toFixed(1));
    RatingStore.flush();
  }

  /** 角标文字：有分才返回，例如 "8.9"；没分返回空串（卡片不画角标） */
  static label(item: VodItem): string {
    const v: number = RatingStore.scoreOf(item);
    if (v <= 0) {
      return '';
    }
    return v.toFixed(1);
  }

  // ---------------- 豆瓣元信息：类型 / 片长 / 地区 ----------------

  /**
   * 缓存格式：一行一条，字段用 \t 分，数组用 | 分
   *   id \t 悬疑|犯罪 \t 120分钟 \t 美国
   * 不用 JSON 是为了绕开 ArkTS 的对象索引限制，读写都更省事。
   */
  private static loadMeta(ctx: common.Context): void {
    RatingStore.metas.clear();
    const raw: string = FileStore.readText(ctx, META_FILE);
    if (raw.length === 0) {
      return;
    }
    const lines: string[] = raw.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const cols: string[] = line.split('\t');
      if (cols.length < 2) {
        continue;
      }
      const m: DoubanMeta = new DoubanMeta();
      m.genres = RatingStore.splitPipes(cols.length > 1 ? cols[1] : '');
      m.durations = RatingStore.splitPipes(cols.length > 2 ? cols[2] : '');
      m.countries = RatingStore.splitPipes(cols.length > 3 ? cols[3] : '');
      RatingStore.metas.set(cols[0], m);
    }
    hilog.info(DOMAIN, TAG, 'meta cache: %{public}d entries', RatingStore.metas.size);
  }

  private static splitPipes(s: string): string[] {
    const out: string[] = [];
    if (s.length === 0) {
      return out;
    }
    const arr: string[] = s.split('|');
    for (let i = 0; i < arr.length; i++) {
      const v: string = arr[i].trim();
      if (v.length > 0) {
        out.push(v);
      }
    }
    return out;
  }

  /** 只读缓存、不发请求：首页 hero 换片频繁，每次打豆瓣会被限流锁死 */
  static metaCached(id: string): DoubanMeta | null {
    const m: DoubanMeta | undefined = RatingStore.metas.get(id);
    return m === undefined ? null : m;
  }

  /** 有缓存直接给，没有就请求一次 rexxar 详情（详情页只有一部片，等得起） */
  static async ensureMeta(id: string): Promise<DoubanMeta | null> {
    if (id.length === 0) {
      return null;
    }
    const c: DoubanMeta | undefined = RatingStore.metas.get(id);
    if (c !== undefined) {
      return c;
    }
    try {
      const d: DoubanSubject = await RatingStore.detail(id);
      const m: DoubanMeta = new DoubanMeta();
      if (d.genres !== undefined) {
        m.genres = d.genres;
      }
      if (d.durations !== undefined) {
        m.durations = d.durations;
      }
      if (d.countries !== undefined) {
        m.countries = d.countries;
      }
      if (m.genres.length === 0 && m.durations.length === 0 && m.countries.length === 0) {
        return null;
      }
      RatingStore.metas.set(id, m);
      RatingStore.saveMeta();
      hilog.info(DOMAIN, TAG, 'meta ok %{public}s: %{public}s', id, m.genres.join('/'));
      return m;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'meta fail %{public}s: %{public}s', id, (e as Error).message);
      return null;
    }
  }

  private static saveMeta(): void {
    const ctx: common.Context | null = RatingStore.ctx;
    if (ctx === null || RatingStore.metas.size === 0) {
      return;
    }
    const lines: string[] = [];
    RatingStore.metas.forEach((m: DoubanMeta, k: string) => {
      lines.push(k + '\t' + m.genres.join('|') + '\t'
        + m.durations.join('|') + '\t' + m.countries.join('|'));
    });
    FileStore.writeText(ctx, META_FILE, lines.join('\n'));
  }

  /**
   * 把当前页里「还需要豆瓣数据」的片排进后台队列。
   *
   * 需要 = 缺评分 或 缺海报。两个目标共用同一次详情请求：
   * 豆瓣 /rexxar/api/v2/movie/{id} 的响应里 rating 和 pic 是并列字段，
   * 拿一次全都有，为海报再查一遍纯属浪费——这个接口 6 秒才敢发一个。
   * 没有 douban_id 的片本类管不了，转给 PosterStore 走按片名搜索。
   */
  static warm(items: VodItem[]): void {
    let added: number = 0;
    let addedScore: number = 0;
    const noId: VodItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const id: string = RatingStore.idOf(items[i]);
      if (id.length === 0) {
        // 没有 douban_id：本类查不了，交给下面按名搜索（图和分一起回）
        noId.push(items[i]);
        continue;
      }
      const needScore: boolean = RatingStore.scores.get(id) === undefined
        && (RatingStore.scoreTried.get(id) ?? 0) < MAX_TRY;
      const needPoster: boolean = PosterStore.needsMeta(id);
      if (!needScore && !needPoster) {
        continue;
      }
      // 海报只有 rexxar 详情能给，那个接口 6 秒才敢发一个，单独排队
      if (needPoster && RatingStore.queue.indexOf(id) < 0) {
        RatingStore.queue.push(id);
        added++;
      }
      // 取分走 subject_abstract，快得多，另排一条队列
      if (needScore && RatingStore.scoreQueue.indexOf(id) < 0
        && RatingStore.scoreQueue.length < SCORE_QUEUE_MAX) {
        RatingStore.scoreQueue.push(id);
        addedScore++;
      }
    }
    if (added > 0) {
      hilog.info(DOMAIN, TAG, 'queued %{public}d, pending %{public}d', added, RatingStore.queue.length);
      RatingStore.kick();
    }
    if (addedScore > 0) {
      hilog.info(DOMAIN, TAG, 'score-queued %{public}d, pending %{public}d',
        addedScore, RatingStore.scoreQueue.length);
      RatingStore.kickScore();
    }
    PosterStore.request(items);
    // 没有 douban_id 又完全没有分的片子：按名搜索是唯一的评分来源。
    // 单独走一趟 scoreOnly，是为了把「早就有海报、但当年只存了图没存分」的老数据也补上，
    // 否则它们在 request() 里会被 hasLocal 直接挡掉，永远等不到角标。
    const needByName: VodItem[] = [];
    for (let i = 0; i < noId.length; i++) {
      if (RatingStore.scoreOf(noId[i]) <= 0) {
        needByName.push(noId[i]);
      }
    }
    if (needByName.length > 0) {
      hilog.info(DOMAIN, TAG, 'no-id need score: %{public}d', needByName.length);
      PosterStore.request(needByName, true);
    }
  }

  /** 进播放页时调：停掉取分 / 海报轮询，队列保留 */
  static pause(): void {
    RatingStore.paused = true;
    RatingStore.stopTimer();
    RatingStore.stopScoreTimer();
  }

  /** 退出播放页时调：把积压的队列重新跑起来 */
  static resume(): void {
    if (!RatingStore.paused) {
      return;
    }
    RatingStore.paused = false;
    if (RatingStore.queue.length > 0) {
      RatingStore.kick();
    }
    if (RatingStore.scoreQueue.length > 0) {
      RatingStore.kickScore();
    }
  }

  private static kick(): void {
    if (RatingStore.paused || RatingStore.timer !== -1) {
      return;
    }
    RatingStore.timer = setInterval(() => {
      RatingStore.step();
    }, GAP_MS) as number;
  }

  private static step(): void {
    if (RatingStore.paused || RatingStore.busy) {
      return;
    }
    if (RatingStore.queue.length === 0) {
      RatingStore.stopTimer();
      RatingStore.flush();
      return;
    }
    const id: string | undefined = RatingStore.queue.shift();
    if (id === undefined) {
      return;
    }
    RatingStore.busy = true;
    RatingStore.fetchOne(id).then(() => {
      RatingStore.busy = false;
    }).catch(() => {
      RatingStore.busy = false;
    });
  }

  private static stopTimer(): void {
    if (RatingStore.timer !== -1) {
      clearInterval(RatingStore.timer);
      RatingStore.timer = -1;
    }
  }

  // ---------------- 取分队列（subject_abstract，400ms 一个） ----------------

  private static kickScore(): void {
    if (RatingStore.paused || RatingStore.scoreTimer !== -1) {
      return;
    }
    RatingStore.scoreTimer = setInterval(() => {
      RatingStore.scoreStep();
    }, SCORE_GAP_MS) as number;
  }

  private static scoreStep(): void {
    if (RatingStore.paused || RatingStore.scoreBusy) {
      return;
    }
    if (RatingStore.scoreQueue.length === 0) {
      RatingStore.stopScoreTimer();
      RatingStore.flush();
      return;
    }
    const id: string | undefined = RatingStore.scoreQueue.shift();
    if (id === undefined) {
      return;
    }
    RatingStore.scoreBusy = true;
    RatingStore.fetchScore(id).then(() => {
      RatingStore.scoreBusy = false;
    }).catch(() => {
      RatingStore.scoreBusy = false;
    });
  }

  private static stopScoreTimer(): void {
    if (RatingStore.scoreTimer !== -1) {
      clearInterval(RatingStore.scoreTimer);
      RatingStore.scoreTimer = -1;
    }
  }

  /**
   * 按 ID 取评分：movie.douban.com/j/subject_abstract。
   *
   * 为什么不和海报共用 rexxar 详情：那个接口 IP 限流极狠（1309），
   * 而这个老的摘要接口实测 0.3 秒一个连发几十次都不限，是唯一能「一屏十几秒补齐」的路子。
   * 返回 rate 为空串 = 豆瓣确实没给它开分，记一次就不再问，免得整夜扑空。
   */
  private static async fetchScore(id: string): Promise<void> {
    const url: string = 'https://movie.douban.com/j/subject_abstract?subject_id=' + id;
    try {
      const text: string = await HttpUtil.getTextWith(url, 'https://movie.douban.com/', UA_DOUBAN);
      const t: string = text.trim();
      if (t.length === 0 || t.charAt(0) !== '{') {
        throw new Error('not json');
      }
      const d: AbstractResp = JSON.parse(t) as AbstractResp;
      if (d.r !== undefined && d.r !== 0) {
        throw new Error('r=' + d.r);
      }
      let rate: string = '';
      const s: AbstractSubject | undefined = d.subject;
      if (s !== undefined && s.is_tv === true) {
        RatingStore.tvIds.add(id);
      }
      if (s !== undefined && s.rate !== undefined && s.rate !== null) {
        rate = typeof s.rate === 'number' ? s.rate.toString() : s.rate.trim();
      }
      const v: number = rate.length > 0 ? parseFloat(rate) : 0;
      if (!isNaN(v) && v > 0 && v <= 10) {
        const old: number | undefined = RatingStore.scores.get(id);
        RatingStore.scores.set(id, v);
        if (old === undefined || Math.abs(old - v) >= 0.05) {
          RatingStore.bump();
          hilog.info(DOMAIN, TAG, 'score %{public}s -> %{public}s', id, v.toFixed(1));
        }
        RatingStore.flush();
        return;
      }
      // 豆瓣没开分：本会话不再为这个 ID 排队
      RatingStore.scoreTried.set(id, MAX_TRY);
      hilog.info(DOMAIN, TAG, 'unrated %{public}s', id);
    } catch (e) {
      const n: number = (RatingStore.scoreTried.get(id) ?? 0) + 1;
      RatingStore.scoreTried.set(id, n);
      hilog.warn(DOMAIN, TAG, 'score fail %{public}s (%{public}d): %{public}s',
        id, n, (e as Error).message);
      if (n < MAX_TRY && RatingStore.scoreQueue.indexOf(id) < 0) {
        RatingStore.scoreQueue.push(id);
      } else if (n >= MAX_TRY && RatingStore.queue.indexOf(id) < 0) {
        // 摘要接口连续两次不行（换地址 / 被墙 / 反爬），退回 rexxar 详情兜底，
        // 那条链路本来就慢，只兜一次，不再无限重试
        RatingStore.queue.push(id);
        RatingStore.kick();
      }
    }
  }

  /**
   * 拉一条豆瓣详情（评分 + 海报）。剧集走 /v2/tv/{id}，电影走 /v2/movie/{id}；
   * 不知道类型时先按电影试，失败了换另一条路径再试一次。
   *
   * 为什么非要分路径：/v2/movie/{id} 对剧集是先 301 再跳 tv，且电影接口的 IP 限流
   * 明显更严（日志里大量 1309 → HTTP 400），剧集海报因此大面积拉不到。
   * /v2/tv/{id} 实测连发不限流，海报和评分一次给全。
   */
  private static async detail(id: string): Promise<DoubanSubject> {
    const tvFirst: boolean = RatingStore.tvIds.has(id);
    const paths: string[] = tvFirst ? ['tv', 'movie'] : ['movie', 'tv'];
    let last: Error = new Error('detail fail');
    for (let i = 0; i < paths.length; i++) {
      const url: string = 'https://m.douban.com/rexxar/api/v2/' + paths[i] + '/' + id;
      try {
        const text: string = await HttpUtil.getTextWith(url,
          'https://m.douban.com/movie/subject/' + id + '/', UA_DOUBAN);
        const t: string = text.trim();
        if (t.length === 0 || t.charAt(0) !== '{') {
          throw new Error('not json');
        }
        const d: DoubanSubject = JSON.parse(t) as DoubanSubject;
        if (paths[i] === 'tv') {
          RatingStore.tvIds.add(id);
        }
        return d;
      } catch (e) {
        last = e as Error;
      }
    }
    throw last;
  }

  private static async fetchOne(id: string): Promise<void> {
    try {
      const d: DoubanSubject = await RatingStore.detail(id);
      // 海报：同一份响应里就有，顺手交给 PosterStore 下载（它负责带 Referer 落地）
      const pic: DoubanPic | undefined = d.pic;
      let picUrl: string = '';
      if (pic !== undefined) {
        if (pic.normal !== undefined && pic.normal.length > 0) {
          picUrl = pic.normal;
        } else if (pic.large !== undefined) {
          picUrl = pic.large;
        }
      }
      if (picUrl.length > 0) {
        PosterStore.offer(id, picUrl);
      } else {
        PosterStore.note(id);   // 豆瓣确实没这张图，记一次，别无限重查
      }
      const r: DoubanRating | undefined = d.rating;
      const v: number = r !== undefined && r.value !== undefined ? r.value : 0;
      const cnt: number = r !== undefined && r.count !== undefined ? r.count : 0;
      if (v > 0) {
        RatingStore.scores.set(id, v);
        RatingStore.bump();
        hilog.info(DOMAIN, TAG, 'ok %{public}s -> %{public}s (%{public}d)', id, v.toFixed(1), cnt);
        RatingStore.flush();
      } else {
        // 豆瓣尚未开分：记住别再反复查
        RatingStore.tried.set(id, MAX_TRY);
        hilog.info(DOMAIN, TAG, 'unrated %{public}s', id);
      }
    } catch (e) {
      const n: number = (RatingStore.tried.get(id) ?? 0) + 1;
      RatingStore.tried.set(id, n);
      hilog.warn(DOMAIN, TAG, 'fail %{public}s (%{public}d): %{public}s', id, n, (e as Error).message);
      // 失败（大概率是限流）就退回队尾再试，但不超过 MAX_TRY 次
      if (n < MAX_TRY && RatingStore.queue.indexOf(id) < 0) {
        RatingStore.queue.push(id);
      }
    }
  }

  private static bump(): void {
    RatingStore.tick++;
    AppStorage.setOrCreate(TICK_KEY, RatingStore.tick);
  }

  /** 还有多少个豆瓣请求没跑完：两条队列排着的 + 正在请求的那两个 */
  static pending(): number {
    return RatingStore.queue.length + (RatingStore.busy ? 1 : 0)
      + RatingStore.scoreQueue.length + (RatingStore.scoreBusy ? 1 : 0);
  }

  /** 缓存落盘（10 秒内不重复写，避免频繁 IO） */
  static flush(): void {
    const ctx: common.Context | null = RatingStore.ctx;
    if (ctx === null || RatingStore.scores.size === 0) {
      return;
    }
    const now: number = Date.now();
    if (now - RatingStore.lastSave < SAVE_MIN_GAP) {
      return;
    }
    RatingStore.lastSave = now;
    const lines: string[] = [];
    RatingStore.scores.forEach((v: number, k: string) => {
      lines.push(k + ',' + v.toFixed(1));
    });
    FileStore.writeText(ctx, FILE, lines.join('\n'));
  }
}
