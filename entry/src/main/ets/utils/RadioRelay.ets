import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 排查用：hdc shell hilog | grep TVBOX_RADIO */
function rlLog(msg: string): void {
  hilog.info(0x0000, 'TVBOX_RADIO', '%{public}s', msg);
}

/**
 * 电台流本地转发（只给「直连播不了」的台用）。
 *
 * 为什么需要：
 *   播放器（hiStreamer）取 mp3 直播流时会带一个有界范围探测 `Range: bytes=0-8191`。
 *   多数服务器直接无视它，回 200 + 不定长，引擎就按直播流一直读；
 *   但 streamtheworld 这类 CDN 老实返回 `206 + Content-Length: 8192`，
 *   引擎把 8192 当成「整个文件的大小」，读完立刻 EOS——表现就是播 0.8 秒自己停。
 *
 * 做法：本机起一个只听 127.0.0.1 的小 HTTP 服务，把播放器的请求接下来，
 *   自己用纯 TCP 去上游取流（顺手跟掉 302，https 一律降成 http：这些 CDN 的 80 口同样给流），
 *   然后**一律回 200、不写 Content-Length、不看 Range**，把字节原样倒回去。
 *   引擎拿到的是「长度未知的直播流」，就不会再有 8KB 那个坑。
 */

/** 只认 loopback，端口挑一串不常用的，被占了就换下一个 */
const LOOPBACK: string = '127.0.0.1';
const PORTS: number[] = [18811, 18812, 18813, 18814];
/** 上游最多跟几次 302 */
const MAX_HOPS: number = 4;
const CONNECT_TIMEOUT: number = 8000;
/** 上游迟迟不给响应头就重来一次：CDN 每次 302 给的边缘节点不同，换一个常常就通了 */
const HEAD_TIMEOUT: number = 6000;
const MAX_RETRY: number = 2;

/** 上游地址拆出来的三段 */
interface UpAddr {
  host: string;
  port: number;
  path: string;
}

/** 一条转发链路：一个播放器连接对应一条上游连接 */
class RelayLink {
  up: socket.TCPSocket | null = null;
  /** 上游的响应头已经解析完、开始倒音频字节 */
  upReady: boolean = false;
  /** 上游响应头累积（8KB 以内，够用） */
  head: Uint8Array = new Uint8Array(0);
  /** 跟了几次跳转 */
  hops: number = 0;
  /** 上游 content-type，透传给播放器（aac 台靠它选解复用器） */
  ctype: string = 'audio/mpeg';
  /** 当前上游地址，仅用于日志 */
  at: string = '';
  /** 观众点的那条原始线路：上游不通时拿它重新跟一次 302，换个边缘节点 */
  orig: string = '';
  retries: number = 0;
  timer: number = -1;
  closed: boolean = false;
}

export class RadioRelay {
  private static port: number = 0;
  private static ready: Promise<number> | null = null;

  /**
   * 哪些台需要走转发。
   * 目前只认 streamtheworld（Triton）：其余 CDN 实测都无视 Range，直连没问题，
   * 多绕一层只会多一份不确定性。
   */
  static needs(url: string): boolean {
    const u: string = (url ?? '').toLowerCase();
    return u.indexOf('streamtheworld.com') >= 0;
  }

  /** 把一堆线路地址换成「需要的走本地转发」的新列表；服务起不来就原样返回 */
  static async mapAll(urls: string[]): Promise<string[]> {
    const out: string[] = [];
    for (const u of urls) {
      out.push(await RadioRelay.wrap(u));
    }
    return out;
  }

  private static async wrap(url: string): Promise<string> {
    if (!RadioRelay.needs(url)) {
      return url;
    }
    const p: number = await RadioRelay.ensure();
    if (p <= 0) {
      return url;
    }
    return 'http://' + LOOPBACK + ':' + p + '/s?u=' + encodeURIComponent(url);
  }

  private static async ensure(): Promise<number> {
    if (RadioRelay.port > 0) {
      return RadioRelay.port;
    }
    if (RadioRelay.ready === null) {
      RadioRelay.ready = RadioRelay.boot();
    }
    return RadioRelay.ready;
  }

  private static async boot(): Promise<number> {
    for (const p of PORTS) {
      try {
        const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
        srv.on('connect', (conn: socket.TCPSocketConnection) => {
          RadioRelay.serve(conn);
        });
        await srv.listen({ address: LOOPBACK, port: p, family: 1 });
        RadioRelay.port = p;
        rlLog('relay listen ' + LOOPBACK + ':' + p);
        return p;
      } catch (e) {
        // 端口被占或不允许监听，试下一个
      }
    }
    return 0;
  }

  // ---------------- 客户端一侧 ----------------

  private static serve(conn: socket.TCPSocketConnection): void {
    const link: RelayLink = new RelayLink();
    let acc: Uint8Array = new Uint8Array(0);
    conn.on('message', (info: socket.SocketMessageInfo) => {
      if (link.up !== null) {
        // 播放器发完 GET 之后不会再说话，多余数据直接丢
        return;
      }
      acc = RadioRelay.join(acc, new Uint8Array(info.message));
      const end: number = RadioRelay.headerEnd(acc);
      if (end < 0) {
        if (acc.length > 16384) {
          RadioRelay.shut(conn, link);
        }
        return;
      }
      const url: string = RadioRelay.urlOf(RadioRelay.text(acc, 0, end));
      if (url.length === 0) {
        RadioRelay.shut(conn, link);
        return;
      }
      link.orig = url;
      link.ctype = RadioRelay.typeOf(url);
      // 先回 200 再看上游：等上游等到 302 跟完，引擎那边可能已经判超时了。
      // 不带 Content-Length、不看 Range，引擎只会把它当「长度未知的直播流」一直读。
      conn.send({
        data: 'HTTP/1.0 200 OK\r\n'
          + 'Content-Type: ' + link.ctype + '\r\n'
          + 'Cache-Control: no-cache\r\n'
          + 'Connection: close\r\n\r\n'
      }).catch(() => {});
      RadioRelay.dial(conn, link, url);
    });
    conn.on('close', () => {
      link.closed = true;
      const u: socket.TCPSocket | null = link.up;
      link.up = null;
      if (u !== null) {
        u.close().catch(() => {});
      }
    });
  }

  // ---------------- 上游一侧 ----------------

  private static dial(conn: socket.TCPSocketConnection, link: RelayLink, url: string): void {
    const addr: UpAddr | null = RadioRelay.parse(url);
    if (addr === null) {
      RadioRelay.shut(conn, link);
      return;
    }
    link.at = addr.host + ':' + addr.port + addr.path;
    RadioRelay.clearTimer(link);
    link.timer = setTimeout(() => {
      link.timer = -1;
      if (!link.upReady && !link.closed) {
        rlLog('upstream silent, retry ' + (link.retries + 1));
        RadioRelay.retryUpstream(conn, link);
      }
    }, HEAD_TIMEOUT);
    const up: socket.TCPSocket = socket.constructTCPSocketInstance();
    link.up = up;
    link.upReady = false;
    link.head = new Uint8Array(0);
    // 只认「当前这一个」上游：跟 302 时旧 socket 也会冒 close，不认身份就会把刚建好的链路一起关掉
    up.on('message', (info: socket.SocketMessageInfo) => {
      if (link.up !== up) {
        return;
      }
      RadioRelay.fromUpstream(conn, link, info.message);
    });
    up.on('close', () => {
      if (link.up === up && !link.closed) {
        RadioRelay.retryUpstream(conn, link);
      }
    });
    up.connect({
      address: { address: addr.host, port: addr.port, family: 1 },
      timeout: CONNECT_TIMEOUT
    }).then(() => {
      const req: string = 'GET ' + addr.path + ' HTTP/1.0\r\n'
        + 'Host: ' + addr.host + '\r\n'
        + 'User-Agent: Mozilla/5.0\r\n'
        + 'Accept: */*\r\n'
        + 'Connection: close\r\n\r\n';
      // 故意不发 Range：上游按直播流从当前位置一直往下吐
      return up.send({ data: req });
    }).catch(() => {
      RadioRelay.retryUpstream(conn, link);
    });
  }

  private static fromUpstream(conn: socket.TCPSocketConnection, link: RelayLink,
    message: ArrayBuffer): void {
    const data: Uint8Array = new Uint8Array(message);
    if (link.upReady) {
      conn.send({ data: message }).catch(() => {});
      return;
    }
    link.head = RadioRelay.join(link.head, data);
    const end: number = RadioRelay.headerEnd(link.head);
    if (end < 0) {
      if (link.head.length > 16384) {
        RadioRelay.shut(conn, link);
      }
      return;
    }
    const head: string = RadioRelay.text(link.head, 0, end);
    const code: number = RadioRelay.statusOf(head);
    if (code >= 300 && code < 400) {
      const loc: string = RadioRelay.locationOf(head);
      const old: socket.TCPSocket | null = link.up;
      link.up = null;
      if (old !== null) {
        old.close().catch(() => {});
      }
      if (loc.length > 0 && link.hops < MAX_HOPS) {
        link.hops++;
        rlLog('3xx ' + code + ' -> ' + loc);
        RadioRelay.dial(conn, link, loc);
      } else {
        RadioRelay.retryUpstream(conn, link);
      }
      return;
    }
    if (code !== 200) {
      rlLog('upstream ' + code + ', retry');
      RadioRelay.retryUpstream(conn, link);
      return;
    }
    // 200 早就回给播放器了，这里只负责把响应头之后的音频字节倒下去
    link.upReady = true;
    RadioRelay.clearTimer(link);
    rlLog('relay stream after ' + link.hops + ' hop(s) from ' + link.at);
    const rest: Uint8Array = link.head.subarray(end);
    if (rest.length > 0) {
      conn.send({ data: RadioRelay.copy(rest).buffer }).catch(() => {});
    }
    link.head = new Uint8Array(0);
  }

  /** 上游这条不通：拿原始线路重来一次（新的 302 一般指向另一个边缘节点）；重试用尽才放弃 */
  private static retryUpstream(conn: socket.TCPSocketConnection, link: RelayLink): void {
    if (link.closed) {
      return;
    }
    const old: socket.TCPSocket | null = link.up;
    link.up = null;
    if (old !== null) {
      old.close().catch(() => {});
    }
    if (link.retries < MAX_RETRY && link.orig.length > 0) {
      link.retries++;
      link.hops = 0;
      RadioRelay.dial(conn, link, link.orig);
      return;
    }
    RadioRelay.shut(conn, link);
  }

  private static clearTimer(link: RelayLink): void {
    if (link.timer >= 0) {
      clearTimeout(link.timer);
      link.timer = -1;
    }
  }

  private static shut(conn: socket.TCPSocketConnection, link: RelayLink): void {
    link.closed = true;
    RadioRelay.clearTimer(link);
    const u: socket.TCPSocket | null = link.up;
    link.up = null;
    if (u !== null) {
      u.close().catch(() => {});
    }
    conn.close().catch(() => {});
  }

  // ---------------- 小工具 ----------------

  /** 拆 http://host[:port]/path；https 一律当 http 处理（这些 CDN 的 80 口同样给流） */
  private static parse(url: string): UpAddr | null {
    let t: string = (url ?? '').trim();
    let wasTls: boolean = false;
    if (t.startsWith('//')) {
      t = 'http:' + t;
    }
    if (t.toLowerCase().startsWith('https://')) {
      t = 'http://' + t.substring(8);
      wasTls = true;
    }
    if (!t.toLowerCase().startsWith('http://')) {
      return null;
    }
    const rest: string = t.substring(7);
    const slash: number = rest.indexOf('/');
    const hostPort: string = slash < 0 ? rest : rest.substring(0, slash);
    const path: string = slash < 0 ? '/' : rest.substring(slash);
    if (hostPort.length === 0) {
      return null;
    }
    let host: string = hostPort;
    let port: number = 80;
    const c: number = hostPort.lastIndexOf(':');
    if (c > 0) {
      const ps: string = hostPort.substring(c + 1);
      const n: number = Number.parseInt(ps, 10);
      if (!Number.isNaN(n) && n > 0 && n < 65536) {
        host = hostPort.substring(0, c);
        port = n;
      }
    }
    if (host.length === 0) {
      return null;
    }
    // 关键：https 的显式 :443 降到 http 后必须换成 80，否则拿明文去敲 TLS 端口，收到一堆非 HTTP 字节
    if (wasTls && port === 443) {
      port = 80;
    }
    return { host: host, port: port, path: path };
  }

  /** 找响应/请求头结束位置（\r\n\r\n 之后的下一个字节下标） */
  private static headerEnd(b: Uint8Array): number {
    for (let i = 3; i < b.length; i++) {
      if (b[i] === 10 && b[i - 1] === 13 && b[i - 2] === 10 && b[i - 3] === 13) {
        return i + 1;
      }
    }
    return -1;
  }

  private static text(b: Uint8Array, from: number, to: number): string {
    let s: string = '';
    const end: number = Math.min(to, b.length);
    for (let i = from; i < end; i++) {
      s += String.fromCharCode(b[i]);
    }
    return s;
  }

  /** 请求行里的 u= 参数 */
  private static urlOf(head: string): string {
    const m: RegExpMatchArray | null = head.match(/[?&]u=([^&\s]+)/);
    if (m === null || m.length < 2) {
      return '';
    }
    try {
      return decodeURIComponent(m[1]);
    } catch (e) {
      return '';
    }
  }

  /** 播放器靠 content-type 选解复用器，转发时得先把类型猜对：aac 台别报成 mp3 */
  private static typeOf(url: string): string {
    const u: string = (url ?? '').toLowerCase();
    return u.indexOf('aac') >= 0 ? 'audio/aac' : 'audio/mpeg';
  }

  private static statusOf(head: string): number {
    const first: string = head.split('\r\n')[0];
    const parts: string[] = first.split(' ');
    if (parts.length < 2) {
      return 0;
    }
    const n: number = Number.parseInt(parts[1], 10);
    return Number.isNaN(n) ? 0 : n;
  }

  private static headerValue(head: string, key: string): string {
    const lines: string[] = head.split('\r\n');
    const k: string = key.toLowerCase() + ':';
    for (const line of lines) {
      if (line.toLowerCase().startsWith(k)) {
        return line.substring(k.length).trim();
      }
    }
    return '';
  }

  private static locationOf(head: string): string {
    const v: string = RadioRelay.headerValue(head, 'location');
    if (v.length === 0) {
      return '';
    }
    if (v.startsWith('//')) {
      return 'http:' + v;
    }
    if (v.toLowerCase().startsWith('https://')) {
      return 'http://' + v.substring(8);
    }
    if (v.toLowerCase().startsWith('http://')) {
      return v;
    }
    // 相对跳转：这些 CDN 一般给绝对地址，真遇到相对的就按同主机拼
    return v.startsWith('/') ? v : ('/' + v);
  }

  private static join(a: Uint8Array, b: Uint8Array): Uint8Array {
    if (a.length === 0) {
      return b;
    }
    const out: Uint8Array = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  private static copy(b: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(b.length);
    out.set(b, 0);
    return out;
  }
}
