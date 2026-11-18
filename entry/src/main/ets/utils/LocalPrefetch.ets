import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 直链 mp4 的本地预取。
 *
 * 起因：天翼云这类签名直链的 CDN 对**同一个签名地址的请求次数**有硬限制
 * （实测 60 秒窗口内十几次，超出就 403，等一分钟才恢复；但一次请求要 45MB 完全正常，
 * 均速 3.4MB/s）。AVPlayer 是按小块 Range 边播边取的，一分钟能发十几二十次，
 * 播到一两分钟必然撞上限流 → 拿不到数据 → 每帧报 stream is unsupported → 5411006。
 *
 * 所以直链不走播放器自己的取流：App 用少数几次大块请求把整集拉到本地，
 * 播放器只读本地文件。130MB 的片子 6 次请求就下完，离限流阈值很远，
 * 而且本地文件拖动进度条是秒响应。
 *
 * 起播不等整集：首块下完（约 30MB，够播一分半）就交给播放器，剩下的后台继续。
 */

const DOMAIN: number = 0x0000;
const TAG: string = 'TVBoxPrefetch';

/** 首块：下完这块就起播 */
const BOOT_BYTES: number = 30 * 1024 * 1024;
/** 首块分几趟拉：每趟一个请求，进度条才有变化（请求数多一个也远不到限流阈值） */
const BOOT_STEP: number = 10 * 1024 * 1024;
/** 后续每块：块越大请求次数越少，越不容易撞 CDN 的请求次数限制 */
const CHUNK_BYTES: number = 24 * 1024 * 1024;
/** 缓存目录最多留几个文件 */
const KEEP_FILES: number = 2;
/** 单块失败后的重试次数（CDN 限流时等窗口过去再要） */
const CHUNK_RETRY: number = 4;

class PrefetchTask {
  url: string = '';
  path: string = '';
  /** 文件总字节数，0 表示还没问出来 */
  total: number = 0;
  /** 从 0 开始连续下载到的位置；播放器 seek 到它之前的位置都不用等 */
  done: number = 0;
  cancelled: boolean = false;
  fd: number = -1;
  failed: boolean = false;
}

export class LocalPrefetch {
  private static task: PrefetchTask | null = null;

  /** 这条地址能不能预取：http(s) 且不是分片/流式容器 */
  static canPrefetch(url: string): boolean {
    if (url.length === 0) {
      return false;
    }
    const lower: string = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    // 只看路径部分：query 里常带 .mp4 之类的参数名，别被它带跑；
    // 也兼容上游把 ? 写成 & 的脏地址（.m3u8&t=hls）
    let cut: number = lower.length;
    const cutQ: number = lower.indexOf('?');
    const cutA: number = lower.indexOf('&');
    if (cutQ >= 0 && cutQ < cut) {
      cut = cutQ;
    }
    if (cutA >= 0 && cutA < cut) {
      cut = cutA;
    }
    const base: string = lower.substring(0, cut);
    // 分片流由播放器自己按需取，不归这里管
    if (base.endsWith('.m3u8') || base.endsWith('.m3u') || base.endsWith('.flv')
      || base.endsWith('.ts') || base.endsWith('.mpd')) {
      return false;
    }
    return true;
  }

  /** 首块下载完成、可以起播时返回本地路径；失败抛异常，调用方回落到网络直连 */
  static async begin(context: common.Context, url: string,
    onBoot: (done: number, total: number) => void): Promise<string> {
    LocalPrefetch.cancel();
    const t: PrefetchTask = new PrefetchTask();
    t.url = url;
    LocalPrefetch.task = t;

    const dir: string = context.filesDir + '/prefetch';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'mkdir failed: %{public}s', (e as Error).message);
    }
    t.path = dir + '/' + LocalPrefetch.hashOf(url) + '.mp4';
    // 同一集看过一遍就直读，不再发请求
    if (LocalPrefetch.isComplete(t.path)) {
      const size: number = fs.statSync(t.path).size;
      t.total = size;
      t.done = size;
      hilog.info(DOMAIN, TAG, 'cache hit, %{public}d bytes', size);
      onBoot(size, size);
      return t.path;
    }

    // 不再单独探测：直接拉第一块，总长度从它的 Content-Range 里读。
    // HEAD 在这条链路上被拒（403），maxRedirects: 0 又会直接抛「重定向次数超限」，
    // 两条路都不通，只有带 Range 的 GET 是稳的。

    // fd 要先开好：首块在 pull 里就直接写盘，不留一份 30MB 的内存副本
    t.fd = fs.openSync(t.path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC).fd;

    const head: number = await LocalPrefetch.pull(t, 0, BOOT_STEP);
    if (t.cancelled) {
      LocalPrefetch.closeFd(t);
      throw new Error('cancelled');
    }
    if (head <= 0) {
      LocalPrefetch.closeFd(t);
      LocalPrefetch.task = null;
      throw new Error('range not supported');
    }
    // 有些地址从字符串上看不出是 HLS（后缀被站点改写、或者 302 到一个清单）：
    // 首块落地后验一眼头 4 字节，是 #EXT 文本清单就立刻放弃，把地址交回播放器。
    // 否则会拿一个几 KB 的清单当视频，还白等几十秒重试。
    if (LocalPrefetch.isPlaylist(t)) {
      LocalPrefetch.closeFd(t);
      LocalPrefetch.dropFile(t.path);
      LocalPrefetch.task = null;
      throw new Error('hls playlist, not a video file');
    }
    if (t.total <= 0) {
      // 服务器没给 Content-Range：这一块就是全部，或者根本不知道有多长
      t.total = head;
    }
    if (t.total > head) {
      // 按总长度把文件撑到位，播放器 stat 到的就是完整大小；
      // 未下载区域是全零，正常顺序播放永远到不了那里（下载比播放快得多）
      fs.writeSync(t.fd, new ArrayBuffer(1), { offset: t.total - 1 });
    }

    // 首块剩下的部分分趟拉，进度条才有东西可显示
    let first: number = head;
    const bootCap: number = Math.min(BOOT_BYTES, t.total);
    while (first < bootCap && !t.cancelled) {
      const want: number = Math.min(BOOT_STEP, bootCap - first);
      const got: number = await LocalPrefetch.pull(t, first, want);
      if (got <= 0) {
        break;
      }
      first += got;
      onBoot(first, t.total);
    }
    if (t.cancelled) {
      LocalPrefetch.closeFd(t);
      throw new Error('cancelled');
    }
    if (first <= 0) {
      LocalPrefetch.closeFd(t);
      throw new Error('first chunk failed');
    }
    t.done = first;
    if (t.done >= t.total) {
      // 整部就在首块里，直接当完成处理
      LocalPrefetch.markDone(t);
      LocalPrefetch.closeFd(t);
      return t.path;
    }
    onBoot(t.done, t.total);
    // 剩下的后台接着拉，不挡起播
    LocalPrefetch.rest(t).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'background fill stopped: %{public}s', e.message);
    });
    return t.path;
  }

  /** 已下载到的字节位置（seek 判断用） */
  static readyByte(): number {
    return LocalPrefetch.task === null ? 0 : LocalPrefetch.task.done;
  }

  static totalByte(): number {
    return LocalPrefetch.task === null ? 0 : LocalPrefetch.task.total;
  }

  static isActive(): boolean {
    return LocalPrefetch.task !== null && !LocalPrefetch.task.cancelled;
  }

  /**
   * 等到 pos 之前的字节都落地。播放器要跳到还没下载的位置时先等一会儿，
   * 否则读到全零区域会直接报解码错误。
   */
  static async waitByte(pos: number, timeoutMs: number): Promise<boolean> {
    const t: PrefetchTask | null = LocalPrefetch.task;
    if (t === null) {
      return true;
    }
    const t0: number = Date.now();
    while (t.done < pos && !t.cancelled && !t.failed && Date.now() - t0 < timeoutMs) {
      await new Promise<void>((r: () => void) => {
        setTimeout(r, 120);
      });
    }
    return t.done >= pos || t.cancelled;
  }

  static cancel(): void {
    const t: PrefetchTask | null = LocalPrefetch.task;
    if (t !== null) {
      t.cancelled = true;
      LocalPrefetch.closeFd(t);
    }
    LocalPrefetch.task = null;
  }

  // ---------------- 内部 ----------------

  private static closeFd(t: PrefetchTask): void {
    if (t.fd >= 0) {
      try {
        fs.closeSync(t.fd);
      } catch (e) {
        // 已关闭
      }
      t.fd = -1;
    }
  }

  /** 顺序把剩余部分拉完 */
  private static async rest(t: PrefetchTask): Promise<void> {
    let guard: number = 0;
    while (!t.cancelled && t.done < t.total && guard < 400) {
      guard++;
      const want: number = Math.min(CHUNK_BYTES, t.total - t.done);
      const got: number = await LocalPrefetch.pull(t, t.done, want);
      if (t.cancelled) {
        break;
      }
      if (got <= 0) {
        t.failed = true;
        throw new Error('chunk stalled at ' + t.done);
      }
      t.done += got;
      hilog.info(DOMAIN, TAG, 'filled %{public}d / %{public}d', t.done, t.total);
    }
    LocalPrefetch.closeFd(t);
    if (t.done >= t.total) {
      hilog.info(DOMAIN, TAG, 'prefetch complete');
      LocalPrefetch.markDone(t);
      LocalPrefetch.prune(t.path, KEEP_FILES);
    }
  }

  /** 头 4 字节是不是 "#EXT"：是就说明拉回来的是 HLS 文本清单，不是视频 */
  private static isPlaylist(t: PrefetchTask): boolean {
    if (t.fd < 0) {
      return false;
    }
    try {
      const b: ArrayBuffer = new ArrayBuffer(8);
      const n: number = fs.readSync(t.fd, b, { offset: 0, length: 8 });
      if (n < 4) {
        return false;
      }
      const v: Uint8Array = new Uint8Array(b);
      return v[0] === 0x23 && v[1] === 0x45 && v[2] === 0x58 && v[3] === 0x54;
    } catch (e) {
      return false;
    }
  }

  /** 作废的缓存文件要删掉，否则下次还会被当成半成品接着下 */
  private static dropFile(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'drop failed: %{public}s', (e as Error).message);
    }
  }

  /** 收尾标记：下次同一集直接读本地，不再发请求 */
  private static markDone(t: PrefetchTask): void {
    try {
      const ok: fs.File = fs.openSync(t.path + '.ok',
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.closeSync(ok);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'touch ok failed: %{public}s', (e as Error).message);
    }
  }

  /**
   * 取一段并写盘，返回实际拿到的字节数。
   */
  private static async pull(t: PrefetchTask, start: number, want: number): Promise<number> {
    let lastErr: string = '';
    for (let attempt = 0; attempt <= CHUNK_RETRY; attempt++) {
      if (t.cancelled) {
        return 0;
      }
      if (attempt > 0) {
        // CDN 限流是按时间窗口放开的，退避比立刻重试有用
        const wait: number = 3000 * attempt;
        hilog.warn(DOMAIN, TAG, 'retry %{public}d after %{public}dms (%{public}s)',
          attempt, wait, lastErr);
        await new Promise<void>((r: () => void) => {
          setTimeout(r, wait);
        });
        if (t.cancelled) {
          return 0;
        }
      }
      const req: http.HttpRequest = http.createHttp();
      try {
        const end: number = start + want - 1;
        const opt: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: { 'Range': 'bytes=' + start + '-' + end } as Record<string, string>,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false,
          connectTimeout: 20000,
          readTimeout: 150000
        };
        const resp: http.HttpResponse = await req.request(t.url, opt);
        if (resp.responseCode !== 206 && resp.responseCode !== 200) {
          lastErr = 'HTTP ' + resp.responseCode;
          // 地址本身就不存在（404/410）：重试再多次也一样，早点交回播放器，
          // 别让用户对着棋盘格等一分半。403 是限流，必须重试。
          if (resp.responseCode === 404 || resp.responseCode === 410) {
            break;
          }
          continue;
        }
        const buf: ArrayBuffer = resp.result as ArrayBuffer;
        if (buf === undefined || buf === null || buf.byteLength === 0) {
          lastErr = 'empty body';
          continue;
        }
        if (resp.responseCode === 200 && start > 0) {
          // 服务器把 Range 忽略了，回来的可能是整个文件，不能按偏移写
          lastErr = 'range ignored at ' + start;
          continue;
        }
        if (t.total <= 0) {
          // 总长度只信 Content-Range（206 时的 Content-Length 是这一块的，不是全长）
          const cr: string = LocalPrefetch.headerOf(resp, 'content-range');
          let got: number = 0;
          if (cr.length > 0) {
            const slash: number = cr.lastIndexOf('/');
            if (slash > 0) {
              got = parseInt(cr.substring(slash + 1), 10);
            }
          } else if (resp.responseCode === 200) {
            got = parseInt(LocalPrefetch.headerOf(resp, 'content-length'), 10);
          }
          if (!isNaN(got) && got > 0) {
            t.total = got;
          }
        }
        if (t.fd >= 0) {
          const room: number = t.total > 0 ? t.total - start : buf.byteLength;
          const use: number = Math.min(buf.byteLength, room);
          fs.writeSync(t.fd, buf, { offset: start, length: use });
          return use;
        }
        return buf.byteLength;
      } catch (e) {
        lastErr = (e as Error).message;
      } finally {
        req.destroy();
      }
    }
    hilog.error(DOMAIN, TAG, 'pull failed at %{public}d: %{public}s', start, lastErr);
    return 0;
  }

  /** 总长度：Content-Range 的 /total 优先，其次 Content-Length 与 URL 里的 x-amz-FSIZE */
  private static totalOf(resp: http.HttpResponse, url: string): number {
    const cr: string = LocalPrefetch.headerOf(resp, 'content-range');
    if (cr.length > 0) {
      const slash: number = cr.lastIndexOf('/');
      if (slash > 0) {
        const n: number = parseInt(cr.substring(slash + 1), 10);
        if (!isNaN(n) && n > 0) {
          return n;
        }
      }
    }
    const cl: number = parseInt(LocalPrefetch.headerOf(resp, 'content-length'), 10);
    if (!isNaN(cl) && cl > 0) {
      return cl;
    }
    const m: string[] = url.split('x-amz-FSIZE=');
    if (m.length > 1) {
      const n: number = parseInt(m[1].split('&')[0], 10);
      if (!isNaN(n) && n > 0) {
        return n;
      }
    }
    return 0;
  }

  /** 头字段大小写不统一，统一小写比较 */
  private static headerOf(resp: http.HttpResponse, name: string): string {
    const h: Record<string, string> = resp.header as Record<string, string>;
    if (h === undefined || h === null) {
      return '';
    }
    const keys: string[] = Object.keys(h);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() === name) {
        return h[keys[i]];
      }
    }
    return '';
  }

  /** 上次已经下完整了就直接播本地 */
  private static isComplete(path: string): boolean {
    try {
      if (!fs.accessSync(path)) {
        return false;
      }
      const st: fs.Stat = fs.statSync(path);
      if (st.size <= 0) {
        return false;
      }
      // 收尾标记：下完时写一个 .ok 文件，避免把下了一半的当成完整的
      return fs.accessSync(path + '.ok');
    } catch (e) {
      return false;
    }
  }

  /** 只留最近 KEEP_FILES 个缓存文件 */
  private static prune(keepPath: string, keep: number): void {
    try {
      const dir: string = keepPath.substring(0, keepPath.lastIndexOf('/'));
      const names: string[] = fs.listFileSync(dir);
      const files: string[] = [];
      for (let i = 0; i < names.length; i++) {
        if (names[i].endsWith('.mp4')) {
          files.push(names[i]);
        }
      }
      if (files.length <= keep) {
        return;
      }
      const pathOf: (n: string) => string = (n: string) => dir + '/' + n;
      files.sort((a: string, b: string) => {
        const ta: number = fs.statSync(pathOf(a)).mtime;
        const tb: number = fs.statSync(pathOf(b)).mtime;
        return ta - tb;
      });
      const drop: number = files.length - keep;
      for (let i = 0; i < drop; i++) {
        const p: string = pathOf(files[i]);
        if (p === keepPath) {
          continue;
        }
        fs.unlinkSync(p);
        if (fs.accessSync(p + '.ok')) {
          fs.unlinkSync(p + '.ok');
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'prune failed: %{public}s', (e as Error).message);
    }
  }

  /** 文件名用地址的短哈希：签名地址老变，但同一集内容相同，按地址区分够用 */
  private static hashOf(s: string): string {
    let h: number = 5381;
    for (let i = 0; i < s.length; i++) {
      h = (h * 33 + s.charCodeAt(i)) | 0;
    }
    const a: number = h >>> 0;
    return 'v' + a.toString(16);
  }
}
