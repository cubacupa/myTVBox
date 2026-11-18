import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 网页模式规则排查用：hdc shell hilog | grep TVBOX_WEB */
function logWeb(msg: string): void {
  hilog.info(0x0000, 'TVBOX_WEB', '%{public}s', msg);
}

/**
 * 无头嗅探：把播放页真跑一遍，从页面运行时里把流地址捞出来。
 *
 * 为什么需要：很多站的播放页只给一个空壳 HTML，真实地址是页面里的混淆 JS
 * 跑完才请求的（有的还先请求一个没有扩展名的接口，再返回 #EXTM3U）。
 * 纯 HTTP 抓页面 + 正则匹配只能捞到写死在 HTML 里的那种，够不着这一类。
 *
 * 实现（照搬 Kazumi 鸿蒙分支的三段钩子）：
 *   1) 劫持 XMLHttpRequest.open，记下请求地址；
 *   2) 劫持 fetch，同样记；
 *   3) 包一层 Response.prototype.text，响应体以 #EXTM3U 开头就认定这次请求的
 *      URL 是播放列表（地址没有 .m3u8 后缀也能认出来）；
 *   4) MutationObserver + 定时扫 <video>/<source>/<iframe>，顺手把媒体静音，
 *      免得后台嗅探时电视突然出声。
 *
 * 宿主：ArkWeb 没有真正的 headless 模式，必须在页面上挂一个 Web 组件（1×1、
 * 全透明、不吃点击），本模块只管操作它的 controller，不负责创建。
 * 目前挂在播放页（Player.ets），因为解决播放地址这一步只在那里发生。
 */

/** 必须在文档开始前注入，否则页面自己的脚本先跑，钩子就晚了 */
export const SNIFF_SCRIPT: string =
  '(function(){' +
  'if(window.__kzOn){window.__kzUrls=window.__kzUrls||[];window.__kzExt=window.__kzExt||[];return;}' +
  'window.__kzOn=1;window.__kzUrls=[];window.__kzExt=[];window.__kzRef=window.__kzRef||{};' +
  'try{window.addEventListener("message",function(e){var d=e&&e.data;if(!d||!d.__kz)return;' +
  'var s=String(d.__kz);if(s){if(d.ref)window.__kzRef[s]=String(d.ref);' +
  'if(window.__kzExt.indexOf(s)<0)window.__kzExt.push(s);}},false);}catch(e){}' +
  'function abs(u){try{if(!u)return "";var s=String(u).trim();if(!s)return "";' +
  'if(s.indexOf("blob:")===0||s.indexOf("data:")===0)return "";' +
  'if(s.indexOf("//")===0)s=location.protocol+s;' +
  'if(s.charAt(0)==="/")s=location.origin+s;return s;}catch(e){return "";}}' +
  'function add(u){try{var s=abs(u);if(!s)return;' +
  'if(!/\\.(m3u8|mp4|flv)([?#]|$)/i.test(s))return;' +
  'try{window.__kzRef[s]=location.href;}catch(e){}' +
  'if(window.__kzUrls.indexOf(s)<0){window.__kzUrls.push(s);' +
  'try{console.log("__kz-url",s);}catch(e){}}tell(s);}catch(e){}}' +
  'function addPlaylist(u){try{var s=abs(u);if(!s)return;' +
  'try{window.__kzRef[s]=location.href;}catch(e){}' +
  'if(window.__kzExt.indexOf(s)<0){window.__kzExt.push(s);' +
  'try{console.log("__kz-hit",s);}catch(e){}}tell(s);}catch(e){}}' +
  // 播放器常在跨域 iframe 里（AGE 的 jx.* 就是这样），那一帧的 XHR 顶层看不见。
  // 子框架把命中的地址 postMessage 给顶层，顶层统一记到 __kzExt。
  'function tell(u){try{if(window.top&&window.top!==window){' +
  'window.top.postMessage({__kz:u,ref:location.href},"*");}}catch(e){}}' +
  'try{var xo=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){add(u);' +
  'return xo.apply(this,arguments);};}catch(e){}' +
  'try{var f=window.fetch;if(f){window.fetch=function(i){try{add(typeof i==="string"?i:(i&&i.url));}' +
  'catch(e){}return f.apply(this,arguments);};}}catch(e){}' +
  'try{var rt=Response.prototype.text;Response.prototype.text=function(){var self=this;' +
  'return rt.apply(this,arguments).then(function(v){try{if(typeof v==="string"&&' +
  'v.indexOf("#EXTM3U")>=0)addPlaylist(self.url);}catch(e){}return v;});};}catch(e){}' +
  'function scan(){try{var ns=document.querySelectorAll("video,audio,source,iframe");' +
  'for(var i=0;i<ns.length;i++){var el=ns[i];add(el.src||el.currentSrc||"");' +
  'add(el.getAttribute("data-src")||"");' +
  'if(el.tagName==="VIDEO"||el.tagName==="AUDIO"){try{el.muted=true;el.volume=0;}catch(e){}}}' +
  'var h=document.documentElement?document.documentElement.innerHTML:"";' +
  'var m=h.match(/https?:\\/\\/[^"\'\\s\\\\<>]+\\.m3u8[^"\'\\s\\\\<>]*/g);' +
  'if(m){for(var k=0;k<m.length;k++)add(m[k]);}}catch(e){}}' +
  'scan();' +
  'try{new MutationObserver(scan).observe(document.documentElement,{childList:true,subtree:true});}catch(e){}' +
  'try{setInterval(scan,1200);}catch(e){}' +
  '})()';

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

interface SniffBag {
  m3u8: string[];
  ext: string[];
  ref: Record<string, string> | null;
}

/** 一行搜索结果 / 一集的页面地址 */
export interface XPathRow {
  name: string;
  href: string;
  /** 列表页卡片的海报地址（分类浏览用；搜索/选集路径不带） */
  pic?: string;
}

/** 一条线路（线路容器里的一串选集链接） */
export interface XPathRoad {
  name: string;
  items: XPathRow[];
}

class WebSnifferImpl {
  /**
   * 页面栈里可能同时活着好几个页面（搜索页藏在详情页下面），每个页面都挂了自己的
   * SniffWeb。这里按挂载顺序记着，永远用最后挂上来的那个；它所在的页面被销毁时
   * 退回上一个，不至于回到搜索页就再也嗅探不了。
   */
  private stack: webview.WebviewController[] = [];
  private attachedAll: webview.WebviewController[] = [];
  private busy: boolean = false;
  /** 地址 → 发出该请求的页面地址（Referer） */
  private refs: Record<string, string> = JSON.parse('{}') as Record<string, string>;

  mount(c: webview.WebviewController): void {
    for (const it of this.stack) {
      if (it === c) {
        return;
      }
    }
    this.stack.push(c);
  }

  markAttached(c: webview.WebviewController): void {
    let hit: boolean = false;
    for (const it of this.attachedAll) {
      if (it === c) {
        hit = true;
        break;
      }
    }
    if (!hit) {
      this.attachedAll.push(c);
    }
  }

  unmountIf(c: webview.WebviewController): void {
    this.stack = this.stack.filter((it: webview.WebviewController) => it !== c);
    this.attachedAll = this.attachedAll.filter((it: webview.WebviewController) => it !== c);
  }

  private active(): webview.WebviewController | null {
    return this.stack.length > 0 ? this.stack[this.stack.length - 1] : null;
  }

  private isAttached(c: webview.WebviewController): boolean {
    for (const it of this.attachedAll) {
      if (it === c) {
        return true;
      }
    }
    return false;
  }

  /** 这个地址该带的 Referer；没有记录就返回空 */
  refererOf(u: string): string {
    const v: string = this.refs[u] ?? '';
    return v;
  }

  isReady(): boolean {
    const c: webview.WebviewController | null = this.active();
    return c !== null && this.isAttached(c);
  }

  /**
   * 等隐藏 WebView 挂上来。页面是先 build 再挂子组件的，
   * 详情页 / 搜索页在 aboutToAppear 里就发请求时往往还没 attach 完成。
   */
  private async waitReady(maxMs: number): Promise<webview.WebviewController | null> {
    let waited: number = 0;
    while (waited < maxMs) {
      const c: webview.WebviewController | null = this.active();
      if (c !== null && this.isAttached(c)) {
        return c;
      }
      await sleep(200);
      waited += 200;
    }
    const last: webview.WebviewController | null = this.active();
    return last !== null && this.isAttached(last) ? last : null;
  }

  /** 是否正在嗅探：播放页据此显示「正在解析播放地址」 */
  isBusy(): boolean {
    return this.busy;
  }

  /**
   * 打开网页并等它自己吐出播放列表。成功返回 m3u8/mp4 地址，失败返回空串。
   * 单次超时给 10s 左右：慢站要等混淆 JS 跑完，太快放弃等于没做。
   */
  async sniff(url: string, timeoutMs: number): Promise<string> {
    if (url.length === 0 || this.busy) {
      return '';
    }
    this.busy = true;
    let c: webview.WebviewController | null = null;
    try {
      // 播放页是先 aboutToAppear 再 build 的，刚发起解析时隐藏 WebView 可能还没挂上
      c = await this.waitReady(5000);
      if (c === null) {
        return '';
      }
      await c.loadUrl(url);
      await this.installHooks(c);
      const total: number = Date.now() + timeoutMs;
      let got: string = await this.pollUntil(c, Math.min(4500, timeoutMs));
      if (got.length > 0) {
        return got;
      }
      // 播放器大多塞在跨域 iframe 里，父页面里挂的钩子看不见那一帧发的请求。
      // 把 iframe 地址当顶层页面再跑一遍 —— 这样它就是主框架，钩子全都命中。
      const frames: string[] = await this.framesOf(c);
      const budget: number = total - Date.now();
      const each: number = frames.length > 0 ? Math.max(2500, Math.min(6000, Math.floor(budget / 2))) : 0;
      for (let i = 0; i < frames.length && i < 2 && each > 500; i++) {
        if (Date.now() >= total) {
          break;
        }
        try {
          await c.loadUrl(frames[i]);
        } catch (e) {
          continue;
        }
        await this.installHooks(c);
        got = await this.pollUntil(c, each);
        if (got.length > 0) {
          return got;
        }
      }
      // 还有时间就在最后一页继续等（有的播放器点了播放才发请求）
      got = await this.pollUntil(c, Math.max(0, total - Date.now()));
      return got;
    } catch (e) {
      return '';
    } finally {
      this.busy = false;
      // 嗅探完成后一定要把页面撤掉：留着会继续加载分片、继续占带宽
      if (c !== null) {
        try {
          await c.loadUrl('about:blank');
        } catch (e) {
          // 页面已销毁时 loadUrl 会抛，忽略
        }
      }
    }
  }

  /** 手动补装钩子：文档开始注入在部分版本/部分站点上不生效，加载完再装一次兜底 */
  private async installHooks(c: webview.WebviewController): Promise<void> {
    try {
      await c.runJavaScript(SNIFF_SCRIPT);
    } catch (e) {
      // 页面还没起来时 runJavaScript 会抛，忽略
    }
  }

  private async pollUntil(c: webview.WebviewController, ms: number): Promise<string> {
    const deadline: number = Date.now() + ms;
    while (Date.now() < deadline) {
      await sleep(700);
      const got: string = await this.poll(c);
      if (got.length > 0) {
        return got;
      }
    }
    return '';
  }

  /** 页面里的 iframe 地址：播放器一般就在这里，广告的后面再看也来不及，先取前两个 */
  private async framesOf(c: webview.WebviewController): Promise<string[]> {
    const out: string[] = [];
    let txt: string = '';
    try {
      txt = await c.runJavaScript('(function(){try{var o=[];var ns=document.querySelectorAll("iframe");' +
        'for(var i=0;i<ns.length;i++){var s=ns[i].src||ns[i].getAttribute("data-src")||"";' +
        'if(s&&/^https?:/i.test(s)&&o.indexOf(s)<0)o.push(s);}return JSON.stringify(o);}catch(e){return ""}})()');
    } catch (e) {
      return out;
    }
    const s: string = WebSnifferImpl.unwrap(txt);
    if (s.length === 0) {
      return out;
    }
    try {
      const arr = JSON.parse(s) as string[];
      if (Array.isArray(arr)) {
        for (const u of arr) {
          out.push(u);
        }
      }
    } catch (e) {
      return out;
    }
    return out;
  }

  private async poll(c: webview.WebviewController): Promise<string> {
    let txt: string = '';
    try {
      txt = await c.runJavaScript(
        '(function(){try{return JSON.stringify({m3u8:window.__kzUrls||[],ext:window.__kzExt||[],' +
          'ref:window.__kzRef||{}})}'
          + 'catch(e){return ""}})()');
    } catch (e) {
      return '';
    }
    if (txt.length === 0) {
      return '';
    }
    let s: string = txt.trim();
    // 有的版本会把字符串结果再套一层引号
    if (s.startsWith('"') && s.endsWith('"') && s.length > 1) {
      s = s.substring(1, s.length - 1).split('\\"').join('"');
    }
    let bag: SniffBag | null = null;
    try {
      bag = JSON.parse(s) as SniffBag;
    } catch (e) {
      return '';
    }
    if (bag === null) {
      return '';
    }
    // 记下每个地址是在哪一帧、哪个页面上发出来的：播放器要用它当 Referer
    if (bag.ref !== null && bag.ref !== undefined) {
      const keys: string[] = Object.keys(bag.ref);
      for (const k of keys) {
        this.refs[k] = bag.ref[k];
      }
    }
    // 响应体里出现过 #EXTM3U 的最可信，其次才是地址里带后缀的
    if (bag.ext && bag.ext.length > 0) {
      return WebSnifferImpl.pickOne(bag.ext);
    }
    if (bag.m3u8 && bag.m3u8.length > 0) {
      return WebSnifferImpl.pickOne(bag.m3u8);
    }
    return '';
  }

  /** 优先 m3u8，跳过 .ts 分片与明显的广告 sdk */
  private static pickOne(list: string[]): string {
    let mp4: string = '';
    for (const u of list) {
      const low: string = u.toLowerCase();
      if (low.includes('.ts')) {
        continue;
      }
      if (low.includes('.m3u8')) {
        return u;
      }
      if (low.includes('.mp4') && mp4.length === 0) {
        mp4 = u;
      }
    }
    return mp4;
  }

  // ---------------- XPath 规则（Kazumi 的网页模式） ----------------

  /**
   * 在网页里跑一遍 XPath，把「一列节点 + 每个节点里的名字和链接」取出来。
   * 用于规则库里的 searchList / searchName / searchResult，
   * 以及详情页的 chapterRoads / chapterResult。
   *
   * 页面是异步渲染的，所以到点就重试一次 JS，直到拿到非空结果或超时。
   */
  private async loadAndEval(url: string, js: string, timeoutMs: number): Promise<string> {
    if (url.length === 0) {
      return '';
    }
    const c: webview.WebviewController | null = await this.waitReady(4000);
    if (c === null) {
      logWeb('waitReady 超时，没有可用的隐藏 WebView');
      return '';
    }
    try {
      await c.loadUrl(url);
      logWeb('load ' + url);
    } catch (e) {
      logWeb('loadUrl 失败 ' + url + ' : ' + (e as Error).message);
      return '';
    }
    const deadline: number = Date.now() + timeoutMs;
    let tries: number = 0;
    while (Date.now() < deadline) {
      await sleep(800);
      let out: string = '';
      try {
        out = await c.runJavaScript(js);
      } catch (e) {
        tries++;
        logWeb('runJavaScript 异常 #' + tries + ' : ' + (e as Error).message);
        continue;
      }
      const v: string = WebSnifferImpl.unwrap(out);
      tries++;
      if (v.length > 2 && v !== '[]') {
        logWeb('命中（第' + tries + '次）len=' + v.length);
        return v;
      }
    }
    logWeb('XPath 求值失败，页面：' + url);
    return '';
  }

  /** runJavaScript 的返回值有的版本会再套一层引号 */
  private static unwrap(txt: string): string {
    if (txt.length === 0) {
      return '';
    }
    let s: string = txt.trim();
    if (s.startsWith('"') && s.endsWith('"') && s.length > 1) {
      s = s.substring(1, s.length - 1).split('\\"').join('"').split('\\\\').join('\\');
    }
    return s;
  }

  async xpathRows(url: string, list: string, name: string, href: string,
    timeoutMs: number, pic: string = ''): Promise<XPathRow[]> {
    if (list.length === 0 || href.length === 0) {
      return [];
    }
    const js: string = '(function(){' +
      // 规则里的 xpath 大多写成 //a/b（绝对路径），但语义上是「相对列表项 / 相对线路容器」。
      // 直接按全文档求值会把页脚导航、侧栏链接一起抓进来，所以带上下文时先试 .// 版本，
      // 空了再退回绝对写法（个别规则确实用绝对路径）。
      // 取名字 / 取链接这种「子项」求值绝不能退回绝对：容器本来就是空的（页面上也匹配到
      // 一堆标题栏），一退回就把整站导航当剧集收进来。
      'function q(p,c,abs){var o=[];var ps=c?(p.indexOf("//")===0?(abs?["."+p,p]:["."+p]):[p]):[p];' +
      'for(var j=0;j<ps.length;j++){try{var r=document.evaluate(ps[j],c||document,null,7,null);' +
      'for(var i=0;i<r.snapshotLength;i++)o.push(r.snapshotItem(i));}catch(e){}' +
      'if(o.length)break;}return o;}' +
      'function nmOf(el){var t=el?(String(el.textContent||"").trim()):"";' +
      'var a=el&&el.getAttribute?String(el.getAttribute("title")||"").trim():"";' +
      'return a.length>t.length?a:t;}' +
      'var rows=q(' + JSON.stringify(list) + ',null,true);var out=[];' +
      'for(var i=0;i<rows.length;i++){' +
      'var nm=q(' + JSON.stringify(name) + ',rows[i],false)[0];' +
      'var a=q(' + JSON.stringify(href) + ',rows[i],false)[0];' +
      'var n=nmOf(nm);' +
      'var u=a?String(a.getAttribute("href")||""):"";' +
      'if(u&&u.indexOf("//")===0)u=location.protocol+u;' +
      'else if(u&&u.charAt(0)==="/")u=location.origin+u;' +
      // 海报可选：懒加载站点的真地址常在 src / data-src / data-original 上，挨个兜
      'var ps="";var pp=' + JSON.stringify(pic) + ';' +
      'if(pp&&pp.length){var im=q(pp,rows[i],false)[0];' +
      'if(im&&im.getAttribute){ps=String(im.getAttribute("src")||im.getAttribute("data-src")||' +
      'im.getAttribute("data-original")||"");}' +
      'if(ps.indexOf("//")===0)ps=location.protocol+ps;' +
      'else if(ps.charAt(0)==="/")ps=location.origin+ps;}' +
      'if(n&&u)out.push({name:n,href:u,pic:ps});}' +
      'return JSON.stringify(out);})()';
    const txt: string = await this.loadAndEval(url, js, timeoutMs);
    return WebSnifferImpl.parseRows(txt);
  }

  async xpathRoads(url: string, roads: string, result: string,
    timeoutMs: number): Promise<XPathRoad[]> {
    if (roads.length === 0 || result.length === 0) {
      return [];
    }
    const js: string = '(function(){' +
      // 选集 xpath 同样按「相对线路容器」求值，否则 //ul/li/a 会把页脚导航一起抓进来。
      // 子项不退回绝对：页面里的标题栏也会被 roads 匹配到，一退回就把整站导航当剧集。
      'function q(p,c,abs){var o=[];var ps=c?(p.indexOf("//")===0?(abs?["."+p,p]:["."+p]):[p]):[p];' +
      'for(var j=0;j<ps.length;j++){try{var r=document.evaluate(ps[j],c||document,null,7,null);' +
      'for(var i=0;i<r.snapshotLength;i++)o.push(r.snapshotItem(i));}catch(e){}' +
      'if(o.length)break;}return o;}' +
      'function nmOf(el){var t=el?(String(el.textContent||"").trim()):"";' +
      'var a=el&&el.getAttribute?String(el.getAttribute("title")||"").trim():"";' +
      'return a.length>t.length?a:t;}' +
      'var rs=q(' + JSON.stringify(roads) + ',null,true);var out=[];var no=0;' +
      'for(var i=0;i<rs.length;i++){' +
      'var as=q(' + JSON.stringify(result) + ',rs[i],false);var items=[];' +
      'for(var k=0;k<as.length;k++){' +
      'var a=as[k];var n=nmOf(a);' +
      'var u=String(a.getAttribute("href")||"");' +
      'if(!u)continue;' +
      'if(u.indexOf("//")===0)u=location.protocol+u;' +
      'else if(u.charAt(0)==="/")u=location.origin+u;' +
      'items.push({name:n,href:u});}' +
      'if(items.length){no++;out.push({name:"线路"+no,items:items});}}' +
      'return JSON.stringify(out);})()';
    const txt: string = await this.loadAndEval(url, js, timeoutMs);
    const roads2: XPathRoad[] = [];
    if (txt.length === 0) {
      return roads2;
    }
    try {
      const arr = JSON.parse(txt) as XPathRoad[];
      if (Array.isArray(arr)) {
        for (const r of arr) {
          if (r !== null && r.items !== undefined && r.items !== null && r.items.length > 0) {
            roads2.push(r);
          }
        }
      }
    } catch (e) {
      return roads2;
    }
    return roads2;
  }

  private static parseRows(txt: string): XPathRow[] {
    const out: XPathRow[] = [];
    if (txt.length === 0) {
      return out;
    }
    try {
      const arr = JSON.parse(txt) as XPathRow[];
      if (Array.isArray(arr)) {
        for (const r of arr) {
          if (r !== null && r.href !== undefined && r.href.length > 0) {
            out.push(r);
          }
        }
      }
    } catch (e) {
      return out;
    }
    return out;
  }
}

/** 全局单例：谁挂了隐藏 Web，谁就能用 */
export const sniffer = new WebSnifferImpl();
