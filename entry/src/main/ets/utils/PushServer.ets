import { socket, connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';

/**
 * 局域网推送服务：电视自己开一个 HTTP 服务，手机扫码打开网页，把地址推上来。
 *
 * 为什么不需要后端：手机和电视在同一个 Wi-Fi 下可以直接互通，电视监听一个端口即可。
 * 代价是手机必须连同一网络，跨网（手机用 4G）就不行了 —— 想跨网得有自己的服务器。
 *
 * 协议就三条：
 *   GET  /?t=<token>    → 返回手机端输入页
 *   POST /push?t=<token> body=text=<urlencoded>  → 记下地址，回 {"ok":true}
 *   token 不对一律 403，防止同网段别的设备乱推
 */

const PORT_BASE: number = 8899;
const PORT_TRIES: number = 3;

export class PushServer {
  private server: socket.TCPSocketServer | null = null;
  private portNum: number = 0;
  private tokenStr: string = '';
  private pendingText: string = '';
  private localIp: string = '';
  private errStr: string = '';
  /** 推送用途：'addr' 普通地址 / 'cookie' 豆瓣 Cookie，只影响手机端页面的文案 */
  private kindStr: string = 'addr';
  /** 最近一次处理的痕迹，排查用；界面上会显示 */
  diag: string = '';
  hits: number = 0;

  isRunning(): boolean {
    return this.server !== null;
  }

  /** 二维码里要放的内容 */
  url(): string {
    if (this.localIp.length === 0 || this.portNum === 0) {
      return '';
    }
    return 'http://' + this.localIp + ':' + this.portNum + '/?t=' + this.tokenStr;
  }

  error(): string {
    return this.errStr;
  }

  /** 取走手机推上来的地址（取一次就清空） */
  take(): string {
    const v = this.pendingText;
    this.pendingText = '';
    return v;
  }

  async start(kind: string = 'addr'): Promise<void> {
    // 服务可能是复用的（上次推送没关），文案用途每次都要按当前这次刷新
    this.kindStr = kind;
    if (this.server !== null) {
      return;
    }
    this.errStr = '';
    this.pendingText = '';
    this.hits = 0;

    try {
      this.localIp = await this.pickIp();
    } catch (e) {
      this.localIp = '';
    }
    if (this.localIp.length === 0) {
      this.errStr = '没拿到电视的局域网地址，先确认电视 Wi-Fi 是连着的';
      return;
    }

    this.tokenStr = this.makeToken();

    for (let i = 0; i < PORT_TRIES; i++) {
      const want = PORT_BASE + i;
      try {
        const s = socket.constructTCPSocketServerInstance();
        const addr: socket.NetAddress = { address: '0.0.0.0', port: want, family: 1 };
        await s.listen(addr);
        // 系统在 bind 失败时会自己挑一个随机端口，所以以实际地址为准
        let real = want;
        try {
          const la = await s.getLocalAddress();
          const lp: number | undefined = la.port;
          if (lp !== undefined && lp > 0) {
            real = lp;
          }
        } catch (e) {
          real = want;
        }
        this.server = s;
        this.portNum = real;
        this.bind(s);
        return;
      } catch (e) {
        const err = e as BusinessError;
        this.errStr = '端口 ' + want + ' 监听失败（' + err.code + '）';
      }
    }
  }

  stop(): void {
    const s = this.server;
    this.server = null;
    this.portNum = 0;
    this.pendingText = '';
    if (s !== null) {
      try {
        s.off('connect');
      } catch (e) {
        this.errStr = this.errStr;
      }
      s.close().catch((e: BusinessError) => {
        this.errStr = this.errStr;
      });
    }
  }

  // ---------------- 内部 ----------------

  private async pickIp(): Promise<string> {
    // 注意：智慧屏上 getDefaultNet 系列一律 201，只能走 getAllNets 遍历
    const nets: connection.NetHandle[] = await connection.getAllNets();
    const cands: string[] = [];
    for (let i = 0; i < nets.length; i++) {
      const p = await connection.getConnectionProperties(nets[i]);
      for (let k = 0; k < p.linkAddresses.length; k++) {
        const la = p.linkAddresses[k];
        if (la.address.family === 1) {
          const a = la.address.address;
          if (a !== '127.0.0.1' && !a.startsWith('127.')) {
            cands.push(a);
          }
        }
      }
    }
    for (let i = 0; i < cands.length; i++) {
      if (cands[i].startsWith('192.168.')) {
        return cands[i];
      }
    }
    for (let i = 0; i < cands.length; i++) {
      if (cands[i].startsWith('10.')) {
        return cands[i];
      }
    }
    for (let i = 0; i < cands.length; i++) {
      if (cands[i].startsWith('172.')) {
        return cands[i];
      }
    }
    return cands.length > 0 ? cands[0] : '';
  }

  private makeToken(): string {
    const hex = '0123456789abcdef';
    let t = '';
    for (let i = 0; i < 12; i++) {
      t += hex.charAt(Math.floor(Math.random() * 16));
    }
    return t;
  }

  private bind(s: socket.TCPSocketServer): void {
    s.on('connect', (conn: socket.TCPSocketConnection) => {
      let buf: string = '';
      let done: boolean = false;
      conn.on('message', (info: socket.SocketMessageInfo) => {
        try {
          if (done) {
            return;
          }
          const chunk = this.decode(info.message);
          if (chunk === undefined || chunk.length === 0) {
            // 连接刚建立时会先来一个空包，正常现象，等真正的请求
            return;
          }
          buf += chunk;
          const sep = buf.indexOf('\r\n\r\n');
          if (sep < 0) {
            return;
          }
          const head = buf.substring(0, sep);
          const rest = buf.substring(sep + 4);
          const need = this.contentLength(head);
          if (rest.length < need) {
            return; // body 还没收全，等下一包
          }
          done = true;
          const body = need > 0 ? rest.substring(0, need) : '';
          this.route(conn, head, body);
        } catch (e) {
          const err = e as BusinessError;
          this.diag = '收包异常：' + err.message;
          this.safeClose(conn);
        }
      });
    });
    s.on('error', (e: BusinessError) => {
      this.diag = 'socket 错误：' + e.code + ' ' + e.message;
    });
  }

  private safeClose(conn: socket.TCPSocketConnection): void {
    try {
      conn.close().catch((e: BusinessError) => {
        this.diag = this.diag;
      });
    } catch (e) {
      this.diag = this.diag;
    }
  }

  private route(conn: socket.TCPSocketConnection, head: string, body: string): void {
    try {
      const firstLine = head.split('\r\n')[0];
      const parts = firstLine.split(' ');
      const method = parts.length > 0 ? parts[0] : 'GET';
      const path = parts.length > 1 ? parts[1] : '/';
      if (this.diag.length > 0) {
        this.diag = '';
      }

      if (this.tokenOf(path) !== this.tokenStr) {
        this.send(conn, '403 Forbidden', 'text/plain; charset=utf-8', 'bad token');
        return;
      }

      if (method === 'POST') {
        const v = this.formValue(body, 'text');
        if (v.length === 0) {
          this.send(conn, '200 OK', 'application/json; charset=utf-8', '{"ok":false,"msg":"empty"}');
          return;
        }
        this.pendingText = v;
        this.hits++;
        this.send(conn, '200 OK', 'application/json; charset=utf-8', '{"ok":true}');
        return;
      }

      this.send(conn, '200 OK', 'text/html; charset=utf-8', this.page());
    } catch (e) {
      const err = e as BusinessError;
      this.diag = '路由异常：' + err.message;
      this.safeClose(conn);
    }
  }

  private tokenOf(path: string): string {
    const i = path.indexOf('t=');
    if (i < 0) {
      return '';
    }
    let v = path.substring(i + 2);
    const amp = v.indexOf('&');
    if (amp >= 0) {
      v = v.substring(0, amp);
    }
    return v;
  }

  private contentLength(head: string): number {
    const lines = head.split('\r\n');
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().startsWith('content-length:')) {
        const v = parseInt(lines[i].substring(15).trim(), 10);
        return isNaN(v) ? 0 : v;
      }
    }
    return 0;
  }

  private formValue(body: string, key: string): string {
    const prefix = key + '=';
    const segs = body.split('&');
    for (let i = 0; i < segs.length; i++) {
      if (segs[i].startsWith(prefix)) {
        return this.urlDecode(segs[i].substring(prefix.length));
      }
    }
    return '';
  }

  private urlDecode(s: string): string {
    const bytes: number[] = [];
    let i = 0;
    while (i < s.length) {
      const c = s.charCodeAt(i);
      if (c === 0x25 && i + 2 < s.length) {
        const v = parseInt(s.substring(i + 1, i + 3), 16);
        if (!isNaN(v)) {
          bytes.push(v);
          i += 3;
          continue;
        }
      }
      bytes.push(c === 0x2B ? 0x20 : c);
      i++;
    }
    const arr = new Uint8Array(bytes.length);
    for (let k = 0; k < bytes.length; k++) {
      arr[k] = bytes[k];
    }
    try {
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(arr);
    } catch (e) {
      return '';
    }
  }

  private decode(buf: ArrayBuffer | undefined): string {
    try {
      if (buf === undefined || buf === null) {
        return '';
      }
      const decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buf));
    } catch (e) {
      return '';
    }
  }

  private send(conn: socket.TCPSocketConnection, status: string,
    ctype: string, body: string): void {
    try {
      const bytes = new util.TextEncoder().encodeInto(body);
      const head = 'HTTP/1.1 ' + status + '\r\n'
        + 'Content-Type: ' + ctype + '\r\n'
        + 'Content-Length: ' + bytes.length + '\r\n'
        + 'Cache-Control: no-store\r\n'
        + 'Connection: close\r\n\r\n';
      conn.send({ data: head + body })
        .then(() => {
          this.safeClose(conn);
        })
        .catch((e: BusinessError) => {
          this.diag = '回包失败：' + e.code + ' ' + e.message;
          this.safeClose(conn);
        });
    } catch (e) {
      const err = e as BusinessError;
      this.diag = '发送异常：' + err.message;
      this.safeClose(conn);
    }
  }

  /** 手机端页面。样式尽量素，电视上看着小、手机上看着舒服就行 */
  private page(): string {
    const cookie: boolean = this.kindStr === 'cookie';
    let h = '<!doctype html><html lang=zh><head><meta charset=utf-8>';
    h += '<meta name=viewport content="width=device-width,initial-scale=1,viewport-fit=cover">';
    h += '<title>推送到电视</title><style>';
    h += '*{box-sizing:border-box}';
    h += 'body{margin:0;padding:22px 18px;font:16px/1.55 -apple-system,system-ui,sans-serif;';
    h += 'background:#141414;color:#eee}';
    h += 'h1{font-size:19px;margin:0 0 6px}';
    h += '.tip{font-size:14px;color:#999;margin:0 0 16px}';
    h += 'textarea{width:100%;height:112px;padding:12px;font-size:15px;line-height:1.4;';
    h += 'border-radius:10px;border:1px solid #333;background:#1e1e1e;color:#fff;resize:vertical}';
    h += 'button{width:100%;margin-top:14px;padding:15px;border:0;border-radius:10px;';
    h += 'background:#FF6B00;color:#fff;font-size:17px;font-weight:600}';
    h += 'button:disabled{opacity:.55}';
    h += '#s{margin-top:14px;font-size:15px;min-height:22px;color:#999}';
    h += '</style></head><body>';
    h += '<h1>' + (cookie ? '推送豆瓣 Cookie' : '推送到电视') + '</h1>';
    h += cookie
      ? '<p class=tip>在电脑或手机浏览器登录豆瓣 → 开发者工具 Network → 随便点一个请求 → '
        + '复制它的 Cookie 请求头，粘到下面。</p>'
      : '<p class=tip>粘贴你复制的接口地址，点下面按钮，电视上会自动填进输入框。</p>';
    h += cookie
      ? '<textarea id=t placeholder=\'bid=abc123; dbcl2="1234567:xxxx"\'></textarea>'
      : '<textarea id=t placeholder="https://example.com/config.json"></textarea>';
    h += '<button id=b>' + (cookie ? '推送 Cookie' : '推送到电视') + '</button><p id=s></p>';
    h += '<script>';
    h += 'var TK="' + this.tokenStr + '";';
    h += 'var ta=document.getElementById("t"),b=document.getElementById("b"),s=document.getElementById("s");';
    h += 'function say(msg,ok){s.textContent=msg;s.style.color=ok?"#7fd88a":"#ff8a8a";}';
    h += 'b.onclick=function(){';
    h += 'var v=ta.value.trim();';
    h += 'if(!v){say("内容还是空的",0);return;}';
    h += 'b.disabled=true;b.textContent="推送中…";';
    h += 'fetch("/push?t="+TK,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},';
    h += 'body:"text="+encodeURIComponent(v)})';
    h += '.then(function(r){return r.json()})';
    h += '.then(function(j){';
    h += 'if(j.ok){say("已送到电视，' + (cookie ? '回去点「保存并验证」' : '回去点「载入」生效') + '",1);ta.value="";}';
    h += 'else{say("电视没收到："+(j.msg||"未知原因"),0);}';
    h += 'b.disabled=false;b.textContent="推送到电视";})';
    h += '.catch(function(){say("连不上电视，确认手机和电视连的是同一个 Wi-Fi",0);';
    h += 'b.disabled=false;b.textContent="推送到电视";});};';
    h += '</script></body></html>';
    return h;
  }
}

/** 全局单例：设置页开、播放页不用管 */
export const pushServer = new PushServer();
