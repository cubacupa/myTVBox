import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { AppState } from '../utils/AppState';
import { ConfigStore } from '../utils/ConfigStore';
import { ApiStore, SavedApi } from '../utils/ApiStore';
import { BuiltinConfig } from '../utils/BuiltinConfig';
import { SiteCfg, RepoCfg, RepoScanResult, LiveCfg } from '../model/TvBoxModels';
import { LiveSrcProbe } from '../utils/LiveSrcProbe';
import { MySitesStore } from '../utils/MySitesStore';
import { PinStore } from '../utils/PinStore';
import { DoubanAuth } from '../utils/DoubanAuth';
import { HttpUtil } from '../utils/HttpUtil';
import { pushServer } from '../utils/PushServer';
import { QrView } from '../components/QrView';
import { SideNav } from '../components/SideNav';

/**
 * 设置页配色。与首页 / 收藏 / 历史同一套：近黑底 + 琥珀高亮，
 * 卡片比底色亮一点、描边比卡片亮一点，层级靠明度差而不是靠颜色。
 */
const C_CARD: string = '#0F1015';
const C_LINE: string = '#1A1B22';
const C_INPUT: string = '#16171E';
const C_ACCENT: string = '#FF8A3D';
const C_SUB: string = '#8E8E9A';
const C_DIM: string = '#6E6E7A';

/** 豆瓣接口认这个浏览器 UA，okhttp 之类会回 1287 invalid_request */
const UA_DOUBAN: string =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';

/** 用户公开资料（只用来取昵称做显示） */
interface DoubanMe {
  id?: string;
  name?: string;
}

/**
 * 判断登录态不能用 rexxar 的 /v2/user/me：那个接口带不带 Cookie 都返回同一个
 * 匿名账号（1048835 / xingdiannao），拿它当依据会把有效的 Cookie 判成失效。
 *
 * 改成看 m.douban.com/mine/：登录后 302 到 /people/<自己的ID>/，未登录 302 到
 * accounts.douban.com 的登录页；http 模块默认跟随重定向，所以只要看最终正文里
 * 有没有 people/<dbcl2 里的那个 ID>，就能分辨是在自己主页还是被踢去登录页。
 */

/**
 * 设置页：点播源与直播源分开载入。
 *
 * 为什么要分两个：
 *   采集接口经常"点播废了、直播还活着"（或者反过来）。放在同一个地址槽里，
 *   换点播就顺手把能用的直播源也换掉了，所以这里做成两块互不干扰的来源：
 *     · 点播源 → sites / parses / 当前站点
 *     · 直播源 → lives（不填就跟随点播源那份配置）
 *
 * 两块左右并列、各占半屏；每块内部两行：
 *   第一行 = 名称 30% + 地址 70%（按 layoutWeight 3:7 分）
 *   第二行 = 粘贴 / 载入 / 清空 / 手机推送，占满整行并靠右对齐
 * 按钮不放第一行：半屏宽度下四个按钮会把地址输入框挤到几乎看不见。
 */
@Entry
@Component
struct Settings {
  // ---- 点播源 ----
  @State vodAddr: string = '';
  @State vodName: string = '';
  @State vodAutoName: string = '';
  // ---- 直播源 ----
  @State liveAddr: string = '';
  @State liveName: string = '';
  @State liveAutoName: string = '';
  @State liveOwn: boolean = false;

  @State saved: SavedApi[] = [];
  @State sites: SiteCfg[] = [];
  @State dropped: number = 0;
  @State lives: LiveCfg[] = [];
  @State repos: RepoCfg[] = [];
  @State rows: RepoScanResult[] = [];
  @State scanning: boolean = false;
  @State scanTip: string = '';
  @State repoName: string = '';
  @State curKey: string = '';
  @State configName: string = '';
  @State usableCount: number = 0;
  @State parseCount: number = 0;
  @State errMsg: string = '';
  /** '' | 'vod' | 'live'：哪一块正在联网，用来禁掉重复点击 */
  @State busy: string = '';

  /** Default 里用户自己收进来的站点 api（规范化后），这些行才显示「删除」 */
  @State removableApis: string[] = [];
  // 家长锁：4 位 PIN，设置后点播页隐藏带敏感字样的二级分类
  @State pinHas: boolean = false;
  @State pinText: string = '';
  @State pinMsg: string = '';
  // 清除 PIN 前先验证，避免别人一按就关掉家长锁
  @State pinClearOpen: boolean = false;
  @State pinClearInput: string = '';
  @State pinClearErr: string = '';

  // 豆瓣登录（可选）：Cookie 导入，缓解按名搜索的 IP 风控
  @State doubanText: string = '';
  @State doubanHas: boolean = false;
  @State doubanInfo: string = '未登录';
  @State doubanMsg: string = '';
  @State doubanBusy: boolean = false;

  // 改名浮层
  @State renameOpen: boolean = false;
  @State renameUrl: string = '';
  @State renameText: string = '';
  @State renamePlaceholder: string = '新名字';

  // 手机推送浮层
  @State pushOpen: boolean = false;
  /** 'vod' | 'live'：推进来的地址该填哪个框 */
  @State pushTarget: string = 'vod';
  @State pushUrl: string = '';
  @State pushErr: string = '';
  @State pushMsg: string = '';
  @State pushDiag: string = '';
  private pushTimer: number = -1;

  aboutToDisappear(): void {
    this.closePush();
  }

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    const ctx = getContext(this) as common.Context;
    DoubanAuth.init(ctx);
    try {
      await ConfigStore.init(ctx);
    } catch (e) {
      this.say((e as Error).message);
    }
    this.repos = AppState.repos;
    this.buildRows();
    this.sync();
  }

  private sync(): void {
    this.vodAddr = AppState.configUrl;
    this.vodName = AppState.configName;
    this.vodAutoName = AppState.configName;
    this.configName = AppState.configName;
    this.liveOwn = AppState.hasOwnLive();
    this.liveAddr = AppState.liveUrl;
    this.liveName = AppState.liveName;
    this.liveAutoName = AppState.liveName;
    this.sites = AppState.usableSites();
    this.dropped = AppState.droppedSites();
    this.lives = AppState.lives;
    this.parseCount = AppState.cfg.parses.length;
    this.repoName = AppState.repoName;
    this.usableCount = this.sites.length;
    this.curKey = AppState.currentSite !== null ? AppState.currentSite.key : '';
    this.errMsg = AppState.err;
    const ctx = getContext(this) as common.Context;
    this.saved = ConfigStore.savedApis(ctx);
    this.removableApis = MySitesStore.userApis(ctx);
    this.pinHas = PinStore.get(ctx).length === 4;
    this.doubanHas = DoubanAuth.has();
    this.doubanInfo = DoubanAuth.summary();
  }

  private buildRows(): void {
    const out: RepoScanResult[] = [];
    for (const r of this.repos) {
      const row = new RepoScanResult();
      row.name = r.name;
      row.url = r.url;
      row.msg = '未扫描';
      out.push(row);
    }
    this.rows = out;
    this.scanTip = '';
  }

  // ---------- 输入辅助 ----------

  private async pasteInto(isLive: boolean): Promise<void> {
    try {
      const board = pasteboard.getSystemPasteboard();
      const data = await board.getData();
      const text = data.getPrimaryText();
      if (!text || text.length === 0) {
        this.say('剪贴板里没有文字');
        return;
      }
      if (isLive) {
        this.liveAddr = text.trim();
        this.suggestLiveName();
      } else {
        this.vodAddr = text.trim();
        this.suggestVodName();
      }
      this.say('已从剪贴板粘贴到' + (isLive ? '直播源' : '点播源') + '，按「载入」生效');
    } catch (e) {
      this.say('粘贴失败：' + (e as Error).message);
    }
  }

  // ---------- 手机扫码推送 ----------

  /**
   * 电视上打字太痛苦：手机扫码把地址推过来。
   * 电视起一个局域网 HTTP 服务，二维码里就是它的地址；手机提交后
   * 这里轮询 take()，拿到就填进对应的输入框。
   */
  private async openPush(target: string): Promise<void> {
    this.stopPoll();
    this.pushTarget = target;
    this.pushUrl = '';
    this.pushErr = '';
    this.pushMsg = '';
    this.pushOpen = true;
    await pushServer.start(target === 'cookie' ? 'cookie' : 'addr');
    if (!pushServer.isRunning()) {
      this.pushErr = pushServer.error();
      return;
    }
    this.pushUrl = pushServer.url();
    if (this.pushUrl.length === 0) {
      this.pushErr = '服务起来了但地址是空的';
      return;
    }
    this.startPoll();
  }

  private startPoll(): void {
    this.stopPoll();
    this.pushTimer = setInterval(() => {
      if (pushServer.diag !== this.pushDiag) {
        this.pushDiag = pushServer.diag;
      }
      const v = pushServer.take();
      if (v.length === 0) {
        return;
      }
      if (this.pushTarget === 'live') {
        this.liveAddr = v;
        this.suggestLiveName();
      } else if (this.pushTarget === 'cookie') {
        this.doubanText = v;
      } else {
        this.vodAddr = v;
        this.suggestVodName();
      }
      this.pushMsg = this.pushTarget === 'cookie'
        ? '收到 Cookie，回去点「保存并验证」'
        : '收到，已填进输入框';
      this.stopPoll();
      setTimeout(() => {
        this.pushOpen = false;
        pushServer.stop();
      }, 1400);
    }, 400);
  }

  private stopPoll(): void {
    if (this.pushTimer >= 0) {
      clearInterval(this.pushTimer);
      this.pushTimer = -1;
    }
  }

  private closePush(): void {
    this.stopPoll();
    this.pushOpen = false;
    pushServer.stop();
  }

  /**
   * 地址变了以后给名称一个建议值。
   * ① 用户自己敲过名字就不再覆盖；② 地址清空时名字跟着清空；
   * ③ 地址还没打完先不填，免得名字停在半截字符。
   */
  private suggestVodName(): void {
    const a: string = this.vodAddr.trim();
    const cur: string = this.vodName.trim();
    const manual: boolean = cur.length > 0 && cur !== this.vodAutoName;
    if (a.length === 0) {
      if (!manual) {
        this.vodName = '';
        this.vodAutoName = '';
      }
      return;
    }
    if (manual || a.indexOf('.') < 0) {
      return;
    }
    this.vodName = a === AppState.configUrl ? AppState.configName
      : (BuiltinConfig.isBuiltin(a) ? BuiltinConfig.NAME : ApiStore.guessName(a));
    this.vodAutoName = this.vodName;
  }

  private suggestLiveName(): void {
    const a: string = this.liveAddr.trim();
    const cur: string = this.liveName.trim();
    const manual: boolean = cur.length > 0 && cur !== this.liveAutoName;
    if (a.length === 0) {
      if (!manual) {
        this.liveName = '';
        this.liveAutoName = '';
      }
      return;
    }
    if (manual || a.indexOf('.') < 0) {
      return;
    }
    this.liveName = ApiStore.guessName(a);
    this.liveAutoName = this.liveName;
  }

  // ---------- 载入 ----------

  private async loadVod(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = 'vod';
    this.say('正在拉取点播配置…');
    const ctx = getContext(this) as common.Context;
    try {
      const m = await ConfigStore.importAddress(ctx, this.vodAddr, this.vodName);
      this.repos = AppState.repos;
      this.rows = [];
      if (this.repos.length > 0) {
        this.buildRows();
        this.say(m + '（点下方仓库加载，或先「扫描全部」找出能用的）');
      } else {
        this.say(m);
      }
      this.sync();
    } catch (e) {
      this.say('点播源载入失败：' + (e as Error).message);
    } finally {
      this.busy = '';
    }
  }

  private async loadLiveSrc(): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = 'live';
    this.say('正在拉取直播源…');
    const ctx = getContext(this) as common.Context;
    try {
      this.say(await ConfigStore.loadLive(ctx, this.liveAddr, this.liveName));
      this.sync();
    } catch (e) {
      this.say('直播源载入失败：' + (e as Error).message);
    } finally {
      this.busy = '';
    }
  }

  /** 清掉独立直播源，回到「跟随点播源」 */
  private backToVodLive(): void {
    const ctx = getContext(this) as common.Context;
    ConfigStore.clearLive(ctx);
    this.say('直播源已跟随点播源（' + this.livesAfterFollow() + '）');
    this.sync();
  }

  private livesAfterFollow(): string {
    const n: number = AppState.cfg.lives.length;
    return n > 0 ? '当前点播配置里有 ' + n + ' 个直播列表' : '当前点播配置里没有 lives，直播页会提示无源';
  }

  /** 地址簿点一条：载入为点播源 */
  private async useSavedAsVod(a: SavedApi): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.vodAddr = a.url;
    this.vodName = a.name;
    this.vodAutoName = a.name;
    await this.loadVod();
  }

  /** 地址簿点一条：设为直播源 */
  private async useSavedAsLive(a: SavedApi): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.liveAddr = a.url;
    this.liveName = a.name;
    this.liveAutoName = a.name;
    await this.loadLiveSrc();
  }

  private clearVodInput(): void {
    this.vodAddr = '';
    this.vodName = '';
    this.vodAutoName = '';
  }

  private clearLiveInput(): void {
    this.liveAddr = '';
    this.liveName = '';
    this.liveAutoName = '';
  }

  // ---------- 改名 / 删除 ----------

  private openRename(a: SavedApi): void {
    this.renameUrl = a.url;
    this.renameText = '';
    this.renamePlaceholder = '原名：' + a.name + '，输入新名字';
    this.renameOpen = true;
  }

  private doRename(): void {
    const nm: string = this.renameText.trim();
    if (nm.length === 0) {
      this.say('名字不能为空');
      return;
    }
    const ctx = getContext(this) as common.Context;
    ConfigStore.renameApi(ctx, this.renameUrl, nm);
    this.renameOpen = false;
    this.say('已改名为「' + nm + '」');
    this.sync();
  }

  private delSaved(a: SavedApi): void {
    const ctx = getContext(this) as common.Context;
    ConfigStore.removeApi(ctx, a.url);
    const isCur: boolean = a.url === AppState.configUrl;
    this.say('已从列表移除「' + a.name + '」' + (isCur ? '，但当前点播源还是它（地址没变）' : ''));
    this.sync();
  }

  // ---------- 多仓 ----------

  private async scanAll(): Promise<void> {
    if (this.scanning || this.rows.length === 0) {
      return;
    }
    this.scanning = true;
    this.scanTip = '正在扫描…';
    const BATCH: number = 3;
    const total: number = this.rows.length;
    let finished: number = 0;
    for (let i = 0; i < total; i += BATCH) {
      const end: number = Math.min(i + BATCH, total);
      const jobs: Promise<RepoScanResult>[] = [];
      for (let j = i; j < end; j++) {
        const repo = new RepoCfg();
        repo.name = this.rows[j].name;
        repo.url = this.rows[j].url;
        jobs.push(ConfigStore.scanOne(repo));
      }
      this.scanTip = '正在扫描 ' + end + ' / ' + total + '…';
      const done: RepoScanResult[] = await Promise.all(jobs);
      const next: RepoScanResult[] = this.rows.slice();
      for (let k = 0; k < done.length; k++) {
        next[i + k] = done[k];
        finished++;
      }
      this.rows = next;
    }
    const sorted: RepoScanResult[] = this.rows.slice();
    sorted.sort((a: RepoScanResult, b: RepoScanResult) => b.usable - a.usable);
    this.rows = sorted;
    let ok: number = 0;
    for (const r of sorted) {
      if (r.ok) {
        ok++;
      }
    }
    this.scanTip = '扫描完成：' + ok + ' / ' + finished + ' 个仓库有可用站点'
      + (ok === 0 ? '。这份多仓里没有能跑的站点（几乎全是 spider 型），换一份配置更快' : '');
    this.scanning = false;
  }

  private async useRepoUrl(name: string, url: string): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = 'vod';
    this.say('正在加载「' + name + '」…');
    const ctx = getContext(this) as common.Context;
    const r = new RepoCfg();
    r.name = name;
    r.url = url;
    try {
      this.say(await ConfigStore.importRepo(ctx, r));
      this.sync();
    } catch (e) {
      this.say('加载仓库失败：' + (e as Error).message);
    } finally {
      this.busy = '';
    }
  }

  private async useSite(s: SiteCfg): Promise<void> {
    if (!AppState.isUsable(s)) {
      this.say('「' + s.name + '」依赖 spider，已从列表过滤');
      return;
    }
    const ctx = getContext(this) as common.Context;
    await ConfigStore.setSite(ctx, s);
    this.curKey = s.key;
    this.say('已切换到「' + s.name + '」，回点播页刷新即可');
  }

  /** 只有「用户自己收进 Default」的站点能删；预设的暴风资源永远不显示删除 */
  private canRemoveSite(s: SiteCfg): boolean {
    return this.removableApis.indexOf(MySitesStore.normApi(s.api ?? '')) >= 0;
  }

  private delMySite(s: SiteCfg): void {
    const ctx = getContext(this) as common.Context;
    this.say(MySitesStore.remove(ctx, s.api ?? ''));
    // Default 是静态拼出来的，写盘后要重新解析一次，资源站列表才会少一行；
    // applyText 会按 key 重新绑定当前站，删掉的正好是当前站时自动落到剩下的第一个
    if (BuiltinConfig.isBuiltin(AppState.configUrl)) {
      ConfigStore.applyText(BuiltinConfig.text());
    }
    this.sync();
  }

  private savePin(): void {
    const ctx = getContext(this) as common.Context;
    const v: string = this.pinText.trim();
    if (!/^\d{4}$/.test(v)) {
      this.pinMsg = '请输入正好 4 位数字';
      return;
    }
    if (!PinStore.set(ctx, v)) {
      this.pinMsg = '保存失败：本地文件写不进去';
      return;
    }
    this.pinText = '';
    this.pinHas = true;
    this.pinMsg = 'PIN 已设置';
  }

  /** 清除前先要 PIN：不验的话谁都能一按就关掉家长锁 */
  private askClearPin(): void {
    if (!this.pinHas) {
      this.pinMsg = '还没有设置 PIN';
      return;
    }
    this.pinClearInput = '';
    this.pinClearErr = '';
    this.pinClearOpen = true;
  }

  private doClearPin(): void {
    const ctx = getContext(this) as common.Context;
    if (this.pinClearInput.trim() !== PinStore.get(ctx)) {
      this.pinClearErr = 'PIN 不对，无法清除';
      return;
    }
    PinStore.clear(ctx);
    this.pinText = '';
    this.pinHas = false;
    this.pinClearOpen = false;
    this.pinClearInput = '';
    this.pinClearErr = '';
    this.pinMsg = 'PIN 已清除';
  }

  // ---------- 豆瓣登录 ----------

  private async pasteCookie(): Promise<void> {
    try {
      const board = pasteboard.getSystemPasteboard();
      const data = await board.getData();
      const text = data.getPrimaryText();
      if (!text || text.length === 0) {
        this.doubanMsg = '剪贴板里没有文字';
        return;
      }
      this.doubanText = text.trim();
      this.doubanMsg = '已从剪贴板粘贴，点「保存并验证」生效';
    } catch (e) {
      this.doubanMsg = '粘贴失败：' + (e as Error).message;
    }
  }

  /**
   * 验证办法：dbcl2="<数字ID>:<hash>" 里带着豆瓣用户 ID，用这份 Cookie 打开
   * m.douban.com/mine/ —— 登录态会被重定向到 /people/<这个ID>/，未登录会被送去
   * 登录页。看最终正文里有没有 people/<ID> 即可（详见文件头说明）。
   */
  private async saveCookie(): Promise<void> {
    if (this.doubanBusy) {
      return;
    }
    const raw: string = this.doubanText.trim();
    if (raw.length === 0) {
      this.doubanMsg = '先把 Cookie 粘贴进来';
      return;
    }
    const ctx = getContext(this) as common.Context;
    if (!DoubanAuth.setRaw(ctx, raw)) {
      this.doubanMsg = '这段文本里没有 dbcl2，不是登录后的 Cookie（匿名访问复制到的不算）';
      return;
    }
    this.doubanBusy = true;
    this.doubanMsg = '正在向豆瓣验证…';
    try {
      const uid: string = DoubanAuth.id();
      const mine: string = await HttpUtil.getTextWith(
        'https://m.douban.com/mine/',
        'https://m.douban.com/mine/', UA_DOUBAN);
      if (mine.indexOf('people/' + uid) < 0) {
        // 被送去登录页 = 这份 Cookie 没被豆瓣认，或者已经失效
        this.doubanMsg = 'Cookie 无效或已过期（豆瓣把这次请求当成了未登录），请重新复制一次';
        return;
      }
      // 昵称只是展示用，取不到不影响登录态
      let nm: string = '';
      try {
        const p: string = await HttpUtil.getTextWith(
          'https://m.douban.com/rexxar/api/v2/user/' + uid,
          'https://m.douban.com/people/' + uid + '/', UA_DOUBAN);
        const pd: DoubanMe = JSON.parse(p.trim()) as DoubanMe;
        nm = (pd.name ?? '').trim();
      } catch (e2) {
        nm = '';
      }
      DoubanAuth.confirmName(ctx, nm);
      this.doubanMsg = '登录成功：' + (nm.length > 0 ? nm : ('ID ' + uid));
      this.doubanText = '';   // 别把一长串 Cookie 留在界面上
    } catch (e) {
      this.doubanMsg = '验证请求失败：' + (e as Error).message + '（Cookie 已保存，可稍后再试）';
    } finally {
      this.doubanBusy = false;
      this.sync();
    }
  }

  private clearCookie(): void {
    const ctx = getContext(this) as common.Context;
    DoubanAuth.clear(ctx);
    this.doubanText = '';
    this.doubanMsg = '已退出豆瓣登录，之后按匿名身份请求';
    this.sync();
  }

  /** 操作反馈一律走 toast：短暂停留，不在页面上占一行常驻文字 */
  private say(text: string): void {
    const s: string = (text ?? '').trim();
    if (s.length === 0) {
      return;
    }
    try {
      this.getUIContext().getPromptAction().showToast({ message: s, duration: 2200 });
    } catch (e) {
      try {
        promptAction.showToast({ message: s, duration: 2200 });
      } catch (e2) {
        // 提示失败不影响操作本身
      }
    }
  }

  // ---------- UI ----------

  @Builder
  section(title: string) {
    Row({ space: 9 }) {
      Row()
        .width(3)
        .height(13)
        .borderRadius(2)
        .backgroundColor(C_ACCENT)
      Text(title)
        .fontSize(13.5)
        .fontColor('#C9C9D4')
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .margin({ top: 12, bottom: 14 })
  }

  /** 页面顶栏：标题 + 数据胶囊，右侧留给状态提示 */
  @Builder
  pageHeader() {
    Row() {
      Row({ space: 12 }) {
        Text('设置')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text(this.configName.length > 0 ? this.configName : '未载入')
          .fontSize(12.5)
          .fontColor(C_SUB)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .borderRadius(7)
          .backgroundColor('#12FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 220 })
        Text('点播源与直播源各存一份，改完立刻生效')
          .fontSize(12.5)
          .fontColor('#7E7E8A')
      }
      // 与标题垂直居中：底对齐时小字被压到 34 号字的字形底缘
      .alignItems(VerticalAlign.Center)

      Blank()

      Row({ space: 10 }) {
        Row({ space: 7 }) {
          Text('可用站点')
            .fontSize(12)
            .fontColor(C_DIM)
          Text(this.usableCount.toString())
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFB37A')
        }
        .height(32)
        .padding({ left: 13, right: 13 })
        .borderRadius(16)
        .backgroundColor('#12FFFFFF')

        Row({ space: 7 }) {
          Text('直播')
            .fontSize(12)
            .fontColor(C_DIM)
          Text(this.lives.length.toString())
            .fontSize(12.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.lives.length > 0 ? '#7FD88A' : C_SUB)
        }
        .height(32)
        .padding({ left: 13, right: 13 })
        .borderRadius(16)
        .backgroundColor('#12FFFFFF')
      }
    }
    .width('100%')
    .height(56)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 44, right: 36 })
    .margin({ top: 26, bottom: 6 })
  }

  /**
   * 输入框：按 3:7 分宽（名称 30% / 地址 70%），按钮另起一行右对齐。
   *
   * 注意：这里四个 builder 都不带参数。@Builder 的入参是值传递，父组件状态
   * 变了不会重建节点 —— 带参数的话，点「粘贴」把地址写进 this.vodAddr，
   * 输入框里会一直显示旧内容。
   */
  @Builder
  vodNameBox() {
    TextInput({ text: this.vodName, placeholder: '名称（留空用域名）' })
      .layoutWeight(3)
      .height(46)
      .fontSize(14)
      .fontColor('#FFFFFF')
      .placeholderColor('#5C5C68')
      .backgroundColor(C_INPUT)
      .borderRadius(12)
      .border({ width: 1, color: '#20212A' })
      .padding({ left: 14, right: 14 })
      .onChange((v: string) => { this.vodName = v; })
  }

  @Builder
  vodAddrBox() {
    TextInput({ text: this.vodAddr, placeholder: '配置地址 https://.../config.json' })
      .layoutWeight(7)
      .height(46)
      .fontSize(14)
      .fontColor('#FFFFFF')
      .placeholderColor('#5C5C68')
      .backgroundColor(C_INPUT)
      .borderRadius(12)
      .border({ width: 1, color: '#20212A' })
      .padding({ left: 14, right: 14 })
      .onChange((v: string) => {
        this.vodAddr = v;
        this.suggestVodName();
      })
  }

  @Builder
  liveNameBox() {
    TextInput({ text: this.liveName, placeholder: '名称' })
      .layoutWeight(3)
      .height(46)
      .fontSize(14)
      .fontColor('#FFFFFF')
      .placeholderColor('#5C5C68')
      .backgroundColor(C_INPUT)
      .borderRadius(12)
      .border({ width: 1, color: '#20212A' })
      .padding({ left: 14, right: 14 })
      .onChange((v: string) => { this.liveName = v; })
  }

  @Builder
  liveAddrBox() {
    TextInput({ text: this.liveAddr, placeholder: 'm3u / txt 直链或配置地址' })
      .layoutWeight(7)
      .height(46)
      .fontSize(14)
      .fontColor('#FFFFFF')
      .placeholderColor('#5C5C68')
      .backgroundColor(C_INPUT)
      .borderRadius(12)
      .border({ width: 1, color: '#20212A' })
      .padding({ left: 14, right: 14 })
      .onChange((v: string) => {
        this.liveAddr = v;
        this.suggestLiveName();
      })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 背景：暗底 + 左上角一层暖光，和首页 / 收藏 / 历史同一套
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#1F1A1208', 0.0], ['#0C08090B', 0.45], ['#08090B', 1.0]]
        })

      Row() {
        SideNav({ active: 5 })
        Column() {
        this.pageHeader()

        Scroll() {
          Column() {
            // ---------- 点播源 / 直播源：左右并列，各占半屏 ----------
            Row() {
              // ---------- 左：点播源 ----------
              Column() {
                this.section('点播源 · 影视 / 剧集（站点 + 解析）')

                Row() {
                  this.vodNameBox()
                  Row().width(10)
                  this.vodAddrBox()
                }
                .width('100%')

                // 操作按钮另起一行：占满整行宽度后靠右对齐，挤在第一行会把地址框压没
                Row() {
                  Button('粘贴')
                    .height(46).fontSize(14).fontColor('#FFFFFF').backgroundColor('#232530')
                    .borderRadius(12)
                    .onClick(() => { this.pasteInto(false); })
                  Button(this.busy === 'vod' ? '载入中…' : '载入')
                    .height(46).fontSize(14).fontColor('#150A04').backgroundColor('#FF8A3D')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.loadVod(); })
                  Button('清空')
                    .height(46).fontSize(14).fontColor('#B9B9C4').backgroundColor('#232530')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.clearVodInput(); })
                  Button('手机推送')
                    .height(46).fontSize(13).fontColor('#8ED0FF').backgroundColor('#152B33')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.openPush('vod'); })
                }
                .width('100%')
                .justifyContent(FlexAlign.End)
                .margin({ top: 10 })

                Text('当前：' + (this.configName.length > 0 ? this.configName : '未命名')
                  + (this.repoName ? ' · 仓库「' + this.repoName + '」' : '')
                  + ' · 可用站点 ' + this.usableCount + ' 个'
                  + ' · 解析 ' + this.parseCount + ' 个'
                  + (this.dropped > 0 ? ' · 已过滤 ' + this.dropped + ' 个 spider 站点（不显示）' : ''))
                  .fontSize(13)
                  .fontColor('#8E8E9A')
                  .width('100%')
                  .margin({ top: 8 })

                if (this.errMsg) {
                  Text('存储提示：' + this.errMsg)
                    .fontSize(12).fontColor('#FF9A9A').width('100%').margin({ top: 6 })
                }
              }
              .layoutWeight(1)
              .padding({ left: 20, right: 20, top: 6, bottom: 18 })
              .margin({ right: 8 })
              .backgroundColor(C_CARD)
              .borderRadius(20)
              .border({ width: 1, color: C_LINE })

              // ---------- 右：直播源 ----------
              Column() {
                this.section('直播源 · 电视频道（lives）')

                Row() {
                  this.liveNameBox()
                  Row().width(10)
                  this.liveAddrBox()
                }
                .width('100%')

                // 操作按钮另起一行：「跟随点播源」贴左，其余按钮靠右
                Row() {
                  if (this.liveOwn) {
                    Button('跟随点播源')
                      .height(46).fontSize(14).fontColor('#B9B9C4').backgroundColor('#232530')
                      .borderRadius(12)
                      .onClick(() => { this.backToVodLive(); })
                  }
                  Blank()
                  Button('粘贴')
                    .height(46).fontSize(14).fontColor('#FFFFFF').backgroundColor('#232530')
                    .borderRadius(12)
                    .onClick(() => { this.pasteInto(true); })
                  Button(this.busy === 'live' ? '载入中…' : '载入')
                    .height(46).fontSize(14).fontColor('#150A04').backgroundColor('#FF8A3D')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.loadLiveSrc(); })
                  Button('清空')
                    .height(46).fontSize(14).fontColor('#B9B9C4').backgroundColor('#232530')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.clearLiveInput(); })
                  Button('手机推送')
                    .height(46).fontSize(13).fontColor('#8ED0FF').backgroundColor('#152B33')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.openPush('live'); })
                }
                .width('100%')
                .margin({ top: 10 })

                // 状态行独占一行；源名清单另开一行，别让它贴着「当前：…」把这句话挤成两截。
                Text(this.liveOwn
                  ? '当前：独立直播源「' + (this.liveName.length > 0 ? this.liveName : '未命名')
                    + '」· 直播列表 ' + this.lives.length + ' 个'
                  : '当前：跟随点播源「' + (this.configName.length > 0 ? this.configName : '未命名')
                    + '」· 直播列表 ' + this.lives.length + ' 个')
                  .fontSize(13)
                  .fontColor('#8E8E9A')
                  .width('100%')
                  .margin({ top: 6 })

                if (this.lives.length > 0) {
                  Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
                    ForEach(this.lives, (l: LiveCfg, idx: number) => {
                      Text(l.name + (LiveSrcProbe.isBad(l.url) ? ' · 空' : ''))
                        .fontSize(12.5)
                        .fontColor(LiveSrcProbe.isBad(l.url) ? '#6b6b6b' : '#cccccc')
                        .backgroundColor(LiveSrcProbe.isBad(l.url) ? '#101116' : '#1A1B22')
                        .borderRadius(8)
                        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                        .margin({ right: 8, top: 6 })
                    }, (l: LiveCfg, idx: number) => l.name + String(idx))
                  }
                  .width('100%')
                  .margin({ top: 2 })
                }
              }
              .layoutWeight(1)
              .padding({ left: 20, right: 20, top: 6, bottom: 18 })
              .margin({ left: 8 })
              .backgroundColor(C_CARD)
              .borderRadius(20)
              .border({ width: 1, color: C_LINE })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .margin({ top: 14 })

            // ---------- 家长锁 / 豆瓣账号：左右并列，各占半屏 ----------
            Row() {
              // ---------- 左：家长锁 4 位 PIN ----------
              Column() {
                this.section('家长锁 · 4 位 PIN')

                Row() {
                  TextInput({ text: this.pinText, placeholder: '4 位数字' })
                    .width(190).height(44).fontSize(15)
                    .fontColor('#FFFFFF').placeholderColor('#5C5C68')
                    .backgroundColor('#14151C').borderRadius(12)
                    // 数字键盘 + 圆点掩码：PIN 不明文显示
                    .type(InputType.NUMBER_PASSWORD)
                    .showPasswordIcon(false)
                    .enableAutoFill(false)
                    .inputFilter('[0-9]')
                    .maxLength(4)
                    .onChange((v: string) => { this.pinText = v; })
                  Button('设置 / 修改')
                    .height(44).fontSize(14).fontColor('#150A04')
                    .backgroundColor('#FF8A3D').borderRadius(12)
                    .margin({ left: 12 })
                    .onClick(() => { this.savePin(); })
                  Button('清除 PIN')
                    .height(44).fontSize(14).fontColor('#B9B9C4')
                    .backgroundColor('#232530').borderRadius(12)
                    .margin({ left: 12 })
                    .onClick(() => { this.askClearPin(); })
                  Text(this.pinHas ? '● 已设置' : '○ 未设置')
                    .fontSize(14).fontColor(this.pinHas ? '#7FD88A' : '#7E7E8A')
                    .margin({ left: 16 })
                }
                .width('100%')

                if (this.pinMsg) {
                  Text(this.pinMsg).fontSize(13).fontColor('#7FD88A').width('100%').margin({ top: 6 })
                }
              }
              .layoutWeight(1)
              .padding({ left: 20, right: 20, top: 6, bottom: 18 })
              .margin({ right: 8 })
              .backgroundColor(C_CARD)
              .borderRadius(20)
              .border({ width: 1, color: C_LINE })

              // ---------- 右：豆瓣账号（可选） ----------
              Column() {
                this.section('豆瓣账号（可选）· 提高抓取配额')

                TextInput({ text: this.doubanText, placeholder: '粘贴 Cookie（含 dbcl2=…）' })
                  .width('100%').height(46).fontSize(14)
                  .fontColor('#FFFFFF').placeholderColor('#5C5C68')
                  .backgroundColor('#14151C').borderRadius(12)
                  .onChange((v: string) => { this.doubanText = v; })

                Row() {
                  Button('粘贴')
                    .height(42).fontSize(14).fontColor('#FFFFFF').backgroundColor('#232530')
                    .borderRadius(12)
                    .onClick(() => { this.pasteCookie(); })
                  Button('手机推送')
                    .height(42).fontSize(13).fontColor('#8ED0FF').backgroundColor('#152B33')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.openPush('cookie'); })
                  Button(this.doubanBusy ? '验证中…' : '保存并验证')
                    .height(42).fontSize(14).fontColor('#150A04').backgroundColor('#FF8A3D')
                    .borderRadius(12).margin({ left: 10 })
                    .onClick(() => { this.saveCookie(); })
                  if (this.doubanHas) {
                    Button('退出登录')
                      .height(42).fontSize(14).fontColor('#B9B9C4').backgroundColor('#232530')
                      .borderRadius(12).margin({ left: 10 })
                      .onClick(() => { this.clearCookie(); })
                  }
                  Text('● ' + (this.doubanHas ? this.doubanInfo : '未登录'))
                    .fontSize(14).fontColor(this.doubanHas ? '#7FD88A' : '#7E7E8A')
                    .margin({ left: 16 })
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .justifyContent(FlexAlign.End)
                .margin({ top: 10 })

                if (this.doubanMsg) {
                  Text(this.doubanMsg).fontSize(13).fontColor('#7FD88A').width('100%').margin({ top: 6 })
                }
              }
              .layoutWeight(1)
              .padding({ left: 20, right: 20, top: 6, bottom: 18 })
              .margin({ left: 8 })
              .backgroundColor(C_CARD)
              .borderRadius(20)
              .border({ width: 1, color: C_LINE })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .margin({ top: 14 })

            // ---------- 已保存的接口 / 资源站：左右并列 ----------
            Row() {
              // ---------- 左：已保存的接口 + 多仓仓库 ----------
              Column() {
                if (this.saved.length > 0) {
                  this.section('已保存的接口')
                  ForEach(this.saved, (a: SavedApi, idx: number) => {
                    // 名称 + 地址 + 按钮回到同一行：接口名一般不长，信息区让出宽度给按钮
                    Row() {
                      Column() {
                        Row() {
                          Text(a.name)
                            .fontSize(16)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(a.url === this.vodAddr ? '#FF8A3D' : '#E4E4EC')
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                            .constraintSize({ maxWidth: 260 })
                          if (a.url === this.vodAddr) {
                            Text('点播中')
                              .fontSize(11).fontColor('#FF8A3D').backgroundColor('#2A1B0C')
                              .borderRadius(12).padding({ left: 8, right: 8, top: 2, bottom: 2 })
                              .margin({ left: 8 })
                          }
                          if (this.liveOwn && a.url === this.liveAddr) {
                            Text('直播中')
                              .fontSize(11).fontColor('#7FD88A').backgroundColor('#12210F')
                              .borderRadius(12).padding({ left: 8, right: 8, top: 2, bottom: 2 })
                              .margin({ left: 6 })
                          }
                        }
                        Text(BuiltinConfig.isBuiltin(a.url) ? BuiltinConfig.DESC : a.url)
                          .fontSize(11).fontColor('#5C5C68').width('100%')
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .margin({ top: 4 })
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      Text('载入点播')
                        .fontSize(13).fontColor('#FFB077')
                        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                        .backgroundColor('#2A1B0C').borderRadius(9).margin({ left: 10 })
                        .focusable(true)
                        .onClick(() => { this.useSavedAsVod(a); })
                      Text('设为直播')
                        .fontSize(13).fontColor('#7FD88A')
                        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                        .backgroundColor('#12210F').borderRadius(9).margin({ left: 8 })
                        .focusable(true)
                        .onClick(() => { this.useSavedAsLive(a); })
                      // 内置配置改不了名、也删不掉（它不在磁盘地址簿里，删了会立刻回来）
                      if (!BuiltinConfig.isBuiltin(a.url)) {
                        Text('改名')
                          .fontSize(13).fontColor('#8E8E9A')
                          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                          .backgroundColor('#232530').borderRadius(9).margin({ left: 8 })
                          .focusable(true)
                          .onClick(() => { this.openRename(a); })
                        Text('删除')
                          .fontSize(13).fontColor('#FF9A9A')
                          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                          .backgroundColor('#232530').borderRadius(9).margin({ left: 6 })
                          .focusable(true)
                          .onClick(() => { this.delSaved(a); })
                      }
                    }
                    .width('100%')
                    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
                    .backgroundColor(a.url === this.vodAddr ? '#241A0D' : '#14151C')
                    .borderRadius(12)
                    .margin({ bottom: 8 })
                  }, (a: SavedApi, idx: number) => idx + '|' + a.url + '|' + a.name)

                  // 界面上只留一条操作提示；技术原因（spider 运行时）写在代码注释和对话里
                  Text('点播源和直播源各存一份，互不影响：某个接口只有直播能用时，点「设为直播」即可。')
                    .fontSize(13).fontColor('#7E7E8A').width('100%').margin({ top: 10 })
                }

                // ---------- 多仓仓库：和接口同属「来源」，跟在左列 ----------
                if (this.rows.length > 0) {
                  Row() {
                    Text('多仓仓库（共 ' + this.rows.length + ' 个 · 载入后作用在点播源）')
                      .fontSize(16).fontColor('#FF8A3D').fontWeight(FontWeight.Bold)
                      .layoutWeight(1)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Button(this.scanning ? '扫描中…' : '扫描全部')
                      .height(36).fontSize(14)
                      .backgroundColor(this.scanning ? '#232530' : '#FF8A3D')
                      .fontColor(this.scanning ? '#FFFFFF' : '#150A04')
                      .onClick(() => { this.scanAll(); })
                  }
                  .width('100%')
                  .margin({ top: 20, bottom: 10 })

                  if (this.scanTip) {
                    Text(this.scanTip).fontSize(13).fontColor('#8E8E9A').width('100%').margin({ bottom: 10 })
                  }

                  ForEach(this.rows, (r: RepoScanResult) => {
                    Row() {
                      Text(r.name).fontSize(15).fontColor('#E4E4EC').layoutWeight(1).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(r.msg)
                        .fontSize(12)
                        .fontColor(r.ok ? '#7FD88A' : (r.msg === '未扫描' ? '#7E7E8A' : '#FF9A9A'))
                        .margin({ right: 12 })
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.busy === 'vod' ? '…' : '加载').fontSize(14).fontColor('#FF8A3D')
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
                    .backgroundColor(r.ok ? '#12200F' : '#14151C')
                    .borderRadius(12)
                    .margin({ bottom: 8 })
                    .focusable(true)
                    .onClick(() => { this.useRepoUrl(r.name, r.url); })
                  }, (r: RepoScanResult, idx: number) => idx + '|' + r.url)
                }
              }
              .layoutWeight(1)
              .padding({ left: 20, right: 20, top: 6, bottom: 18 })
              .margin({ right: 8 })
              .backgroundColor(C_CARD)
              .borderRadius(20)
              .border({ width: 1, color: C_LINE })
              .alignItems(HorizontalAlign.Start)

              // ---------- 右：资源站（只列可用） ----------
              Column() {
                if (this.sites.length > 0) {
                  this.section('资源站（选一个作为当前点播站点）')
                  ForEach(this.sites, (s: SiteCfg) => {
                    Row() {
                      // 切换和删除做成平级点击区：ArkTS 的 ClickEvent 没有
                      // stopPropagation，嵌套的话点删除会连带触发整行的切换
                      Row() {
                        Text(s.name).fontSize(15)
                          .fontColor(s.key === this.curKey ? '#FF8A3D' : '#E4E4EC')
                          .layoutWeight(1).maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text('type ' + s.type).fontSize(12).fontColor('#5C5C68').margin({ right: 8 })
                        Text(s.key === this.curKey ? '当前' : '切换')
                          .fontSize(12)
                          .fontColor(s.key === this.curKey ? '#FF8A3D' : '#7FD88A')
                      }
                      .layoutWeight(1)
                      .focusable(true)
                      .onClick(() => { this.useSite(s); })

                      // 只有用户自己收进 Default 的站点能删；预设的暴风资源没有这个按钮
                      if (this.canRemoveSite(s)) {
                        Text('删除')
                          .fontSize(12).fontColor('#FF9A9A')
                          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                          .backgroundColor('#2A1719').borderRadius(9)
                          .margin({ left: 8 })
                          .focusable(true)
                          .onClick(() => { this.delMySite(s); })
                      }
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
                    .backgroundColor(s.key === this.curKey ? '#241A0D' : '#14151C')
                    .borderRadius(12)
                    .margin({ bottom: 8 })
                  }, (s: SiteCfg, idx: number) => idx + '|' + s.key)
                } else {
                  Text('这份配置里没有可用的采集站，换一个接口，'
                    + '或到「直播源」单独挂一份能用的直播地址。')
                    .fontSize(13).fontColor('#E0B341').width('100%').margin({ top: 8 })
                }

              }
              .layoutWeight(1)
              .padding({ left: 20, right: 20, top: 6, bottom: 18 })
              .margin({ left: 8 })
              .backgroundColor(C_CARD)
              .borderRadius(20)
              .border({ width: 1, color: C_LINE })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .margin({ top: 14 })

          }
          .width('100%')
          .padding({ left: 44, right: 36, bottom: 34 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')

      // ---------- 清除 PIN 前先验证 ----------
      if (this.pinClearOpen) {
        Column() {
          Column() {
            Text('输入 PIN 以清除').fontSize(20).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
            TextInput({ text: this.pinClearInput, placeholder: '4 位数字' })
              .width('100%').height(48).fontSize(18)
              .fontColor('#FFFFFF').placeholderColor('#5C5C68')
              .backgroundColor('#232530').borderRadius(12)
              .type(InputType.NUMBER_PASSWORD)
              .showPasswordIcon(false)
              .enableAutoFill(false)
              .inputFilter('[0-9]')
              .maxLength(4)
              .margin({ top: 16 })
              .defaultFocus(true)
              .onChange((v: string) => { this.pinClearInput = v; })
            if (this.pinClearErr.length > 0) {
              Text(this.pinClearErr).fontSize(13).fontColor('#FF9A9A').width('100%').margin({ top: 8 })
            }
            Row() {
              Button('取消')
                .fontSize(14).height(40).backgroundColor('#232530').fontColor('#FFFFFF')
                .onClick(() => { this.pinClearOpen = false; })
              Button('确认清除')
                .fontSize(14).height(40).backgroundColor('#FF8A3D').fontColor('#150A04')
                .margin({ left: 12 })
                .onClick(() => { this.doClearPin(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: 16 })
          }
          .width(400)
          .backgroundColor('#12131A')
          .borderRadius(20)
          .padding(24)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
      }

      // ---------- 改名浮层 ----------
      if (this.renameOpen) {
        Column() {
          Column() {
            Text('给接口改名').fontSize(20).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)
            Text(this.renameUrl)
              .fontSize(11).fontColor('#5C5C68').width('100%').margin({ top: 6 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            TextInput({ text: this.renameText, placeholder: this.renamePlaceholder })
              .width('100%')
              .height(48)
              .fontSize(15)
              .fontColor('#FFFFFF')
              .placeholderColor('#5C5C68')
              .backgroundColor('#232530')
              .borderRadius(12)
              .margin({ top: 16 })
              .defaultFocus(true)
              .onChange((v: string) => { this.renameText = v; })
            Row() {
              Button('取消')
                .fontSize(14).height(40).backgroundColor('#232530').fontColor('#FFFFFF')
                .onClick(() => { this.renameOpen = false; })
              Button('保存')
                .fontSize(14).height(40).backgroundColor('#FF8A3D').fontColor('#150A04')
                .margin({ left: 12 })
                .onClick(() => { this.doRename(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: 16 })
          }
          .width('46%')
          .backgroundColor('#12131A')
          .borderRadius(20)
          .padding(24)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
      }

      // ---------- 手机推送浮层 ----------
      if (this.pushOpen) {
        Column() {
          Column() {
            Text(this.pushTarget === 'live' ? '手机推送 · 直播源'
              : (this.pushTarget === 'cookie' ? '手机推送 · 豆瓣 Cookie' : '手机推送 · 点播源'))
              .fontSize(19).fontColor('#FFFFFF').fontWeight(FontWeight.Bold)

            if (this.pushErr.length > 0) {
              Text(this.pushErr).fontSize(14).fontColor('#FF9A9A')
                .width('100%').margin({ top: 14 })
            } else if (this.pushUrl.length === 0) {
              Row() {
                LoadingProgress().width(26).height(26).color('#FF8A3D')
                Text('正在启动本地服务…').fontSize(14).fontColor('#999999').margin({ left: 10 })
              }
              .margin({ top: 18 })
            } else {
              Text(this.pushTarget === 'cookie'
                ? '手机连同一个 Wi-Fi → 扫码 → 粘贴 Cookie → 点推送'
                : '手机连同一个 Wi-Fi → 扫码 → 粘贴地址 → 点推送')
                .fontSize(13).fontColor('#8E8E9A').margin({ top: 8 })
              QrView({ content: this.pushUrl, box: 240 })
                .margin({ top: 12 })
              Text(this.pushMsg.length > 0
                ? this.pushMsg
                : '这个服务只在电视上开着 App 时有效')
                .fontSize(13)
                .fontColor(this.pushMsg.length > 0 ? '#7fd88a' : '#666666')
                .margin({ top: 12 })
              if (this.pushDiag.length > 0) {
                Text(this.pushDiag)
                  .fontSize(11).fontColor('#7E7E8A').margin({ top: 6 })
                  .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }

            Button('关闭')
              .fontSize(14).height(38).backgroundColor('#232530').fontColor('#FFFFFF')
              .margin({ top: 16 })
              .onClick(() => { this.closePush(); })
          }
          .width(360)
          .backgroundColor('#12131A')
          .borderRadius(20)
          .padding(20)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}
