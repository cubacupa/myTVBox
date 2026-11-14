import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { HttpUtil } from './HttpUtil';
import { PosterStore } from './PosterStore';
import { VodItem } from '../model/VodItem';

/**
 * 横版剧照（backdrop）刮削 —— 首页主推位的整屏铺底图。
 *
 * 为什么不用竖版海报去放大：竖版海报铺满 16:9 屏幕只能裁掉上下大半再模糊，
 * 得到的就是一团色块，等于没有背景。横版剧照才是电视端该用的东西。
 *
 * 数据来源（实测，2026-11）：
 *   GET https://m.douban.com/rexxar/api/v2/movie/{id}/photos?type=S&start=0&count=8
 *   必须带 Referer: https://movie.douban.com/，否则 418。
 *   - 剧集也走 /v2/movie/ 路径（/v2/tv/{id}/photos 会 404 traversal_error）
 *   - type=S 是「剧照」，里面竖版海报和横版剧照混在一起，
 *     所以必须按宽高比自己筛（挑最大的横版）
 *   - 返回的 large.url 是 600px 宽的签名地址，够糊一层但不能当背景，
 *     原图地址可以自己拼：https://img3.doubanio.com/view/photo/l/public/p{id}.jpg
 *     实测 1200×796、约 200KB，不需要签名，只要带 Referer
 *
 * 一次主推位只需要 1~2 个请求（有 douban_id 就 1 个），而且按片名缓存，
 * 不会像海报刮削那样排队几百条。所以这里用独立的小队列，节奏 1.5 秒，
 * 不与 PosterStore 的搜索队列抢配额。
 *
 * 缓存：filesDir/backdrops/<key>.jpg，key = PosterStore 的片名哈希（与海报同源）。
 *   横版图只服务首页主推位，留 80 张就够，超了按修改时间清最旧。
 */
const TAG: string = 'BackdropStore';
const DOMAIN: number = 0x0001;
const DIR: string = 'backdrops';
const TICK_KEY: string = 'backdropTick';
const MAX_FILES: number = 80;
/** 两次抓取之间留的空隙：photos 接口不严，但没必要连着打 */
const GAP_MS: number = 1500;
/** 被明确拒绝后的冷却 */
const BLOCK_COOLDOWN_MS: number = 600000;
const MAX_TRY: number = 2;

const UA_DOUBAN: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
const REFERER_DOUBAN: string = 'https://movie.douban.com/';

interface PhotoSize {
  url?: string;
  width?: number;
  height?: number;
}

interface PhotoImage {
  large?: PhotoSize;
  normal?: PhotoSize;
}

interface PhotoItem {
  id?: string;
  image?: PhotoImage;
}

interface PhotosResp {
  total?: number;
  photos?: PhotoItem[];
}

/** rexxar 搜索结果（只为主推位找豆瓣 ID，取第一条最像的） */
interface BdSearchTarget {
  id?: string;
  title?: string;
  year?: string;
}

interface BdSearchItem {
  target?: BdSearchTarget;
}

interface BdSearchBox {
  items?: BdSearchItem[];
}

interface BdSearchResp {
  banned?: string;
  subjects?: BdSearchBox;
}

/** 详情接口里的预告片（封面是 720×405 的真 16:9 图） */
interface BdTrailer {
  title?: string;
  cover_url?: string;
}

interface BdDetail {
  is_tv?: boolean;
  trailers?: BdTrailer[];
}

interface BdTask {
  key: string;
  name: string;
  year: string;
  doubanId: string;
  tried: number;
}

export class BackdropStore {
  private static ctx: common.Context | null = null;
  private static dir: string = '';
  private static files: Map<string, string> = new Map<string, string>();
  /**
   * 已确认抓不到的 key。没有这个名单，首页每次重绘都会重新 ensure()，
   * 对着同一部抓不到剧照的片子无限重试（每次 1~2 个请求），纯属白烧豆瓣配额。
   */
  private static givenUp: Set<string> = new Set<string>();
  private static queue: BdTask[] = [];
  private static busy: boolean = false;
  private static timer: number = -1;
  private static lastRunAt: number = 0;
  private static cooldownUntil: number = 0;
  private static tick: number = 0;
  private static inited: boolean = false;

  static init(ctx: common.Context): void {
    BackdropStore.ctx = ctx;
    if (BackdropStore.inited) {
      return;
    }
    BackdropStore.inited = true;
    BackdropStore.dir = ctx.filesDir + '/' + DIR;
    try {
      fs.mkdirSync(BackdropStore.dir);
    } catch (e) {
      // 已存在
    }
    BackdropStore.scan();
    BackdropStore.tick = 0;
    AppStorage.setOrCreate(TICK_KEY, 0);
    hilog.info(DOMAIN, TAG, 'ready: %{public}d backdrops', BackdropStore.files.size);
  }

  /** 缓存 key：与海报同一套片名哈希，收藏/历史里没有 douban_id 也能命中 */
  private static keyOf(name: string): string {
    if (name.length === 0) {
      return '';
    }
    const probe: VodItem = { vod_id: '', vod_name: name, vod_pic: '' };
    return 'b' + PosterStore.nameKeyOf(probe);
  }

  /** 已刮到的本地横版剧照；没有返回空串 */
  static localOf(name: string): string {
    const k: string = BackdropStore.keyOf(name);
    if (k.length === 0) {
      return '';
    }
    const f: string | undefined = BackdropStore.files.get(k);
    if (f === undefined) {
      return '';
    }
    return 'file://' + BackdropStore.dir + '/' + f + '.jpg';
  }

  /** 是否已经有图（避免重复入队） */
  static has(name: string): boolean {
    return BackdropStore.localOf(name).length > 0;
  }

  /**
   * 请求一张横版剧照。已有图 / 已在队列 / 已确认抓不到，都直接返回。
   * 有 douban_id 时只发一个请求；没有才先按片名搜一次。
   */
  static ensure(name: string, year: string, doubanId: string): void {
    const n: string = (name ?? '').trim();
    if (n.length === 0) {
      return;
    }
    const k: string = BackdropStore.keyOf(n);
    if (k.length === 0 || BackdropStore.files.get(k) !== undefined
      || BackdropStore.givenUp.has(k)) {
      return;
    }
    for (let i = 0; i < BackdropStore.queue.length; i++) {
      if (BackdropStore.queue[i].key === k) {
        return;
      }
    }
    BackdropStore.queue.push({
      key: k,
      name: n,
      year: (year ?? '').trim(),
      doubanId: (doubanId ?? '').trim(),
      tried: 0
    } as BdTask);
    BackdropStore.kick();
  }

  private static kick(): void {
    if (BackdropStore.timer !== -1) {
      return;
    }
    BackdropStore.timer = setInterval(() => {
      BackdropStore.step();
    }, 500) as number;
  }

  private static stop(): void {
    if (BackdropStore.timer !== -1) {
      clearInterval(BackdropStore.timer);
      BackdropStore.timer = -1;
    }
  }

  private static step(): void {
    if (BackdropStore.busy) {
      return;
    }
    if (BackdropStore.queue.length === 0) {
      BackdropStore.stop();
      return;
    }
    const now: number = Date.now();
    if (now < BackdropStore.cooldownUntil || now - BackdropStore.lastRunAt < GAP_MS) {
      return;
    }
    const t: BdTask | undefined = BackdropStore.queue.shift();
    if (t === undefined) {
      return;
    }
    BackdropStore.lastRunAt = now;
    BackdropStore.busy = true;
    BackdropStore.run(t).then(() => {
      BackdropStore.busy = false;
    }).catch(() => {
      BackdropStore.busy = false;
    });
  }

  private static async run(t: BdTask): Promise<void> {
    try {
      let id: string = t.doubanId;
      if (id.length === 0) {
        id = await BackdropStore.searchId(t.name, t.year);
      }
      if (id.length === 0) {
        hilog.info(DOMAIN, TAG, 'no douban id: %{public}s', t.name);
        BackdropStore.givenUp.add(t.key);
        return;
      }
      const url: string = await BackdropStore.pickUrl(id);
      if (url.length === 0) {
        hilog.info(DOMAIN, TAG, 'no landscape photo: %{public}s (%{public}s)', t.name, id);
        BackdropStore.givenUp.add(t.key);
        return;
      }
      const ok: boolean = await BackdropStore.download(url, t.key);
      if (ok) {
        BackdropStore.files.set(t.key, t.key);
        BackdropStore.bump();
        hilog.info(DOMAIN, TAG, 'saved %{public}s <- %{public}s', t.name, id);
      } else if (t.tried + 1 < MAX_TRY) {
        // 下载失败（多半是图床抖）：放回队尾再试一次
        t.tried = t.tried + 1;
        BackdropStore.queue.push(t);
      } else {
        BackdropStore.givenUp.add(t.key);
      }
    } catch (e) {
      const msg: string = (e as Error).message;
      if (BackdropStore.isBlocked(e as Error)) {
        BackdropStore.cooldownUntil = Date.now() + BLOCK_COOLDOWN_MS;
        hilog.warn(DOMAIN, TAG, 'blocked, cooldown %{public}dms', BLOCK_COOLDOWN_MS);
        return;
      }
      hilog.warn(DOMAIN, TAG, 'fail %{public}s: %{public}s', t.name, msg);
      if (t.tried + 1 < MAX_TRY) {
        t.tried = t.tried + 1;
        BackdropStore.queue.push(t);
      } else {
        BackdropStore.givenUp.add(t.key);
      }
    }
  }

  /** 没有 douban_id 时按片名搜一次，取标题最接近的那条 */
  private static async searchId(name: string, year: string): Promise<string> {
    const q: string = PosterStore.cleanTitle(name);
    if (q.length === 0) {
      return '';
    }
    const url: string = 'https://m.douban.com/rexxar/api/v2/search/subjects?q='
      + encodeURIComponent(q) + '&type=movie&start=0&count=5';
    const text: string = await HttpUtil.getTextWith(url, 'https://m.douban.com/search/', UA_DOUBAN);
    const s: string = text.trim();
    if (s.length === 0 || s.charAt(0) !== '{') {
      throw new Error('not json');
    }
    const d: BdSearchResp = JSON.parse(s) as BdSearchResp;
    const box: BdSearchBox | undefined = d.subjects;
    const items: BdSearchItem[] = box !== undefined && box.items !== undefined ? box.items : [];
    const want: string = PosterStore.baseOf(q).replace(/\s+/g, '');
    let loose: string = '';
    for (let i = 0; i < items.length; i++) {
      const tg: BdSearchTarget | undefined = items[i].target;
      if (tg === undefined) {
        continue;
      }
      const id: string = (tg.id ?? '').trim();
      if (id.length === 0) {
        continue;
      }
      if (loose.length === 0) {
        loose = id;
      }
      const title: string = PosterStore.baseOf(PosterStore.cleanTitle(tg.title ?? ''))
        .replace(/\s+/g, '');
      const y: string = (tg.year ?? '').trim();
      if (title === want && (year.length === 0 || y.length === 0 || y === year)) {
        return id;
      }
    }
    // 没有精确命中就不用：宁可不显示铺底图，也不能铺错一部片的剧照
    if (loose.length > 0) {
      hilog.info(DOMAIN, TAG, 'only loose match for %{public}s, skip', name);
    }
    return '';
  }

  /**
   * 找一张够宽的图当整屏铺底。三级降级：
   *   1) 剧照里最大的横版（1200×796 这一档，最清晰）
   *   2) 预告片封面（720×405，真 16:9；新片常常只有一张竖版海报，没有剧照）
   *   3) 都没有 → 返回空串，首页退回"竖版海报模糊"的旧效果
   *
   * 剧集的 photos 接口在 /v2/movie/{id} 上会回一段 HTML 跳转提示（不是 JSON），
   * 要走 /v2/tv/{id} 才有数据，所以两条路径都要试。
   */
  private static async pickUrl(id: string): Promise<string> {
    const paths: string[] = ['movie', 'tv'];
    for (let i = 0; i < paths.length; i++) {
      const u: string = 'https://m.douban.com/rexxar/api/v2/' + paths[i] + '/' + id
        + '/photos?type=S&start=0&count=10';
      try {
        const t: string = await BackdropStore.getJson(u,
          'https://movie.douban.com/subject/' + id + '/');
        if (t.length > 0) {
          const hit: string = BackdropStore.bestLandscape(t);
          if (hit.length > 0) {
            return hit;
          }
        }
      } catch (e) {
        // 电影 ID 打 tv 路径是 404，剧集 ID 打 movie 路径是跳转页 —— 都算"这条路径没货"，
        // 换下一条就行。只有被风控（403/429）才值得把整次任务判失败去冷却。
        if (BackdropStore.isBlocked(e as Error)) {
          throw e as Error;
        }
      }
    }
    for (let i = 0; i < paths.length; i++) {
      const u: string = 'https://m.douban.com/rexxar/api/v2/' + paths[i] + '/' + id;
      try {
        const t: string = await BackdropStore.getJson(u,
          'https://m.douban.com/movie/subject/' + id + '/');
        if (t.length === 0) {
          continue;
        }
        const d: BdDetail = JSON.parse(t) as BdDetail;
        const tr: BdTrailer[] = d.trailers !== undefined && d.trailers !== null ? d.trailers : [];
        for (let k = 0; k < tr.length; k++) {
          const raw: string | undefined = tr[k].cover_url;
          const c: string = raw === undefined ? '' : raw.trim();
          if (c.indexOf('http') === 0) {
            return c;
          }
        }
      } catch (e) {
        if (BackdropStore.isBlocked(e as Error)) {
          throw e as Error;
        }
      }
    }
    return '';
  }

  /** 这条错误是不是豆瓣的限流拒绝（需要整体冷却） */
  private static isBlocked(e: Error): boolean {
    return /403|429|banned|rate_limit/i.test(e.message);
  }

  /** 取一段 JSON；非 JSON（剧集的 movie 跳转提示 / 风控页）返回空串 */
  private static async getJson(url: string, referer: string): Promise<string> {
    const text: string = await HttpUtil.getTextWith(url, referer, UA_DOUBAN);
    const s: string = text.trim();
    if (s.length === 0 || s.charAt(0) !== '{') {
      return '';
    }
    return s;
  }

  /**
   * 剧照列表里挑最大的横版。
   * type=S 里混着竖版官方海报（经常就是唯一那张），必须按宽高比筛。
   */
  private static bestLandscape(json: string): string {
    const d: PhotosResp = JSON.parse(json) as PhotosResp;
    const photos: PhotoItem[] = d.photos !== undefined && d.photos !== null ? d.photos : [];
    let bestId: string = '';
    let bestW: number = 0;
    let bestSigned: string = '';
    for (let i = 0; i < photos.length; i++) {
      const it: PhotoItem = photos[i];
      const img: PhotoImage | undefined = it.image;
      if (img === undefined) {
        continue;
      }
      const lg: PhotoSize | undefined = img.large;
      const nm: PhotoSize | undefined = img.normal;
      const w: number = lg !== undefined && lg.width !== undefined ? lg.width
        : (nm !== undefined && nm.width !== undefined ? nm.width : 0);
      const h: number = lg !== undefined && lg.height !== undefined ? lg.height
        : (nm !== undefined && nm.height !== undefined ? nm.height : 0);
      if (w <= 0 || h <= 0 || w < h * 1.2) {
        continue;   // 竖版 / 方图直接跳过
      }
      if (w > bestW) {
        bestW = w;
        bestId = it.id === undefined ? '' : it.id.trim();
        bestSigned = lg !== undefined && lg.url !== undefined ? lg.url.trim()
          : (nm !== undefined && nm.url !== undefined ? nm.url.trim() : '');
      }
    }
    if (bestId.length > 0) {
      // 自己拼原图地址：签名地址只有 600 宽，铺 4K 屏太糊
      return 'https://img3.doubanio.com/view/photo/l/public/p' + bestId + '.jpg';
    }
    return bestSigned;
  }

  /** 下载到沙箱。图床有防盗链，必须带 Referer，否则回 418（十几字节文本） */
  private static async download(url: string, key: string): Promise<boolean> {
    const dest: string = BackdropStore.dir + '/' + key + '.jpg';
    const cands: string[] = [url];
    const alt: string = url.replace('img3.doubanio.com', 'img1.doubanio.com');
    if (alt !== url) {
      cands.push(alt);
    }
    for (let i = 0; i < cands.length; i++) {
      const n: number = await HttpUtil.downloadTo(cands[i], REFERER_DOUBAN, UA_DOUBAN, dest);
      if (n > 8000) {
        return true;
      }
    }
    return false;
  }

  private static scan(): void {
    BackdropStore.files.clear();
    try {
      const names: string[] = fs.listFileSync(BackdropStore.dir) as string[];
      for (let i = 0; i < names.length; i++) {
        const n: string = names[i];
        if (!n.endsWith('.jpg')) {
          continue;
        }
        const key: string = n.substring(0, n.length - 4);
        BackdropStore.files.set(key, key);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'scan fail');
    }
    if (BackdropStore.files.size <= MAX_FILES) {
      return;
    }
    const keys: string[] = [];
    BackdropStore.files.forEach((v: string, k: string) => {
      keys.push(k);
    });
    for (let i = 0; i < keys.length && BackdropStore.files.size > MAX_FILES * 0.8; i++) {
      try {
        fs.unlinkSync(BackdropStore.dir + '/' + keys[i] + '.jpg');
        BackdropStore.files.delete(keys[i]);
      } catch (e) {
        // 单张删不掉不影响整体
      }
    }
  }

  private static bump(): void {
    BackdropStore.tick++;
    AppStorage.setOrCreate(TICK_KEY, BackdropStore.tick);
  }
}
