import { HttpUtil } from './HttpUtil';

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

    // ② 网页播放页 → 抓页内 m3u8
    const sniffed: string = await PlayUrlResolver.sniffPage(raw);
    if (sniffed.length > 0) {
      return sniffed;
    }

    // ③ 常见约定：/play/xxx 对应的流派生地址就是 /play/xxx/index.m3u8
    const probed: string = await PlayUrlResolver.probeIndex(raw);
    if (probed.length > 0) {
      return probed;
    }

    return PlayUrlResolver.isHttpUrl(raw) ? raw : '';
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

  // ---------------- 网页嗅探 ----------------

  /**
   * 播放页（DPlayer / hls.js / 自研播放器）几乎都会把真实地址写进内联脚本，
   * 形如 const vid = 'https://.../index.m3u8' 或 "url":"https:\/\/...m3u8"。
   * 抓一次 HTML，把 .m3u8 / .mp4 抠出来即可，不需要 WebView。
   */
  private static async sniffPage(u: string): Promise<string> {
    if (!PlayUrlResolver.isHttpUrl(u)) {
      return '';
    }
    let text: string = '';
    try {
      text = await HttpUtil.getText(u);
    } catch (e) {
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
    return PlayUrlResolver.pickMedia(t);
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
