import { util } from '@kit.ArkTS';

/**
 * macCMS 系播放页（/vodplay/xxx-1-1.html）通用解析。
 *
 * 这类页面把真实地址塞在内联脚本里：
 *   var player_aaaa = {"flag":"play","encrypt":2,"url":"JTY4JTc0..."}
 * url 按 encrypt 处理过：
 *   0  明文（可能带 \/ 转义）
 *   1  escape 过的明文（%68%74%74%70…）
 *   2  base64(escape(url))：先 base64 解码，再 percent 解码
 *
 * 静态抓一次 HTML 就能解出地址，比挂 WebView 嗅探快一个数量级；
 * 解出来可能是直链（m3u8/mp4），也可能是上游站的播放页，由调用方再抓一层。
 */
export class MacCmsPlayer {
  /** 从播放页 HTML 解出真实地址；解不出返回空串 */
  static parse(html: string): string {
    if (html === null || html === undefined || html.length === 0) {
      return '';
    }
    const at: number = html.indexOf('player_aaaa');
    if (at < 0) {
      return '';
    }
    const brace: number = html.indexOf('{', at);
    if (brace < 0) {
      return '';
    }
    const end: number = MacCmsPlayer.matchingBrace(html, brace);
    if (end < 0) {
      return '';
    }
    const body: string = html.substring(brace, end + 1);
    let obj: Record<string, Object> | null = null;
    try {
      obj = JSON.parse(body) as Record<string, Object>;
    } catch (e) {
      return '';
    }
    if (obj === null) {
      return '';
    }
    const rawUrl: Object | undefined = obj['url'];
    if (rawUrl === undefined || rawUrl === null || typeof rawUrl !== 'string') {
      return '';
    }
    let u: string = (rawUrl as string).trim();
    if (u.length === 0) {
      return '';
    }
    let enc: number = 0;
    const rawEnc: Object | undefined = obj['encrypt'];
    if (typeof rawEnc === 'number') {
      enc = rawEnc as number;
    } else if (typeof rawEnc === 'string') {
      const n: number = Number(rawEnc as string);
      enc = Number.isNaN(n) ? 0 : n;
    }
    if (enc === 2) {
      const decoded: string = MacCmsPlayer.base64ToText(u);
      if (decoded.length > 0) {
        u = decoded;
      }
    }
    if (enc === 1 || enc === 2) {
      u = MacCmsPlayer.percentDecode(u);
    }
    // JSON 里常见 https:\/\/host\/a.mp4
    u = u.split('\\/').join('/');
    return u.trim();
  }

  /** 从 braceAt 的 { 开始找到配对的 }，跳过字符串里的括号 */
  private static matchingBrace(s: string, braceAt: number): number {
    let depth: number = 0;
    let quote: string = '';
    for (let i: number = braceAt; i < s.length; i++) {
      const ch: string = s.charAt(i);
      if (quote.length > 0) {
        if (ch === '\\') {
          i++;
        } else if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === '\'') {
        quote = ch;
      } else if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0) {
          return i;
        }
      }
    }
    return -1;
  }

  /** percent 解码，非法串原样返回（部分站点会漏转义，不能因为一处 % 就整条丢掉） */
  private static percentDecode(s: string): string {
    try {
      return decodeURIComponent(s);
    } catch (e) {
      return s;
    }
  }

  /** base64 → utf8；兼容 url-safe 与缺省 padding */
  private static base64ToText(s: string): string {
    let t: string = s.split('-').join('+').split('_').join('/').trim();
    // 去掉换行
    t = t.replace(/\s+/g, '');
    if (t.length === 0) {
      return '';
    }
    while (t.length % 4 !== 0) {
      t += '=';
    }
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(t);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(bytes);
    } catch (e) {
      return '';
    }
  }
}
