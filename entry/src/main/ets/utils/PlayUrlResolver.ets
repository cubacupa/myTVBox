import { HttpUtil } from './HttpUtil';
import { sniffer } from './WebSniffer';
import { MacCmsPlayer } from './MacCmsPlayer';
import { hilog } from '@kit.PerformanceAnalysisKit';

function logPlay(msg: string): void {
  hilog.info(0x0000, 'TVBOX_PLAY', '%{public}s', msg);
}

/** 桌面 UA：番剧站按 UA 分流，手机 UA 拿到的页面里没有 player_aaaa */
const DESKTOP_UA: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/**
 * 播放地址解析器。
 *
 * TVBox 站点的播放地址有三种形态，必须依次处理，缺一步就会把一个
 * 非法字符串丢给 AVPlayer，报 "unsupported type"：
 *
 *   1) 直链            https://xx/a/index.m3u8   → 直接用
 *   2) 需要解析接口    flag 命中 parses 里的 flags → 请求解析接口换真地址
 *   3) 网页播放页      https://play.xx.com/play/abcd（返回 HTML，页内 hls.js）
 *                       → 抓页面，把里面的 .m3u8 抠出来
 *
 * 特别注意配置里的 parses 常有 {"name":"Json聚合","url":"Demo"} 这类占位项，
 * 它们不是地址；未校验就拼进 URL 会得到 "Demohttps://..." 这种垃圾串。
 */
export class PlayUrlResolver {
  static isDirect(u: string): boolean {
    const s = (u ?? '').toLowerCase();
    return s.includes('.m3u8') || s.includes('.mp4') || s.includes('.flv') || s.includes('.ts');
  }

  /** 解析接口必须是 http(s) 地址；Demo / Web / Json聚合 这类占位值一律无效 */
  static isValidJx(jx: string): boolean {
    const s = (jx ?? '').trim().toLowerCase();
    if (s.length < 8) {
      return false;
    }
    return s.startsWith('http://') || s.startsWith('https://');
  }

  static isHttpUrl(u: string): boolean {
    const s = (u ?? '').trim().toLowerCase();
    return s.startsWith('http://') || s.startsWith('https://');
  }

  /**
   * 自签名 CDN 直链：鉴权信息已经写在 URL 参数里，不能再带 Referer。
   *
   * 实测（2026-11-18）：腾讯视频 dis_k/dis_t、天翼云 homelink.ctyun.cn 的
   * X-Amz-* 签名直链，裸请求 / 带 UA / 带 Range 都返回 200/206；一旦带上播放页
   * Referer 立刻 404（播放器报 5411007 IO Resource Not Found）。原因是签名本身
   * 已完成鉴权，附加的第三方 Referer 反而命中 CDN 防盗链白名单校验。
   *
   * 嗅探脚本会把页面里出现的每条 mp4/m3u8 的 location.href 记成 Referer，
   * 这类最终直链也在其中，所以起播前必须按签名特征主动剔除。
   */
  static isSelfSigned(u: string): boolean {
    const s = (u ?? '').toLowerCase();
    return s.includes('x-amz-') || s.includes('x-cos-') ||
      s.includes('dis_k=') || s.includes('dis_t=') ||
      s.includes('auth_key=') || s.includes('sign=') || s.includes('signature=');
  }

  /**
   * 依次尝试：直链 → 解析接口 → 网页嗅探 → 猜 index.m3u8 → 原样返回。
   * 返回值保证是 http(s) 地址，避免把非法串交给播放器。
   */
  static async resolve(videoUrl: string, jx: string): Promise<string> {
    const raw: string = (videoUrl ?? '').trim();
    if (raw.length === 0) {
      return '';
    }
    if (PlayUrlResolver.isDirect(raw)) {
      return raw;
    }

    // ① 正规解析接口
    if (PlayUrlResolver.isValidJx(jx)) {
      const got: string = await PlayUrlResolver.tryJx(raw, jx);
      if (got.length > 0) {
        return got;
      }
    }

    // ② 网页播放页：先静态解 macCMS 的 player_aaaa（多数站够用且不用开 WebView），
    //    解出来还是网页就再抓一层（本站播放页 → 上游站播放页是常见形态）
    const fromPage: string = await PlayUrlResolver.readPlayerPage(raw);
    if (fromPage.length > 0) {
      return fromPage;
    }

    // ②b 静态解析没结果 → 让无头 WebView 真跑一遍页面（页面自己请求的流才捞得到）
    const live: string = await sniffer.sniff(raw, 11000);
    if (live.length > 0) {
      return live;
    }

    // ③ 常见约定：/play/xxx 对应的流派生地址就是 /play/xxx/index.m3u8
    const probed: string = await PlayUrlResolver.probeIndex(raw);
    if (probed.length > 0) {
      return probed;
    }

    // 网页里既没有 player_aaaa 也没有流地址：把网页地址原样丢给播放器只会得到
    // "Unsupported Format"，不如返回空串让播放页给出「换条线路」的提示。
    logPlay('全部解析手段失败，放弃：' + raw);
    return '';
  }

  // ---------------- 解析接口 ----------------

  private static async tryJx(videoUrl: string, jx: string): Promise<string> {
    const reqUrl: string = PlayUrlResolver.buildJxRequest(jx, videoUrl);
    let text: string = '';
    try {
      text = await HttpUtil.getText(reqUrl);
    } catch (e) {
      return '';
    }
    const trimmed: string = text.trim();
    if (trimmed.length === 0) {
      return '';
    }

    // 返回 JSON：取 url / data / playUrl / result
    if (trimmed.startsWith('{')) {
      try {
        const o = JSON.parse(trimmed) as Record<string, Object>;
        const cand: string = PlayUrlResolver.pickUrlFromJson(o);
        if (PlayUrlResolver.isHttpUrl(cand)) {
          return cand;
        }
      } catch (e) {
        // 落到下面
      }
    }
    // 返回 m3u8 文本：解析接口本身就是代理流
    if (trimmed.startsWith('#EXTM3U')) {
      return reqUrl;
    }
    // 返回纯文本直链
    if (PlayUrlResolver.isHttpUrl(trimmed)) {
      return trimmed.split('\n')[0].trim();
    }
    return '';
  }

  private static pickUrlFromJson(o: Record<string, Object>): string {
    const u = o['url'];
    if (typeof u === 'string' && (u as string).length > 0) {
      return u as string;
    }
    const d = o['data'];
    if (typeof d === 'string' && (d as string).length > 0) {
      return d as string;
    }
    if (d !== null && d !== undefined && typeof d === 'object') {
      const dd = d as Record<string, Object>;
      const du = dd['url'];
      if (typeof du === 'string' && (du as string).length > 0) {
        return du as string;
      }
    }
    const names: string[] = ['playUrl', 'result', 'm3u8', 'link'];
    for (let i = 0; i < names.length; i++) {
      const v = o[names[i]];
      if (typeof v === 'string' && (v as string).length > 0) {
        return v as string;
      }
    }
    return '';
  }

  private static buildJxRequest(jx: string, videoUrl: string): string {
    if (jx.includes('{url}')) {
      return jx.replace('{url}', encodeURIComponent(videoUrl));
    }
    if (jx.endsWith('=')) {
      return jx + encodeURIComponent(videoUrl);
    }
    return jx + videoUrl;
  }

  // ---------------- 网页播放页 ----------------

  /**
   * 播放页（macCMS / DPlayer / hls.js）几乎都把真实地址写进内联脚本。
   * 先按 macCMS 的 player_aaaa 精确解（支持 encrypt 0/1/2），
   * 解不出再从整页里揪 .m3u8 / .mp4；解出来仍是网页就再抓一层。
   */
  private static async readPlayerPage(u: string): Promise<string> {
    const first: string = await PlayUrlResolver.readPage(u);
    if (first.length === 0) {
      return '';
    }
    if (PlayUrlResolver.isDirect(first)) {
      return first;
    }
    if (!PlayUrlResolver.isHttpUrl(first)) {
      return '';
    }
    // 上游播放页：只再抓一层，防止站点互相指来指去
    const second: string = await PlayUrlResolver.readPage(first);
    if (second.length > 0 && PlayUrlResolver.isDirect(second)) {
      return second;
    }
    return '';
  }

  /** 抓一次页面，返回页内解出的播放地址（可能是网页） */
  /** 取 http(s)://host/ 作为 Referer：播放页普遍校验 Referer，空着容易被当成盗链 */
  private static originOf(u: string): string {
    const i: number = u.indexOf('://');
    if (i < 0) {
      return '';
    }
    const slash: number = u.indexOf('/', i + 3);
    return slash > 0 ? u.substring(0, slash + 1) : u + '/';
  }

  private static async readPage(u: string): Promise<string> {
    if (!PlayUrlResolver.isHttpUrl(u)) {
      return '';
    }
    let text: string = '';
    try {
      // 必须用桌面 UA：番剧站按 UA 分流，手机 UA 会拿到手机版（甚至一个空壳），
      // 里面的 player_aaaa 与 m3u8 全都没有，抓回来等于白抓。
      text = await HttpUtil.getTextWith(u, PlayUrlResolver.originOf(u), DESKTOP_UA);
    } catch (e) {
      logPlay('抓页面失败 ' + u + ' : ' + (e as Error).message);
      return '';
    }
    if (text.length === 0) {
      return '';
    }
    const t: string = text.trim();
    if (t.startsWith('#EXTM3U')) {
      return u;
    }
    if (t.length > 1200000) {
      return '';
    }
    const fromPlayer: string = MacCmsPlayer.parse(t);
    if (PlayUrlResolver.isHttpUrl(fromPlayer)) {
      logPlay('player_aaaa ' + u + ' => ' + fromPlayer);
      return fromPlayer;
    }
    const picked: string = PlayUrlResolver.pickMedia(t);
    logPlay('页面 len=' + t.length + ' player_aaaa=' + (fromPlayer.length > 0 ? fromPlayer : '(空)') +
      ' picked=' + (picked.length > 0 ? picked : '(空)') + ' ' + u);
    return picked;
  }

  /** 从任意文本里揪出第一个像播放地址的 URL（优先 m3u8） */
  private static pickMedia(text: string): string {
    const lower: string = text.toLowerCase();
    const keys: string[] = ['.m3u8', '.mp4'];
    for (let k = 0; k < keys.length; k++) {
      const key: string = keys[k];
      let from: number = 0;
      for (let guard = 0; guard < 40; guard++) {
        const at: number = lower.indexOf(key, from);
        if (at < 0) {
          break;
        }
        const end: number = PlayUrlResolver.reachEnd(text, at + key.length);
        const cand: string = PlayUrlResolver.expandUrl(text, at + key.length, end);
        if (cand.length > 0) {
          return cand;
        }
        from = at + key.length;
      }
    }
    return '';
  }

  /** 从扩展名往右吃到引号/空白/括号为止（保留 ? 参数） */
  private static reachEnd(text: string, from: number): number {
    const stop: string = ' \t\r\n"\'`<>()[]{},|\\';
    let e: number = from;
    while (e < text.length) {
      const ch: string = text.charAt(e);
      if (stop.indexOf(ch) >= 0) {
        break;
      }
      e++;
    }
    return e;
  }

  /** 从扩展名往左回溯到协议头，得到完整 URL */
  private static expandUrl(text: string, mid: number, end: number): string {
    const stop: string = ' \t\r\n"\'`<>()[]{};,|';
    let s: number = mid;
    while (s > 0) {
      const ch: string = text.charAt(s - 1);
      if (stop.indexOf(ch) >= 0) {
        break;
      }
      s--;
    }
    let raw: string = text.substring(s, end);
    // JSON 里常见 https:\/\/host\/a.m3u8
    raw = raw.split('\\/').join('/');
    if (raw.startsWith('//')) {
      return 'https:' + raw;
    }
    const at: number = raw.toLowerCase().lastIndexOf('http');
    if (at > 0) {
      raw = raw.substring(at);
    }
    if (!PlayUrlResolver.isHttpUrl(raw)) {
      return '';
    }
    // 过滤掉明显不是播放地址的字符串（如页面里提到的 sdk 地址）
    const low: string = raw.toLowerCase();
    if (low.includes('player.min.js') || low.includes('hls.min.js') || low.includes('hls.js')) {
      return '';
    }
    return raw;
  }

  // ---------------- 兜底猜测 ----------------

  private static async probeIndex(u: string): Promise<string> {
    // 最后一段带扩展名（.html/.php）就不猜
    const noQuery: string = u.split('?')[0];
    const slash: number = noQuery.lastIndexOf('/');
    const last: string = slash >= 0 ? noQuery.substring(slash + 1) : noQuery;
    if (last.includes('.')) {
      return '';
    }
    const base: string = u.endsWith('/') ? u : u + '/';
    try {
      const t: string = await HttpUtil.getText(base + 'index.m3u8');
      if (t.trim().startsWith('#EXTM3U')) {
        return base + 'index.m3u8';
      }
    } catch (e) {
      // 忽略
    }
    return '';
  }
}
