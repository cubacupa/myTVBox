import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 线路体检：判断一条线路此刻是不是活的。
 *
 * 跟 LiveSrcProbe 不是一回事——那个探的是「整份直播源能不能解析出频道」，
 * 这里探的是「这一条具体 URL 能不能拉到 m3u8」。一个频道合并后常有好几条线路，
 * 第一条失效时预览就会停在「信号中断」，但后面几条其实是好的。
 *
 * 探测很轻：只流式读前面 4KB，看到 #EXTM3U 就立刻断开。直播流不会自己结束，
 * 整条拉下去是几百 MB；短读 + 主动 destroy 才不会把电视带宽吃掉。
 *
 * 结果只在内存里缓存：成功 30 分钟、失败 5 分钟。失败 TTL 短一些，让上游抖动
 * 恢复后能尽快重新入选；成功 TTL 长一些，避免每次聚焦都重新探一遍。重启 App 清空。
 *
 * 全失败不等于线路就废了——网关可能校验 UA / Referer，HTTP 层拿到 403 但播放器
 * 反而能播。所以这里只做「优先选谁」，不设黑名单：没有任何线路通过时，调用方
 * 仍照原样用第一条，不让探活把频道弄成没法看。
 */
export class LiveLineProbe {
  private static readonly OK_TTL: number = 30 * 60 * 1000;
  private static readonly BAD_TTL: number = 5 * 60 * 1000;
  private static readonly MAX_BYTES: number = 4096;
  private static readonly TIMEOUT_MS: number = 3500;
  private static readonly UA: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /** url → { ok: 是否通过, ts: 探活时间 } */
  private static cache: Map<string, LineProbeEntry> = new Map();
  /** 正在探的 url，避免同一条被并发重复请求 */
  private static inflight: Map<string, Promise<boolean>> = new Map();

  /**
   * 同步查缓存。返回 undefined 表示还没探过（调用方应先用原逻辑，别干等）。
   */
  static alive(url: string): boolean | undefined {
    const e: LineProbeEntry | undefined = LiveLineProbe.cache.get(url);
    if (e === undefined) {
      return undefined;
    }
    const ttl: number = e.ok ? LiveLineProbe.OK_TTL : LiveLineProbe.BAD_TTL;
    if (Date.now() - e.ts > ttl) {
      LiveLineProbe.cache.delete(url);
      return undefined;
    }
    return e.ok;
  }

  /** 缓存里有通过的线路吗——按给定顺序返回第一条，没有就返回空串 */
  static firstAlive(urls: string[]): string {
    for (const u of urls) {
      if (LiveLineProbe.alive(u) === true) {
        return u;
      }
    }
    return '';
  }

  /**
   * 批量探活。带缓存与并发去重：探过的（在 TTL 内）直接跳过，正在探的复用同一个 Promise。
   */
  static async probe(urls: string[]): Promise<void> {
    const jobs: Promise<boolean>[] = [];
    for (const u of urls) {
      if (!u.startsWith('http')) {
        continue;
      }
      if (LiveLineProbe.alive(u) !== undefined) {
        continue;
      }
      let job: Promise<boolean> | undefined = LiveLineProbe.inflight.get(u);
      if (job === undefined) {
        job = LiveLineProbe.check(u);
        LiveLineProbe.inflight.set(u, job);
      }
      jobs.push(job);
    }
    if (jobs.length === 0) {
      return;
    }
    await Promise.all(jobs);
  }

  /** 用户手动重试时清掉失败缓存，让刚恢复的线路重新有机会 */
  static clearBad(): void {
    const dead: string[] = [];
    for (const u of LiveLineProbe.cache.keys()) {
      const e: LineProbeEntry | undefined = LiveLineProbe.cache.get(u);
      if (e !== undefined && !e.ok) {
        dead.push(u);
      }
    }
    for (const u of dead) {
      LiveLineProbe.cache.delete(u);
    }
  }

  private static check(url: string): Promise<boolean> {
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      let req: http.HttpRequest | null = null;
      let timer: number = -1;
      let settled: boolean = false;
      let badStatus: boolean = false;
      let text: string = '';
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

      const finish = (ok: boolean): void => {
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
          // destroy 在请求已结束时可能抛错，忽略
        }
        LiveLineProbe.cache.set(url, { ok: ok, ts: Date.now() });
        LiveLineProbe.inflight.delete(url);
        resolve(ok);
      };

      try {
        req = http.createHttp();
        req.on('headersReceive', (header: Object) => {
          // HTTP 模块跟随重定向后，这里拿到的是最终响应的状态码
          const code: number = Number((header as Record<string, Object>)['statusCode'] ?? 0);
          if (code > 0 && (code < 200 || code >= 300)) {
            badStatus = true;
            finish(false);
          }
        });
        req.on('dataReceive', (data: ArrayBuffer) => {
          if (settled) {
            return;
          }
          try {
            text += decoder.decodeWithStream(new Uint8Array(data), { stream: true });
          } catch (e) {
            // 解码失败按没证据处理，继续等超时
          }
          if (/^\s*#EXTM3U/im.test(text) || text.length >= LiveLineProbe.MAX_BYTES) {
            finish(!badStatus && /^\s*#EXTM3U/im.test(text));
          }
        });

        timer = setTimeout(() => { finish(false); }, LiveLineProbe.TIMEOUT_MS);
        req.request(url, {
          method: http.RequestMethod.GET,
          header: { 'User-Agent': LiveLineProbe.UA, 'Accept': '*/*' },
          connectTimeout: LiveLineProbe.TIMEOUT_MS,
          readTimeout: LiveLineProbe.TIMEOUT_MS,
          expectDataType: http.HttpDataType.STRING
        }).then((resp: http.HttpResponse) => {
          if (settled) {
            return;
          }
          // 索引很小会自己结束，走这里；正常结束同样要看到 #EXTM3U 才算数
          const body: string = typeof resp.result === 'string' ? resp.result : '';
          finish(resp.responseCode >= 200 && resp.responseCode < 300 &&
            /^\s*#EXTM3U/im.test(body));
        }).catch((err: BusinessError) => {
          finish(false);
        });
      } catch (e) {
        finish(false);
      }
    });
  }
}

interface LineProbeEntry {
  ok: boolean;
  ts: number;
}
