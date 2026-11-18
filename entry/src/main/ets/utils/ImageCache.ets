import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HttpUtil } from './HttpUtil';

/**
 * 外链图片本地化通道。
 *
 * 为什么需要：豆瓣图床（img3 / img9.doubanio.com）对电视端的直连请求回 403 ——
 * 不带 Referer 会被当成盗链，ArkUI 的 Image 组件又没有任何设置请求头的能力，
 * 所以规则站抓来的海报在列表里一律显示「暂无海报」。
 *
 * 做法：用带 Referer / 浏览器 UA 的 HTTP 把图抓到本地，把文件路径交给 Image。
 * 顺带的好处是同一张图只下一次，翻回来立刻可见。
 *
 * 目录放 cacheDir（不是 filesDir）：海报属于可再生数据，占空间大（一张几十 KB，
 * 翻上百页就是几十 MB），交给系统按需回收更合适。
 */
const DIR: string = 'siteimg';

/** 图床认浏览器 UA，okhttp / 系统 UA 会被挡 */
const UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const REFERER: string = 'https://www.douban.com/';

const TAG: string = 'ImageCache';
const DOMAIN: number = 0x0001;

/** 外链海报落地后 +1；所有列表页读一下这个 StorageProp 就会重绘出图 */
const TICK_KEY: string = 'sitePicTick';

export class ImageCache {
  private static dir: string = '';
  private static inited: boolean = false;
  /** url → 本地路径（本次进程内已下好的） */
  private static done: Map<string, string> = new Map<string, string>();
  /** url → 进行中的任务：同一张图被多张卡片同时要，只发一次请求 */
  private static inflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  /** 失败过的 url：别每次重绘都再试一遍（豆瓣 403 会持续一段时间） */
  private static failed: Set<string> = new Set<string>();

  static init(ctx: common.Context): void {
    if (ImageCache.inited) {
      return;
    }
    ImageCache.inited = true;
    AppStorage.setOrCreate<number>(TICK_KEY, 0);
    ImageCache.dir = ctx.cacheDir + '/' + DIR;
    try {
      fs.mkdirSync(ImageCache.dir);
    } catch (e) {
      // 已存在
    }
  }

  static isReady(): boolean {
    return ImageCache.dir.length > 0;
  }

  /** 本进程内已经落好的，直接给（同步，画图前先问一次，省掉一帧空白） */
  static cached(url: string): string {
    const v: string | undefined = ImageCache.done.get(url);
    return v === undefined ? '' : v;
  }

  static hasFailed(url: string): boolean {
    return ImageCache.failed.has(url);
  }

  /**
   * 列表页画图前统一问这一句：拿到真正能画出来的地址。
   *   - 本地图（刮削图 / file://）：原样
   *   - 已本地化的外链：本地路径
   *   - 本地化失败：退回原始外链，让 Image 自己试直连（最差等于没有这套机制）
   *   - 正在下载 / 还没开始：空串，页面先显示占位，别留黑框
   * 首页 / 记录 / 收藏都走这里，保证同一部片在各页表现一致。
   */
  static display(url: string): string {
    if (url.length === 0) {
      return '';
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return url;
    }
    const hit: string = ImageCache.cached(url);
    if (hit.length > 0) {
      return hit;
    }
    if (ImageCache.hasFailed(url)) {
      return url;
    }
    return '';
  }

  /**
   * 把外链海报丢进本地化通道，下载完成后 +1 让所有列表页重绘。
   * 同一个 url 只发一次请求（inflight / done / failed 去重）。
   */
  static warm(url: string): void {
    if (url.length === 0 || (!url.startsWith('http://') && !url.startsWith('https://'))) {
      return;
    }
    if (ImageCache.cached(url).length > 0 || ImageCache.hasFailed(url)) {
      return;
    }
    if (ImageCache.inflight.has(url)) {
      return;
    }
    ImageCache.local(url, '').then(() => {
      const n: number = AppStorage.get<number>(TICK_KEY) ?? 0;
      AppStorage.setOrCreate<number>(TICK_KEY, n + 1);
    }).catch(() => {
      // 失败也会在 local 里记进 failed，这里不用重绘（display 会退回原链）
    });
  }

  /**
   * 取本地文件路径；失败返回空串（调用方退回占位框）。
   * referer 传空则按豆瓣处理——目前唯一需要本地化的就是豆瓣图床。
   */
  static async local(url: string, referer: string): Promise<string> {
    const u: string = (url ?? '').trim();
    if (u.length === 0 || !u.startsWith('http')) {
      return '';
    }
    const hit: string = ImageCache.cached(u);
    if (hit.length > 0) {
      return hit;
    }
    if (ImageCache.hasFailed(u)) {
      return '';
    }
    const running: Promise<string> | undefined = ImageCache.inflight.get(u);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string> = ImageCache.fetch(u, referer);
    ImageCache.inflight.set(u, task);
    const out: string = await task;
    ImageCache.inflight.delete(u);
    if (out.length > 0) {
      ImageCache.done.set(u, out);
    } else {
      ImageCache.failed.add(u);
    }
    return out;
  }

  /** URL → 稳定文件名。djb2 哈希把长地址压到 8 位 36 进制，再带上长度防碰撞 */
  private static keyOf(u: string): string {
    let h: number = 5381;
    for (let i = 0; i < u.length; i++) {
      h = ((h * 33) ^ u.charCodeAt(i)) >>> 0;
    }
    return h.toString(36) + '_' + u.length.toString(36);
  }

  private static async fetch(u: string, referer: string): Promise<string> {
    if (!ImageCache.isReady()) {
      return '';
    }
    const path: string = ImageCache.dir + '/' + ImageCache.keyOf(u) + '.jpg';
    // 落过盘的直接复用：进程重启后 done 是空的，但文件还在
    // 注意 Image 组件只认 file:// 前缀，裸沙箱路径画不出来
    try {
      if (fs.accessSync(path)) {
        return 'file://' + path;
      }
    } catch (e) {
      // 不存在，继续下载
    }
    const ref: string = referer.length > 0 ? referer : REFERER;
    const n: number = await HttpUtil.downloadTo(u, ref, UA, path);
    if (n > 0) {
      return 'file://' + path;
    }
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // 没写成功就没文件
    }
    hilog.warn(DOMAIN, TAG, 'download fail: %{public}s', u);
    return '';
  }
}
