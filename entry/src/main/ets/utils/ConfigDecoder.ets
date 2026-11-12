import { util } from '@kit.ArkTS';

/**
 * 伪装配置解码器（对齐 TVBox / catvod 的 Decoder）。
 *
 * 相当多 TVBox 配置站不愿让人直接抓 JSON，会把配置 Base64 后拼在任意内容的尾部
 * （最常见是一张图片），并在中间放一个「8 位随机字母数字 + **」当路标：
 *
 *     [JPEG 图片二进制][wRByCInE**][Base64(JSON)]
 *
 * TVBox 的解法（catvod/utils/Decoder.java）：
 *   1) 内容不是 JSON 且含 "**" → 进 Base64 分支
 *   2) 正则 [A-Za-z0-9]{8}\*\* 定位，**之前的全部丢掉（整张图片被丢弃）
 *   3) Base64.decode(..., Base64.DEFAULT)，Android 的解码器会忽略字符集外的非法字节
 *
 * 这里做等价实现：定位路标 → 取其后的全部 → 只留 base64 字符 → 补齐长度 → 解码。
 * 另外兜一层「整段就是 Base64」的配置。解不出来就原样返回，交给上层报错。
 */
export class ConfigDecoder {
  /** 把伪装配置还原成 JSON 文本；不是伪装的则原样返回 */
  static unwrap(text: string): string {
    const t: string = text ?? '';
    if (t.length === 0) {
      return t;
    }
    // 已经是配置（含以 // 注释开头的），不动它
    if (ConfigDecoder.looksJson(t)) {
      return t;
    }
    const from: number = ConfigDecoder.findMarker(t);
    if (from > 0) {
      const decoded: string = ConfigDecoder.decodeBase64(t.substring(from));
      if (decoded.length > 0) {
        return decoded;
      }
    }
    // 有些站不带路标，直接把整段作为 Base64 返回
    const whole: string = ConfigDecoder.decodeBase64(t);
    if (whole.length > 0) {
      return whole;
    }
    return t;
  }

  private static looksJson(t: string): boolean {
    const s: string = t.trim();
    if (s.length === 0) {
      return false;
    }
    const c: string = s.charAt(0);
    return c === '{' || c === '[' || c === '/';
  }

  /** 找到「8 位字母数字 + **」路标，返回 ** 之后的下标；没有则 -1 */
  private static findMarker(t: string): number {
    let from: number = 0;
    while (from < t.length) {
      const idx: number = t.indexOf('**', from);
      if (idx < 0) {
        return -1;
      }
      if (idx >= 8 && ConfigDecoder.alnumBefore(t, idx)) {
        return idx + 2;
      }
      from = idx + 2;
    }
    return -1;
  }

  private static alnumBefore(t: string, idx: number): boolean {
    for (let i = idx - 8; i < idx; i++) {
      const c: string = t.charAt(i);
      const ok: boolean = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
      if (!ok) {
        return false;
      }
    }
    return true;
  }

  /**
   * 宽松 Base64 解码：忽略字符集外的内容（图片二进制转字符串留下的乱码），
   * 去掉尾部 = 后补齐到 4 的倍数。解析结果必须真的含配置字段，否则视为失败。
   */
  private static decodeBase64(raw: string): string {
    let clean: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: string = raw.charAt(i);
      if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
        || c === '+' || c === '/' || c === '=') {
        clean += c;
      }
    }
    if (clean.length < 64) {
      return '';
    }
    let body: string = clean;
    while (body.length > 0 && body.charAt(body.length - 1) === '=') {
      body = body.substring(0, body.length - 1);
    }
    const rem: number = body.length % 4;
    if (rem === 1) {
      return '';
    }
    if (rem === 3) {
      body += '=';
    } else if (rem === 2) {
      body += '==';
    }
    try {
      const helper: util.Base64Helper = new util.Base64Helper();
      const bytes: Uint8Array = helper.decodeSync(body);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const out: string = decoder.decodeToString(bytes);
      const hit: boolean = out.indexOf('"sites"') >= 0 || out.indexOf('"lives"') >= 0
        || out.indexOf('"spider"') >= 0 || out.indexOf('"urls"') >= 0
        || out.indexOf('"parses"') >= 0;
      return hit ? out : '';
    } catch (e) {
      return '';
    }
  }
}
