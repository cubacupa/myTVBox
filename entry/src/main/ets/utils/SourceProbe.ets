import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 源接口体检：只测配置里填的地址（点播 API、直播订阅、多仓仓库），
 * 不展开到频道媒体 URL。收到响应头就算连通，立刻断开，不下载正文——
 * 直播列表几百 KB、点播接口一把拉全库，体检没必要付这个流量。
 *
 * 结果只反映 HTTP 层通不通、快不快，不代表里面的内容一定能播：
 * 网关校验 UA / Referer 时可能 HTTP 403 但播放器正常，所以不拉黑，
 * 只用来排序和显示。成功缓存 10 分钟、失败 2 分钟，重启 App 清空。
 */
export interface ProbeTarget {
  url: string;
  name: string;
}

export interface ProbeResult {
  url: string;
  name: string;
  ok: boolean;
  ms: number;
  reason: string;
  ts: number;
}

export class SourceProbe {
  private static readonly TIMEOUT_MS: number = 7000;
  private static readonly OK_TTL: number = 10 * 60 * 1000;
  private static readonly BAD_TTL: number = 2 * 60 * 1000;
  private static readonly UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  private static cache: Map<string, ProbeResult> = new Map();
  private static running: boolean = false;

  /** 同步查结果。undefined 表示还没测过或已过期 */
  static result(url: string): ProbeResult | undefined {
    const r: ProbeResult | undefined = SourceProbe.cache.get(url);
    if (r === undefined) {
      return undefined;
    }
    const ttl: number = r.ok ? SourceProbe.OK_TTL : SourceProbe.BAD_TTL;
    if (Date.now() - r.ts > ttl) {
      SourceProbe.cache.delete(url);
      return undefined;
    }
    return r;
  }

  /** 列表行上显示的一小段：通了给耗时，没通给原因，没测给空串 */
  static label(url: string): string {
    const r: ProbeResult | undefined = SourceProbe.result(url);
    if (r === undefined) {
      return '';
    }
    return r.ok ? (r.ms + 'ms') : r.reason;
  }

  static isRunning(): boolean {
    return SourceProbe.running;
  }

  /** 用户点「重测失败项」时只清失败的，成功的耗时保留 */
  static clearFailed(): void {
    const dead: string[] = [];
    for (const r of SourceProbe.cache.values()) {
      if (!r.ok) {
        dead.push(r.url);
      }
    }
    for (const u of dead) {
      SourceProbe.cache.delete(u);
    }
  }

  /** 有通过的吗——给「按耗时」排序用：成功永远排失败前面 */
  static rank(url: string): number {
    const r: ProbeResult | undefined = SourceProbe.result(url);
    if (r === undefined) {
      return 2;
    }
    return r.ok ? 0 : 1;
  }

  static latency(url: string): number {
    const r: ProbeResult | undefined = SourceProbe.result(url);
    return r === undefined ? Number.MAX_VALUE : r.ms;
  }

  /**
   * 批量体检，最多 8 个并发。已完成（缓存有效）的跳过；重复地址只测一次。
   * 不抛异常：单个地址失败只记结果，不影响其他地址。
   */
  static async run(targets: ProbeTarget[]): Promise<void> {
    if (SourceProbe.running) {
      return;
    }
    SourceProbe.running = true;
    try {
      const todo: ProbeTarget[] = [];
      const seen: Set<string> = new Set();
      for (const t of targets) {
        const u: string = (t.url ?? '').trim();
        if (!u.startsWith('http') || seen.has(u) || SourceProbe.result(u) !== undefined) {
          continue;
        }
        seen.add(u);
        todo.push({ url: u, name: t.name });
      }
      let i: number = 0;
      while (i < todo.length) {
        const batch: Promise<void>[] = [];
        const end: number = Math.min(todo.length, i + 8);
        while (i < end) {
          batch.push(SourceProbe.check(todo[i]));
          i++;
        }
        await Promise.all(batch);
      }
    } finally {
      SourceProbe.running = false;
    }
  }

  private static check(t: ProbeTarget): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      const start: number = Date.now();
      let req: http.HttpRequest | null = null;
      let timer: number = -1;
      let settled: boolean = false;
      let reason: string = '';
      let gotHeader: boolean = false;

      const finish = (ok: boolean, why: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
        }
        try {
          if (req !== null) {
            req.destroy();
          }
        } catch (e) {
          // 请求已结束时 destroy 会抛错，忽略
        }
        SourceProbe.cache.set(t.url, {
          url: t.url, name: t.name, ok: ok,
          ms: Date.now() - start, reason: why, ts: Date.now()
        });
        resolve();
      };

      try {
        req = http.createHttp();
        req.on('headersReceive', (header: Object) => {
          const code: number = Number((header as Record<string, Object>)['statusCode'] ?? 0);
          if (code <= 0) {
            return;
          }
          gotHeader = true;
          if (code >= 200 && code < 300) {
            finish(true, '');
          } else {
            finish(false, SourceProbe.statusReason(code));
          }
        });
        req.on('dataReceive', (data: ArrayBuffer) => {
          // 少数服务不发 headersReceive 事件，这里兜底：有数据就算通
          if (!gotHeader) {
            finish(true, '');
          }
        });
        timer = setTimeout(() => { finish(false, '连接超时'); }, SourceProbe.TIMEOUT_MS);
        req.request(t.url, {
          method: http.RequestMethod.GET,
          header: { 'User-Agent': SourceProbe.UA, 'Accept': '*/*' },
          connectTimeout: SourceProbe.TIMEOUT_MS,
          readTimeout: SourceProbe.TIMEOUT_MS,
          expectDataType: http.HttpDataType.STRING
        }).then((resp: http.HttpResponse) => {
          if (settled) {
            return;
          }
          const code: number = resp.responseCode;
          if (code >= 200 && code < 300) {
            finish(true, '');
          } else {
            finish(false, SourceProbe.statusReason(code));
          }
        }).catch((err: BusinessError) => {
          finish(false, SourceProbe.errorReason(err));
        });
      } catch (e) {
        finish(false, '无法发起请求');
      }
    });
  }

  private static statusReason(code: number): string {
    if (code === 401 || code === 403) {
      return '需要授权（' + code + '）';
    }
    if (code === 404 || code === 410) {
      return '地址失效（' + code + '）';
    }
    if (code >= 500) {
      return '服务器错误（' + code + '）';
    }
    return 'HTTP ' + code;
  }

  private static errorReason(err: BusinessError): string {
    const s: string = ((err && err.message) ?? '').toLowerCase();
    if (s.includes('timeout') || s.includes('timed out') || s.includes('超时')) {
      return '连接超时';
    }
    if (s.includes('dns') || s.includes('host') || s.includes('name resolution') || s.includes('主机')) {
      return '域名解析失败';
    }
    if (s.includes('certificate') || s.includes('ssl') || s.includes('tls')) {
      return '证书校验失败';
    }
    if (s.includes('refused') || s.includes('connect') || s.includes('network') || s.includes('连接')) {
      return '连不上服务器';
    }
    return '连接失败';
  }
}
