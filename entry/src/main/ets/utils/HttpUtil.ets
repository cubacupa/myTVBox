import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { FileStore } from './FileStore';
import { DoubanAuth } from './DoubanAuth';

/**
 * 网络工具（GET / JSON）
 *
 * 关于 HTTP 400：它表示"请求已到达服务器，但服务器认为这个请求不合法"，
 * 与 DNS、网络不通、明文拦截无关，问题出在请求本身。TVBox 源站常见 400 成因：
 *   1) 域名含中文（如 www.饭太硬.cc）—— HTTP 请求行与 Host 头只能是 ASCII，
 *      nginx 解析到 UTF-8 字节会直接回 "400 Bad Request"，必须先转 Punycode
 *   2) http:// 打到 https 端口 —— nginx 回 400 "plain HTTP request was sent to HTTPS port"
 *   3) 空 / 异常 User-Agent 被源站或 CDN(WAF) 拒绝
 *   4) GET 请求携带 Content-Type: application/json 却无 body，被部分 WAF 判为非法
 *   5) 粘贴地址时带入换行、全角空格、中文标点、零宽字符 → URL 非法
 *   6) api 以 ? 或 & 结尾时拼接成 "?&ac=list"（空参数），部分服务端 400
 *
 * 本类对应处理：清洗地址、中文域名自动 Punycode、补齐浏览器 UA、
 * GET 不带 body 类 Content-Type、http→https 自动重试、错误带服务端响应体片段。
 */
const UA: string =
  'Mozilla/5.0 (Linux; Android 10; SmartTV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36';

/**
 * TVBox 生态里很多配置站按 UA 分流：浏览器 UA 给网页/跳转，okhttp UA 才给配置
 * （饭太硬 /tv 就是典型——okhttp 拿到的是一张"图片壳 + Base64 配置"）。
 * 正常站点用浏览器 UA 即可，所以浏览器优先、okhttp 兜底，避免多一次请求。
 */
const OKHTTP_UA: string = 'okhttp/3.12.13';

interface RawResp {
  code: number;
  text: string;
}

interface ConfigAttempt {
  ok: boolean;
  text: string;
  code: number;
  err: string;
}

/** 落盘的「这个域名只能用 https」记录（http 打不通；老文件可能缺字段，读时宽松） */
interface HttpsOnlyHost {
  h?: string;
  t?: number;
}

const F_HTTPS_ONLY: string = 'tvbox_https_only.json';
/** 记忆有效期：过了就当没记住，重新先试一次 http —— 站点可能已经能走 http 了 */
const HTTPS_ONLY_TTL_MS: number = 7 * 24 * 3600 * 1000;

// ---- Punycode (RFC 3492) 常量 ----
const PC_BASE: number = 36;
const PC_TMIN: number = 1;
const PC_TMAX: number = 26;
const PC_SKEW: number = 38;
const PC_DAMP: number = 700;
const PC_INITIAL_BIAS: number = 72;
const PC_INITIAL_N: number = 128;

export class HttpUtil {
  /**
   * 网络策略：默认用 http，只有 http 确实打不通时才用 https（用户要求）。
   * 多数采集站（如百度采集 api.apibdzy.com）http 稳定在 1 秒级，https 却 1s~38s 抖动，
   * 所以对 https 地址也先用 http 试；只有 http 连不上 / 非 200 时才回退 https。
   *
   * 对确实只能走 https 的域名，落盘记一条（tvbox_https_only.json），
   * 下次直接 https，不再为它白等一次 http；7 天后自动失效、重新先试 http。
   */
  private static httpsOnly: string[] = [];
  private static httpsTs: number[] = [];
  private static ctx: common.Context | null = null;
  private static loaded: boolean = false;

  /** 入口页启动时调用一次（Index.boot）：把上次记住的域名读回内存，只会加载一次 */
  static init(ctx: common.Context): void {
    HttpUtil.ctx = ctx;
    if (HttpUtil.loaded) {
      return;
    }
    HttpUtil.loaded = true;
    const txt: string = FileStore.readText(ctx, F_HTTPS_ONLY);
    if (!txt) {
      return;
    }
    try {
      const arr = JSON.parse(txt) as HttpsOnlyHost[];
      if (!Array.isArray(arr)) {
        return;
      }
      const now: number = Date.now();
      const hosts: string[] = [];
      const ts: number[] = [];
      let dropped: boolean = false;
      for (const a of arr) {
        const h: string = (a.h ?? '').trim().toLowerCase();
        const t: number = a.t ?? 0;
        if (h.length === 0 || now - t > HTTPS_ONLY_TTL_MS || now < t) {
          dropped = true;
          continue;
        }
        if (hosts.indexOf(h) < 0) {
          hosts.push(h);
          ts.push(t);
        }
      }
      HttpUtil.httpsOnly = hosts;
      HttpUtil.httpsTs = ts;
      if (dropped) {
        HttpUtil.save();
      }
    } catch (e) {
      // 文件损坏，当作没有记录
    }
  }

  private static save(): void {
    const ctx: common.Context | null = HttpUtil.ctx;
    if (ctx === null) {
      return;
    }
    const arr: HttpsOnlyHost[] = [];
    for (let i = 0; i < HttpUtil.httpsOnly.length; i++) {
      const t: number = i < HttpUtil.httpsTs.length ? HttpUtil.httpsTs[i] : 0;
      arr.push({ h: HttpUtil.httpsOnly[i], t: t });
    }
    FileStore.writeText(ctx, F_HTTPS_ONLY, JSON.stringify(arr));
  }

  /** 记下这个域名只能用 https（http 打不通）：内存 + 落盘 */
  private static markHttps(host: string): void {
    if (host.length === 0) {
      return;
    }
    const i: number = HttpUtil.httpsOnly.indexOf(host);
    if (i >= 0) {
      HttpUtil.httpsTs[i] = Date.now();
    } else {
      HttpUtil.httpsOnly.push(host);
      HttpUtil.httpsTs.push(Date.now());
    }
    HttpUtil.save();
  }

  /** 忘掉「只能用 https」这条记忆（http 又能用了，或记忆过期） */
  private static unmarkHttps(host: string): void {
    const i: number = HttpUtil.httpsOnly.indexOf(host);
    if (i < 0) {
      return;
    }
    HttpUtil.httpsOnly.splice(i, 1);
    HttpUtil.httpsTs.splice(i, 1);
    HttpUtil.save();
  }

  private static needHttps(host: string): boolean {
    return host.length > 0 && HttpUtil.httpsOnly.indexOf(host) >= 0;
  }

  /** 取 URL 里的主机名（小写，不含端口） */
  private static hostOf(u: string): string {
    const i: number = u.indexOf('://');
    if (i < 0) {
      return '';
    }
    const rest: string = u.substring(i + 3);
    let end: number = rest.length;
    const marks: string[] = ['/', '?', '#', ':'];
    for (const m of marks) {
      const k: number = rest.indexOf(m);
      if (k >= 0 && k < end) {
        end = k;
      }
    }
    return rest.substring(0, end).toLowerCase();
  }

  /** 清洗地址：粘贴来的 URL 常带隐藏字符，能直接导致 400 */
  static clean(url: string): string {
    let u: string = (url ?? '').trim();
    // 控制字符、全角空格、零宽字符、BOM
    u = u.replace(/[\u0000-\u0020\u007F\u200B-\u200D\uFEFF\u3000]/g, '');
    // 中文标点（误输入）
    u = u.replace(/[“”‘’《》〈〉]/g, '');
    // HTML 转义残留（从网页复制配置地址时常见）
    u = u.replace(/&amp;/g, '&');
    // 只贴了域名，没有协议头
    if (u.length > 0 && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(u)) {
      u = 'http://' + u.replace(/^\/+/, '');
    }
    // 中文域名 → Punycode（否则 nginx 直接 400）
    return HttpUtil.asciiUrl(u);
  }

  private static isAscii(s: string): boolean {
    for (let i = 0; i < s.length; i++) {
      if (s.charCodeAt(i) > 0x7F) {
        return false;
      }
    }
    return true;
  }

  /** 把 URL 里的主机名部分转成 ASCII（Punycode），其余原样保留 */
  static asciiUrl(u: string): string {
    const schemeEnd: number = u.indexOf('://');
    if (schemeEnd < 0) {
      return u;
    }
    const prefix: string = u.substring(0, schemeEnd + 3);
    const tail: string = u.substring(schemeEnd + 3);

    // 截出 authority（到第一个 / ? # 为止）
    let cut: number = tail.length;
    const marks: string[] = ['/', '?', '#'];
    for (let i = 0; i < marks.length; i++) {
      const idx: number = tail.indexOf(marks[i]);
      if (idx >= 0 && idx < cut) {
        cut = idx;
      }
    }
    const authority: string = tail.substring(0, cut);
    const rest: string = tail.substring(cut);
    if (authority.length === 0) {
      return u;
    }

    // 拆 userinfo / host / port
    let userinfo: string = '';
    let hostPort: string = authority;
    const at: number = authority.lastIndexOf('@');
    if (at >= 0) {
      userinfo = authority.substring(0, at + 1);
      hostPort = authority.substring(at + 1);
    }
    let port: string = '';
    const colon: number = hostPort.lastIndexOf(':');
    // IPv6 字面量 [::1] 不拆端口
    if (colon >= 0 && hostPort.indexOf(']') < 0) {
      port = hostPort.substring(colon);
      hostPort = hostPort.substring(0, colon);
    }

    const newHost: string = HttpUtil.isAscii(hostPort) ? hostPort : HttpUtil.labelToAscii(hostPort);
    const newRest: string = HttpUtil.encodeNonAscii(rest);
    if (newHost === hostPort && newRest === rest) {
      return u;
    }
    return prefix + userinfo + newHost + port + newRest;
  }

  /**
   * 路径/查询里的非 ASCII 字符转百分号编码。
   * 主机名要转 Punycode，路径要转 %XX，两者不能混用，否则仍是 400。
   * 已经是 %XX 的部分是纯 ASCII，不会被二次编码。
   */
  private static encodeNonAscii(s: string): string {
    if (HttpUtil.isAscii(s)) {
      return s;
    }
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      const code: number = s.codePointAt(i) ?? 0;
      if (code > 0x7F) {
        const ch: string = String.fromCodePoint(code);
        out += encodeURIComponent(ch);
        i += ch.length;
      } else {
        out += s.charAt(i);
        i++;
      }
    }
    return out;
  }

  private static labelToAscii(host: string): string {
    const parts: string[] = host.split('.');
    let out: string = '';
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i];
      if (i > 0) {
        out += '.';
      }
      if (p.length === 0 || HttpUtil.isAscii(p)) {
        out += p;
      } else {
        out += 'xn--' + HttpUtil.punyEncode(p);
      }
    }
    return out;
  }

  private static digitToBasic(d: number): string {
    return String.fromCharCode(d + 22 + (d < 26 ? 75 : 0));
  }

  private static adapt(delta: number, numPoints: number, firstTime: boolean): number {
    let d: number = firstTime ? Math.floor(delta / PC_DAMP) : Math.floor(delta / 2);
    d += Math.floor(d / numPoints);
    let k: number = 0;
    while (d > ((PC_BASE - PC_TMIN) * PC_TMAX) / 2) {
      d = Math.floor(d / (PC_BASE - PC_TMIN));
      k += PC_BASE;
    }
    return Math.floor(k + ((PC_BASE - PC_TMIN + 1) * d) / (d + PC_SKEW));
  }

  private static toCodePoints(s: string): number[] {
    const out: number[] = [];
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        const c2: number = s.charCodeAt(i + 1);
        if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
          out.push((c - 0xD800) * 0x400 + (c2 - 0xDC00) + 0x10000);
          i++;
          continue;
        }
      }
      out.push(c);
    }
    return out;
  }

  /** 单个 label 的 Punycode 编码（不含 xn-- 前缀） */
  private static punyEncode(s: string): string {
    const input: number[] = HttpUtil.toCodePoints(s);
    const len: number = input.length;
    const out: string[] = [];
    for (let i = 0; i < len; i++) {
      if (input[i] < 0x80) {
        out.push(String.fromCharCode(input[i]));
      }
    }
    const basicLength: number = out.length;
    let handled: number = basicLength;
    if (basicLength > 0) {
      out.push('-');
    }

    let n: number = PC_INITIAL_N;
    let delta: number = 0;
    let bias: number = PC_INITIAL_BIAS;

    while (handled < len) {
      let m: number = 2147483647;
      for (let i = 0; i < len; i++) {
        if (input[i] >= n && input[i] < m) {
          m = input[i];
        }
      }
      delta += (m - n) * (handled + 1);
      n = m;
      for (let i = 0; i < len; i++) {
        const cp: number = input[i];
        if (cp < n) {
          delta++;
        }
        if (cp === n) {
          let q: number = delta;
          for (let k = PC_BASE; ; k += PC_BASE) {
            const t: number = k <= bias ? PC_TMIN : (k >= bias + PC_TMAX ? PC_TMAX : k - bias);
            if (q < t) {
              break;
            }
            const qMinusT: number = q - t;
            const baseMinusT: number = PC_BASE - t;
            out.push(HttpUtil.digitToBasic(t + (qMinusT % baseMinusT)));
            q = Math.floor(qMinusT / baseMinusT);
          }
          out.push(HttpUtil.digitToBasic(q));
          bias = HttpUtil.adapt(delta, handled + 1, handled === basicLength);
          delta = 0;
          handled++;
        }
      }
      delta++;
      n++;
    }
    return out.join('');
  }

  private static bodyOf(resp: http.HttpResponse): string {
    if (typeof resp.result === 'string') {
      return resp.result;
    }
    return '';
  }

  /** 单次请求，只 reject 网络层错误，不判定业务状态 */
  private static once(url: string): Promise<http.HttpResponse> {
    return new Promise<http.HttpResponse>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING,
        header: {
          'User-Agent': UA,
          'Accept': '*/*',
          'Accept-Language': 'zh-CN,zh;q=0.9'
        }
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        resolve(resp);
      }).catch((err: BusinessError) => {
        req.destroy();
        reject(new Error(err.message));
      });
    });
  }

  static async getText(url: string): Promise<string> {
    const origin: string = (url ?? '').trim();
    const u0: string = HttpUtil.clean(url);
    if (u0.length === 0) {
      throw new Error('地址为空');
    }
    const host: string = HttpUtil.hostOf(u0);
    const isHttps: boolean = /^https:\/\//i.test(u0);

    // ===== 默认 http：https 地址先用 http 试，http 真不行才用 https =====
    if (isHttps && !HttpUtil.needHttps(host)) {
      const httpU: string = u0.replace(/^https:\/\//i, 'http://');
      let resp: http.HttpResponse;
      try {
        resp = await HttpUtil.once(httpU);
      } catch (e) {
        // http 连不上 / 超时：迫不得已才走 https
        return HttpUtil.finish(await HttpUtil.once(u0), u0, origin);
      }
      if (resp.responseCode === 200) {
        return HttpUtil.bodyOf(resp);
      }
      // http 没拿到数据（明文打 https 端口 / 301 / 403 / 5xx…）：
      // 回退 https 再试；成了就记住「这个域名只能用 https」，下次别再白试 http
      try {
        const r2: http.HttpResponse = await HttpUtil.once(u0);
        if (r2.responseCode === 200) {
          HttpUtil.markHttps(host);
          return HttpUtil.bodyOf(r2);
        }
        return HttpUtil.finish(r2, u0, origin);
      } catch (e2) {
        // https 也抛错：用 http 的响应继续报错（它有状态码/内容，更利于诊断）
        return HttpUtil.finish(resp, httpU, origin);
      }
    }

    // ===== 地址本来就是 http，或该域名已确认只能用 https =====
    let resp: http.HttpResponse;
    try {
      resp = await HttpUtil.once(u0);
    } catch (e) {
      // http 原地址打不通：迫不得已升级 https 再试一次
      if (/^http:\/\//i.test(u0)) {
        const alt: string = u0.replace(/^http:\/\//i, 'https://');
        try {
          const r2: http.HttpResponse = await HttpUtil.once(alt);
          if (r2.responseCode === 200) {
            HttpUtil.markHttps(HttpUtil.hostOf(u0));
            return HttpUtil.bodyOf(r2);
          }
          return HttpUtil.finish(r2, alt, origin);
        } catch (e2) {
          throw new Error((e as Error).message);
        }
      }
      throw new Error((e as Error).message);
    }

    // http 打到 https 端口，nginx 回 400：换 https 再来一次
    if (resp.responseCode === 400 && /^http:\/\//i.test(u0)
      && /https port|plain http|https/i.test(HttpUtil.bodyOf(resp))) {
      const alt: string = u0.replace(/^http:\/\//i, 'https://');
      try {
        const r2: http.HttpResponse = await HttpUtil.once(alt);
        if (r2.responseCode === 200) {
          HttpUtil.markHttps(HttpUtil.hostOf(u0));
          return HttpUtil.bodyOf(r2);
        }
      } catch (e) {
        // 升级 https 也失败，继续走下面的原错误
      }
    }

    return HttpUtil.finish(resp, u0, origin);
  }

  /** 统一收尾：200 返回正文，否则抛出带诊断信息的错误 */
  private static finish(resp: http.HttpResponse, u: string, origin: string): string {
    const body: string = HttpUtil.bodyOf(resp);
    if (resp.responseCode === 200) {
      return body;
    }
    const brief: string = body.replace(/\s+/g, ' ').substring(0, 180);
    let msg: string = 'HTTP ' + resp.responseCode + HttpUtil.hint(resp.responseCode);
    msg += '\n实际请求：' + u;
    if (origin !== u && !HttpUtil.isAscii(origin)) {
      msg += '\n（原地址含中文域名，已自动转为 Punycode）';
    }
    if (brief.length > 0) {
      msg += '\n服务器返回：' + brief;
    }
    throw new Error(msg);
  }

  private static hint(code: number): string {
    if (code === 400) {
      return '（请求不合服务器规范：地址错、中文域名未转码、http/https 混用或被 WAF 拦截）';
    }
    if (code === 401 || code === 403) {
      return '（被拒绝：需要鉴权、UA/Referer 校验或防盗链）';
    }
    if (code === 404) {
      return '（地址不存在：路径写错或该接口已下线）';
    }
    if (code === 500 || code === 502 || code === 503) {
      return '（源站故障或过载，换站点/稍后重试）';
    }
    return '';
  }

  /**
   * 按指定 UA 拉一次，返回状态码 + 文本。
   * 用 ARRAY_BUFFER 接收再宽松解码：配置可能是二进制（图片壳），
   * STRING 模式遇到非法 UTF-8 字节有丢内容的可能，而配置的 ASCII 部分必须完好。
   */
  private static onceRaw(url: string, ua: string): Promise<RawResp> {
    return new Promise<RawResp>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: {
          'User-Agent': ua,
          'Accept': '*/*',
          'Accept-Language': 'zh-CN,zh;q=0.9'
        }
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        let text: string = '';
        if (typeof resp.result === 'string') {
          text = resp.result;
        } else if (resp.result !== undefined && resp.result !== null) {
          const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
          text = decoder.decodeToString(new Uint8Array(resp.result as ArrayBuffer));
        }
        const r: RawResp = { code: resp.responseCode, text: text };
        resolve(r);
      }).catch((err: BusinessError) => {
        req.destroy();
        reject(new Error(err.message));
      });
    });
  }

  /** 内容像不像配置：JSON 开头，或带 ** 路标的伪装配置 */
  private static looksConfig(t: string): boolean {
    const s: string = (t ?? '').trim();
    if (s.length === 0) {
      return false;
    }
    const c: string = s.charAt(0);
    if (c === '{' || c === '[' || c === '/') {
      return true;
    }
    return t.indexOf('**') >= 0;
  }

  /** 浏览器 UA 优先、okhttp UA 兜底，取到像配置的那一份 */
  private static async tryConfig(u: string): Promise<ConfigAttempt> {
    const r: ConfigAttempt = { ok: false, text: '', code: 0, err: '' };
    try {
      const a: RawResp = await HttpUtil.onceRaw(u, UA);
      r.code = a.code;
      if (a.code === 200) {
        if (HttpUtil.looksConfig(a.text)) {
          r.ok = true;
          r.text = a.text;
          return r;
        }
        r.text = a.text;
      }
    } catch (e) {
      r.err = (e as Error).message;
    }
    try {
      const b: RawResp = await HttpUtil.onceRaw(u, OKHTTP_UA);
      if (b.code === 200) {
        if (HttpUtil.looksConfig(b.text)) {
          r.ok = true;
          r.text = b.text;
          return r;
        }
        if (r.text.length === 0) {
          r.text = b.text;
        }
        if (r.code === 0) {
          r.code = b.code;
        }
      } else if (r.code === 0) {
        r.code = b.code;
      }
    } catch (e) {
      if (r.err.length === 0) {
        r.err = (e as Error).message;
      }
    }
    return r;
  }

  /**
   * 专门用于拉配置地址：双 UA 尝试 + http/https 混用纠正。
   * 与 getText 的区别是它接受二进制内容（伪装成图片的配置），
   * 并会把结果交给 ConfigDecoder 还原。
   */
  static async getConfigText(url: string): Promise<string> {
    const u0: string = HttpUtil.clean(url);
    if (u0.length === 0) {
      throw new Error('地址为空');
    }
    let u: string = u0;
    let r: ConfigAttempt;
    const host: string = HttpUtil.hostOf(u0);

    // 默认 http：https 配置地址也先用 http 试，http 真不行才 https
    if (/^https:\/\//i.test(u0) && !HttpUtil.needHttps(host)) {
      const httpU: string = u0.replace(/^https:\/\//i, 'http://');
      r = await HttpUtil.tryConfig(httpU);
      if (r.ok) {
        return r.text;
      }
      const rs: ConfigAttempt = await HttpUtil.tryConfig(u0);
      if (rs.ok) {
        HttpUtil.markHttps(host);
        return rs.text;
      }
      // 两边都没识别成配置：优先把「拿到了内容」的那份交给上层判断是不是网页
      if (r.text.length > 0) {
        return r.text;
      }
      if (rs.text.length > 0) {
        return rs.text;
      }
      let msgH: string = rs.err.length > 0 ? rs.err : ('HTTP ' + rs.code + HttpUtil.hint(rs.code));
      msgH += '\n实际请求：' + u0;
      throw new Error(msgH);
    }

    r = await HttpUtil.tryConfig(u);

    // http 打到 https 端口时 nginx 回 400，换 https 再来一次
    if (!r.ok && r.code === 400 && /^http:\/\//i.test(u)
      && /https port|plain http|https/i.test(r.text)) {
      const alt: string = u.replace(/^http:\/\//i, 'https://');
      const r2: ConfigAttempt = await HttpUtil.tryConfig(alt);
      if (r2.ok) {
        HttpUtil.markHttps(HttpUtil.hostOf(u));
        return r2.text;
      }
      u = alt;
      r = r2;
    }

    if (r.ok) {
      return r.text;
    }
    if (r.text.length > 0) {
      // 拿到了内容但不是配置：交给上层给出「这是网页/不是接口」的提示
      return r.text;
    }
    let msg: string = r.err.length > 0 ? r.err : ('HTTP ' + r.code + HttpUtil.hint(r.code));
    msg += '\n实际请求：' + u;
    throw new Error(msg);
  }

  /**
   * 带自定义超时的文本请求。给慢站用：dmbus.cc 这类 macCMS 的 ajax/data 接口
   * 服务端要现查库，实测 10~18 秒才回（偶尔 40 秒超时），默认 12 秒 readTimeout
   * 必然掐断 → browseCms 返回 null → 掉到空词搜索兜底，全库 6301 部只剩 36 部。
   */
  static async getTextWithTimeout(url: string, referer: string, ua: string,
    connectTimeout: number, readTimeout: number): Promise<string> {
    const u: string = HttpUtil.clean(url);
    if (u.length === 0) {
      throw new Error('地址为空');
    }
    const host: string = HttpUtil.hostOf(u);
    const ck: string = (host === 'douban.com' || host.endsWith('.douban.com'))
      ? DoubanAuth.get() : '';
    const header: Record<string, string> = {
      'User-Agent': ua,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer
    };
    if (ck.length > 0) {
      header['Cookie'] = ck;
    }
    return new Promise<string>((resolve, reject) => {
      const req = http.createHttp();
      req.request(u, {
        method: http.RequestMethod.GET,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        expectDataType: http.HttpDataType.STRING,
        header: header
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        if (resp.responseCode === 200) {
          resolve(HttpUtil.bodyOf(resp));
        } else {
          reject(new Error('HTTP ' + resp.responseCode));
        }
      }).catch((err: BusinessError) => {
        req.destroy();
        reject(new Error(err.message));
      });
    });
  }

  /**
   * 带自定义 Referer 的 GET（只接受 200，其余抛错）。
   * 豆瓣的 rexxar 接口有两道硬门槛：
   *   1) UA 必须是浏览器 UA，okhttp 之类直接回 1287 invalid_request
   *   2) Referer 必须指向具体的 subject 页；只给域名会返回推荐榜数据，不给直接 1287
   * 另外剧集详情会 301 跳到 /api/v2/tv/{id}，http 模块默认跟随重定向，无需额外处理。
   */
  static async getTextWith(url: string, referer: string, ua: string): Promise<string> {
    const u: string = HttpUtil.clean(url);
    if (u.length === 0) {
      throw new Error('地址为空');
    }
    // 豆瓣域名自动带上登录 Cookie（若用户在设置页填过）。
    // 未登录时不发这个头：空 Cookie 反而会被豆瓣当成异常请求。
    const host: string = HttpUtil.hostOf(u);
    const ck: string = (host === 'douban.com' || host.endsWith('.douban.com'))
      ? DoubanAuth.get() : '';
    const header: Record<string, string> = {
      'User-Agent': ua,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Referer': referer
    };
    if (ck.length > 0) {
      header['Cookie'] = ck;
    }
    return new Promise<string>((resolve, reject) => {
      const req = http.createHttp();
      req.request(u, {
        method: http.RequestMethod.GET,
        connectTimeout: 12000,
        readTimeout: 12000,
        expectDataType: http.HttpDataType.STRING,
        header: header
      }).then((resp: http.HttpResponse) => {
        req.destroy();
        if (resp.responseCode === 200) {
          resolve(HttpUtil.bodyOf(resp));
        } else {
          reject(new Error('HTTP ' + resp.responseCode));
        }
      }).catch((err: BusinessError) => {
        req.destroy();
        reject(new Error(err.message));
      });
    });
  }

  /**
   * 下载二进制内容到指定文件，返回实际写入的字节数；失败或内容无效返回 0。
   *
   * 豆瓣图片服务器有防盗链：不带 Referer 直接回 418，且响应体是一段 14 字节的文本，
   * 所以这里必须校验大小（真实海报 20KB 起步），否则会把错误文本当图片存下来，
   * 之后 Image 加载一坨文本只会白白消耗一次 IO。
   */
  static async downloadTo(url: string, referer: string, ua: string, destPath: string): Promise<number> {
    const u: string = HttpUtil.clean(url);
    if (u.length === 0) {
      return 0;
    }
    let buf: ArrayBuffer | null = null;
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(u, {
        method: http.RequestMethod.GET,
        connectTimeout: 12000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: {
          'User-Agent': ua,
          'Accept': 'image/avif,image/webp,image/*,*/*;q=0.8',
          'Referer': referer
        }
      });
      if (resp.responseCode === 200 && resp.result instanceof ArrayBuffer) {
        buf = resp.result as ArrayBuffer;
      }
    } catch (e) {
      buf = null;
    } finally {
      req.destroy();
    }
    if (buf === null || buf.byteLength < 1024) {
      return 0;
    }
    try {
      const f = fs.openSync(destPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, buf);
      fs.closeSync(f);
      return buf.byteLength;
    } catch (e) {
      return 0;
    }
  }

  /**
   * 有些采集站的 vod_id 是 18 位大整数（巨量资源就是），JSON.parse 按 IEEE754
   * 解析会丢精度：629109902295433220 → 629109902295433216，
   * 再拿它去 ac=detail&ids= 查详情必然返回空（界面显示「没有取到影片详情」）。
   * 解析前给这种超大 ID 字面量加引号，当字符串保住原值。
   * 只匹配 16 位以上的整数字面量：暴风等站点的短 ID、total / page 等数字都不受影响，
   * 本来就是字符串的 ID 也不会被改动。
   */
  private static guardBigIds(s: string): string {
    return s.replace(/("vod_id"\s*:\s*)(\d{16,})/g, '$1"$2"');
  }

  static async getJson<T>(url: string): Promise<T> {
    const text: string = await HttpUtil.getText(url);
    return HttpUtil.parseJsonBody<T>(text, url);
  }

  /** 同 getJson，但自带 Referer / UA（站点按 UA 分流时必须用这个） */
  static async getJsonWith<T>(url: string, referer: string, ua: string): Promise<T> {
    const text: string = await HttpUtil.getTextWith(url, referer, ua);
    return HttpUtil.parseJsonBody<T>(text, url);
  }

  /** 同 getJsonWith，但超时放宽给慢站（网页规则站的 macCMS 全库接口） */
  static async getJsonWithTimeout<T>(url: string, referer: string, ua: string,
    connectTimeout: number, readTimeout: number): Promise<T> {
    const text: string = await HttpUtil.getTextWithTimeout(
      url, referer, ua, connectTimeout, readTimeout);
    return HttpUtil.parseJsonBody<T>(text, url);
  }

  private static parseJsonBody<T>(text: string, url: string): T {
    const t: string = text.trim();
    if (t.length === 0) {
      throw new Error('返回内容为空 · ' + HttpUtil.clean(url));
    }
    if (t.charAt(0) !== '{' && t.charAt(0) !== '[') {
      // 典型情况：返回了 HTML 拦截页 / 域名跳转页
      throw new Error('返回的不是 JSON（可能是拦截页或地址错误）· '
        + HttpUtil.clean(url) + '\n内容开头：' + t.substring(0, 120));
    }
    try {
      return JSON.parse(HttpUtil.guardBigIds(t)) as T;
    } catch (e) {
      throw new Error('JSON 解析失败 · ' + HttpUtil.clean(url) + '\n' + (e as Error).message);
    }
  }
}
