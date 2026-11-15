import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { FileStore } from './FileStore';
import { ConfigParser } from './ConfigParser';
import { AppState } from './AppState';
import { HttpUtil } from './HttpUtil';
import { ConfigDecoder } from './ConfigDecoder';
import { ApiStore, SavedApi } from './ApiStore';
import { BuiltinConfig } from './BuiltinConfig';
import { MySitesStore } from './MySitesStore';
import { TvBoxConfig, SiteCfg, RepoCfg, RepoScanResult, LiveCfg } from '../model/TvBoxModels';

/**
 * 配置仓库：负责"配置地址 → 拉取 → 落盘 → 应用"的完整链路。
 * 同时管理当前站点与地址的持久化。
 */
const F_CFG: string = 'tvbox_cfg.json';
const F_SET: string = 'tvbox_settings.json';
const F_REPO: string = 'tvbox_repo.json';
/** 独立直播源的配置原文缓存（跟点播源分开存，互不覆盖） */
const F_LIVE: string = 'tvbox_live.json';

interface Settings {
  address: string;
  siteKey: string;
  repoName: string;
  // 接口名字（老版本存的文件没有这个字段）
  apiName?: string;
  // 独立直播源（老版本没有这两个字段）
  liveAddress?: string;
  liveName?: string;
}

export class ConfigStore {
  // 启动时调用：有缓存先上屏，再静默刷新
  static async init(ctx: common.Context): Promise<void> {
    if (AppState.loaded) {
      return;
    }
    // 如果打包时往 resources/rawfile/live_builtin.m3u 放了一份频道表，这里读进内存。
    // 在 init 里读是因为：只有这里有 context，而 LiveApi 是纯静态类拿不到资源管理器；
    // 也放不进 EntryAbility —— 它是 .ts，ArkTS 不允许 .ts 反引 .ets。
    // 开源版默认不带这个文件，读失败是正常情况，直播页就是空列表。
    try {
      const raw: Uint8Array = ctx.resourceManager.getRawFileContentSync(BuiltinConfig.LIVE_RAWFILE);
      BuiltinConfig.setLiveText(util.TextDecoder.create('utf-8').decodeToString(raw));
    } catch (e) {
      // 没放频道表：不提示，直播页显示空列表
    }
    // 先把自己收集的站点灌进内置 Default，下面取 BuiltinConfig.text() 时才带得上
    MySitesStore.init(ctx);
    const setText = FileStore.readText(ctx, F_SET);
    let st: Settings = { address: '', siteKey: '', repoName: '' };
    if (setText) {
      try {
        st = JSON.parse(setText) as Settings;
      } catch (e) {
        st = { address: '', siteKey: '', repoName: '' };
      }
    }
    AppState.configUrl = st.address ?? '';
    AppState.repoName = st.repoName ?? '';
    // 直播源先还原「地址/名字」，这样后面的 applyText 才知道该不该用配置自带的 lives
    AppState.liveUrl = (st.liveAddress ?? '').trim();
    AppState.liveName = (st.liveName ?? '').trim();
    // 接口名字：优先用存下来的，其次查地址簿，最后从域名推一个
    const savedName: string = (st.apiName ?? '').trim();
    if (savedName.length > 0) {
      AppState.configName = savedName;
    } else if (AppState.configUrl.length > 0) {
      const fromBook: string = ApiStore.nameOf(ctx, AppState.configUrl);
      AppState.configName = fromBook.length > 0 ? fromBook : ApiStore.guessName(AppState.configUrl);
    }
    // 老版本升级上来的地址自动补进地址簿，免得列表里空着
    if (AppState.configUrl.length > 0) {
      ApiStore.save(ctx, AppState.configName, AppState.configUrl);
    }
    if (AppState.liveUrl.length > 0 && AppState.liveName.length === 0) {
      const fromBook: string = ApiStore.nameOf(ctx, AppState.liveUrl);
      AppState.liveName = fromBook.length > 0 ? fromBook : ApiStore.guessName(AppState.liveUrl);
    }
    if (!AppState.configUrl) {
      // 首次启动 / 清空配置后：直接上内置 Default，
      // 免得进去是「还没配置」的白板页，而内置站不花一次网络请求就能出内容
      AppState.configUrl = BuiltinConfig.URL;
      AppState.configName = BuiltinConfig.NAME;
      ApiStore.save(ctx, BuiltinConfig.NAME, BuiltinConfig.URL);
    }

    const cached = FileStore.readText(ctx, F_CFG);
    if (cached) {
      // 内置配置一律以代码里的版本为准：删站 / 换站之后，旧磁盘缓存不能把
      // 已下线的站点带回来。否则 init() 会先拿旧配置上屏、Index 紧接着就
      // loadAll()，等异步 refresh 改成新配置时请求已经发出去了，第一眼仍是失效站点。
      const effective: string = BuiltinConfig.isBuiltin(AppState.configUrl)
        ? BuiltinConfig.text() : cached;
      ConfigStore.applyText(effective);
      ConfigStore.pickSite(st.siteKey);
      // 旧设置里记的站点 key 在新配置中已不存在（例如被删掉的 ffzy），
      // pickSite 已回落到第一个可用站点，把设置文件里的旧 key 一并洗掉。
      if (AppState.currentSite !== null && AppState.currentSite.key !== (st.siteKey ?? '')) {
        ConfigStore.writeSettings(ctx, AppState.currentSite.key, AppState.repoName);
      }
      // 顺手恢复多仓仓库列表（有缓存时不必等联网）
      ConfigStore.loadRepoCache(ctx);
      ConfigStore.restoreLive(ctx);
      AppState.loaded = true;
      if (effective !== cached) {
        FileStore.writeText(ctx, F_CFG, effective);
      }
      ConfigStore.refresh(ctx).catch(() => {});
      return;
    }

    try {
      await ConfigStore.refresh(ctx);
    } catch (e) {
      AppState.err = (e as Error).message;
    }
    ConfigStore.pickSite(st.siteKey);
    ConfigStore.restoreLive(ctx);
    AppState.loaded = true;
  }

  /**
   * 还原直播源。
   * 没单独设直播地址时，直播就是点播配置里的 lives（老行为）；
   * 设了独立地址就先读它自己的缓存上屏，再后台静默刷新一次。
   */
  private static restoreLive(ctx: common.Context): void {
    if (!AppState.hasOwnLive()) {
      AppState.lives = AppState.cfg.lives;
      return;
    }
    const cached: string = FileStore.readText(ctx, F_LIVE);
    if (cached) {
      try {
        const c = ConfigParser.parse(cached);
        if (!c.isRepo) {
          AppState.lives = c.lives;
        }
      } catch (e) {
        // 缓存坏了先空着，下面的 refreshLive 会补
      }
    }
    ConfigStore.refreshLive(ctx).catch(() => {});
  }

  /** 从磁盘恢复多仓仓库列表到内存 */
  private static loadRepoCache(ctx: common.Context): void {
    const txt = FileStore.readText(ctx, F_REPO);
    if (!txt) {
      return;
    }
    try {
      const rc = ConfigParser.parse(txt);
      if (rc.isRepo) {
        AppState.repos = rc.repos;
      }
    } catch (e) {
      // 缓存损坏忽略，等下次导入覆盖
    }
  }

  // 重新拉取配置地址（多仓会只返回仓库列表，等用户选）
  static async refresh(ctx: common.Context): Promise<TvBoxConfig> {
    const addr = AppState.configUrl;
    if (!addr) {
      return new TvBoxConfig();
    }
    const text = await ConfigStore.fetchConfigText(addr);
    ConfigStore.assertConfigText(text);
    const cfg = ConfigParser.parse(text);
    if (cfg.isRepo) {
      // 内存优先：页面直接读 AppState.repos，不再依赖"写盘再读回"
      AppState.repos = cfg.repos;
      if (!FileStore.writeText(ctx, F_REPO, text)) {
        AppState.err = '仓库列表缓存写入失败（本次仍可使用）';
      }
      return cfg;
    }
    FileStore.writeText(ctx, F_CFG, text);
    ConfigStore.applyText(text);
    return cfg;
  }

  // 导入/更新配置地址。name 为空时：先用地址簿里记过的名字，再退回域名
  static async importAddress(ctx: common.Context, address: string, name: string): Promise<string> {
    const addr = address.trim();
    if (!addr) {
      return '请先填写配置地址';
    }
    const typed: string = (name ?? '').trim();
    const fromBook: string = ApiStore.nameOf(ctx, addr);
    const finalName: string = typed.length > 0 ? typed
      : (fromBook.length > 0 ? fromBook
        : (BuiltinConfig.isBuiltin(addr) ? BuiltinConfig.NAME : ApiStore.guessName(addr)));
    const text = await ConfigStore.fetchConfigText(addr);
    ConfigStore.assertConfigText(text);
    const cfg = ConfigParser.parse(text);
    AppState.configUrl = addr;
    AppState.configName = finalName;
    // 拉取成功了才记进地址簿，失败的不留在列表里
    ApiStore.save(ctx, finalName, addr);
    if (cfg.isRepo) {
      // 关键：解析结果直接进内存，页面立即能渲染，避免"文件写没写成功"影响显示
      AppState.repos = cfg.repos;
      FileStore.writeText(ctx, F_REPO, text);
      ConfigStore.writeSettings(ctx, AppState.currentSite ? AppState.currentSite.key : '', '');
      return '这是多仓接口，共 ' + cfg.repos.length + ' 个仓库，请在下方选择';
    }
    AppState.repos = [];
    FileStore.writeText(ctx, F_CFG, text);
    ConfigStore.applyText(text);
    const site = AppState.currentSite;
    ConfigStore.writeSettings(ctx, site ? site.key : '', '');
    let usable: number = 0;
    for (const s of cfg.sites) {
      if (AppState.isUsable(s)) {
        usable++;
      }
    }
    if (cfg.sites.length === 0 && cfg.lives.length === 0 && cfg.parses.length === 0) {
      return '导入完成，但解析出 0 个站点：这个地址可能不是配置 JSON（而是网页/跳转页）';
    }
    if (usable === 0 && cfg.sites.length > 0) {
      return '导入成功：站点 ' + cfg.sites.length + ' 个全部是 spider / JS 型（type 3），'
        + '需要 Android 的 spider 引擎，鸿蒙跑不了，已全部过滤、不再列出'
        + (cfg.lives.length > 0 ? '；但这份配置里的直播源 ' + cfg.lives.length + ' 个仍可用' : '');
    }
    return '导入成功：可用站点 ' + usable + ' 个'
      + (cfg.sites.length > usable ? '（另有 ' + (cfg.sites.length - usable) + ' 个 spider 站点已过滤）' : '')
      + '、直播源 ' + cfg.lives.length + ' 个、解析 ' + cfg.parses.length + ' 个';
  }

  // ---------- 直播源（可与点播源不同地址） ----------

  /** 直链 m3u / txt 直播源合成一条 lives 条目 */
  private static playlistLive(name: string, url: string): LiveCfg {
    const l = new LiveCfg();
    l.name = name.length > 0 ? name : '直播源';
    l.type = 0;
    l.url = url;
    return l;
  }

  /** 直链直播源落盘时包成最小配置，重启后 restoreLive 能照常解析 */
  private static wrapPlaylist(name: string, url: string): string {
    return '{"lives":[{"name":' + JSON.stringify(name.length > 0 ? name : '直播源')
      + ',"type":0,"url":' + JSON.stringify(url) + '}]}';
  }

  /**
   * 判断拉到的东西是「配置 JSON」还是「直链播放列表（m3u / txt）」。
   * 配置里可能带 // 注释，所以不靠首字符判断，而是真解析一次：
   * 解析得动且确实带 sites / lives / parses / urls 的，当配置；否则当播放列表。
   */
  private static tryParseConfig(text: string): TvBoxConfig | null {
    let cfg: TvBoxConfig | null = null;
    try {
      cfg = ConfigParser.parse(text);
    } catch (e) {
      return null;
    }
    if (cfg.isRepo || cfg.lives.length > 0 || cfg.sites.length > 0 || cfg.parses.length > 0) {
      return cfg;
    }
    return null;
  }

  /**
   * 静默刷新独立直播源。启动时用，不打扰用户，失败就保持缓存。
   * 直播源地址等于点播地址 / 没设时，直接复用点播配置里的 lives。
   */
  static async refreshLive(ctx: common.Context): Promise<void> {
    if (!AppState.hasOwnLive()) {
      AppState.lives = AppState.cfg.lives;
      return;
    }
    const text = await ConfigStore.fetchConfigText(AppState.liveUrl);
    const cfg: TvBoxConfig | null = ConfigStore.tryParseConfig(text);
    if (cfg !== null && !cfg.isRepo) {
      AppState.lives = cfg.lives;
      FileStore.writeText(ctx, F_LIVE, text);
      return;
    }
    // 直链 m3u / txt：保持合成的那一条
    const one: LiveCfg = ConfigStore.playlistLive(AppState.liveName, AppState.liveUrl);
    AppState.lives = [one];
    FileStore.writeText(ctx, F_LIVE, ConfigStore.wrapPlaylist(AppState.liveName, AppState.liveUrl));
  }

  /**
   * 用户主动载入一个直播源地址。
   * 跟点播源完全解耦：这里只取 lives，不动 sites / currentSite，
   * 所以「点播废了但直播能用」的接口可以直接挂过来当直播源。
   * 既接受带 lives 的配置 JSON，也接受 m3u / txt 直链。
   */
  static async loadLive(ctx: common.Context, address: string, name: string): Promise<string> {
    const addr: string = (address ?? '').trim();
    if (!addr) {
      return '请先填写直播源地址';
    }
    const typed: string = (name ?? '').trim();
    const fromBook: string = ApiStore.nameOf(ctx, addr);
    const finalName: string = typed.length > 0 ? typed
      : (fromBook.length > 0 ? fromBook : ApiStore.guessName(addr));
    const text = await ConfigStore.fetchConfigText(addr);
    const head: string = text.trim().substring(0, 60).toLowerCase();
    if (head.startsWith('<!doctype') || head.startsWith('<html')) {
      return '这个地址返回的是网页（HTML），不是配置也不是播放列表。'
        + '请填「带 lives 字段的 JSON 配置」或「.m3u / .txt 直播列表」的直链';
    }
    const cfg: TvBoxConfig | null = ConfigStore.tryParseConfig(text);
    if (cfg !== null && cfg.isRepo) {
      return '这个地址是多仓接口（只给仓库列表），请填具体某个仓库里的配置地址';
    }
    AppState.liveUrl = addr;
    AppState.liveName = finalName;
    let count: number = 0;
    if (cfg !== null) {
      AppState.lives = cfg.lives;
      count = cfg.lives.length;
      FileStore.writeText(ctx, F_LIVE, text);
      ApiStore.save(ctx, finalName, addr);
      const site = AppState.currentSite;
      ConfigStore.writeSettings(ctx, site ? site.key : '', AppState.repoName);
      if (count === 0) {
        return '「' + finalName + '」里没有 lives 字段，直播页仍然无源可放'
          + (cfg.sites.length > 0 ? '（这份配置只有 ' + cfg.sites.length + ' 个点播站点，要用点播请在上面载入）' : '');
      }
      return '直播源已切换到「' + finalName + '」：' + count + ' 个直播列表';
    }
    // 直链播放列表
    const one: LiveCfg = ConfigStore.playlistLive(finalName, addr);
    AppState.lives = [one];
    FileStore.writeText(ctx, F_LIVE, ConfigStore.wrapPlaylist(finalName, addr));
    ApiStore.save(ctx, finalName, addr);
    const site = AppState.currentSite;
    ConfigStore.writeSettings(ctx, site ? site.key : '', AppState.repoName);
    return '直播源已设为「' + finalName + '」（直链播放列表，共 1 个列表）';
  }

  /** 清掉独立直播源，回到「跟点播源同一份配置」 */
  static clearLive(ctx: common.Context): void {
    AppState.liveUrl = '';
    AppState.liveName = '';
    AppState.lives = AppState.cfg.lives;
    FileStore.remove(ctx, F_LIVE);
    const site = AppState.currentSite;
    ConfigStore.writeSettings(ctx, site ? site.key : '', AppState.repoName);
  }

  // 从多仓里加载某个仓库
  static async importRepo(ctx: common.Context, repo: RepoCfg): Promise<string> {
    const text = await ConfigStore.fetchConfigText(repo.url);
    ConfigStore.assertConfigText(text);
    const cfg = ConfigParser.parse(text);
    if (cfg.isRepo && cfg.repos.length > 0) {
      return '「' + repo.name + '」本身还是多仓接口，要先在它里面再选一层，当前版本只支持一层多仓';
    }
    FileStore.writeText(ctx, F_CFG, text);
    ConfigStore.applyText(text);
    AppState.repoName = repo.name;
    const site = AppState.currentSite;
    ConfigStore.writeSettings(ctx, site ? site.key : '', repo.name);
    let usable: number = 0;
    for (const s of cfg.sites) {
      if (AppState.isUsable(s)) {
        usable++;
      }
    }
    if (usable === 0) {
      return '已加载「' + repo.name + '」：站点 ' + cfg.sites.length + ' 个，但没有可用站点'
        + '（全是 spider / JS 型，鸿蒙跑不了），换一个仓库试试';
    }
    return '已加载「' + repo.name + '」：站点 ' + cfg.sites.length + ' 个（可用 ' + usable + ' 个）'
      + (cfg.lives.length > 0 ? '、直播 ' + cfg.lives.length + ' 个' : '') + '';
  }

  /**
   * 扫描单个仓库：真的去拉一次，统计里面有多少可用站点。
   * 多仓动辄十几个仓库，靠手点一个个试太慢，用它一次问清"哪个仓库真能用"。
   * 只做读取与统计，不改动当前配置。
   */
  static async scanOne(repo: RepoCfg): Promise<RepoScanResult> {
    const r = new RepoScanResult();
    r.name = repo.name;
    r.url = repo.url;
    try {
      const text = await ConfigStore.fetchConfigText(repo.url);
      ConfigStore.assertConfigText(text);
      const cfg = ConfigParser.parse(text);
      if (cfg.isRepo) {
        r.isRepo = true;
        r.msg = '嵌套多仓（' + cfg.repos.length + ' 个），需直接填其中一个的地址';
        return r;
      }
      r.sites = cfg.sites.length;
      r.lives = cfg.lives.length;
      let usable: number = 0;
      for (const s of cfg.sites) {
        if (AppState.isUsable(s)) {
          usable++;
        }
      }
      r.usable = usable;
      r.ok = usable > 0;
      if (usable > 0) {
        r.msg = '可用 ' + usable + ' / 站点 ' + r.sites + (r.lives > 0 ? ' · 直播 ' + r.lives : '');
      } else if (r.sites > 0) {
        r.msg = '站点 ' + r.sites + ' 个，全是 spider 型';
      } else {
        r.msg = '没有站点，可能不是配置地址';
      }
    } catch (e) {
      r.ok = false;
      r.msg = (e as Error).message;
    }
    return r;
  }

  // 把配置文本解析进 AppState
  static applyText(text: string): void {
    let cfg: TvBoxConfig;
    try {
      cfg = ConfigParser.parse(text);
    } catch (e) {
      // 旧配置保留，错误留给页面展示
      AppState.err = (e as Error).message;
      return;
    }
    if (cfg.isRepo) {
      return;
    }
    AppState.cfg = cfg;
    // 直播源没单独设过地址时，跟着点播配置走
    if (!AppState.hasOwnLive()) {
      AppState.lives = cfg.lives;
    }
    const usable = AppState.usableSites();
    if (AppState.currentSite === null || !AppState.isUsable(AppState.currentSite)) {
      AppState.currentSite = usable.length > 0 ? usable[0] : null;
    } else {
      // 站点对象可能已被替换，按 key 重新绑定
      const again = AppState.findSite(AppState.currentSite.key);
      AppState.currentSite = again;
      if (again === null && usable.length > 0) {
        AppState.currentSite = usable[0];
      }
    }
  }

  static pickSite(key: string): void {
    const usable = AppState.usableSites();
    if (usable.length === 0) {
      AppState.currentSite = null;
      return;
    }
    for (const s of usable) {
      if (s.key === key) {
        AppState.currentSite = s;
        return;
      }
    }
    AppState.currentSite = usable[0];
  }

  static async setSite(ctx: common.Context, site: SiteCfg): Promise<void> {
    AppState.currentSite = site;
    ConfigStore.writeSettings(ctx, site.key, AppState.repoName);
  }

  static async clearAll(ctx: common.Context): Promise<void> {
    FileStore.remove(ctx, F_CFG);
    FileStore.remove(ctx, F_SET);
    FileStore.remove(ctx, F_REPO);
    FileStore.remove(ctx, F_LIVE);
    AppState.reset();
  }

  // ---------- 接口地址簿 ----------

  static savedApis(ctx: common.Context): SavedApi[] {
    const list: SavedApi[] = ApiStore.list(ctx);
    // 内置 Default 常驻列表：它不占网络、也不会失效，
    // 用户把地址簿删干净之后还能一键切回来
    let hasBuiltin: boolean = false;
    for (const a of list) {
      if (BuiltinConfig.isBuiltin(a.url)) {
        hasBuiltin = true;
        break;
      }
    }
    if (!hasBuiltin) {
      list.push({ name: BuiltinConfig.NAME, url: BuiltinConfig.URL });
    }
    return list;
  }

  /** 给已保存的接口改名；如果改的正是当前接口，同步更新运行态与设置文件 */
  static renameApi(ctx: common.Context, url: string, name: string): void {
    const nm: string = (name ?? '').trim();
    if (nm.length === 0) {
      return;
    }
    ApiStore.rename(ctx, url, nm);
    if (AppState.configUrl === url) {
      AppState.configName = nm;
      const site = AppState.currentSite;
      ConfigStore.writeSettings(ctx, site ? site.key : '', AppState.repoName);
    }
    if (AppState.liveUrl === url) {
      AppState.liveName = nm;
      const site = AppState.currentSite;
      ConfigStore.writeSettings(ctx, site ? site.key : '', AppState.repoName);
    }
  }

  /** 从地址簿移除（不影响当前正在用的配置） */
  static removeApi(ctx: common.Context, url: string): void {
    ApiStore.remove(ctx, url);
  }

  /**
   * 拉配置文本并还原伪装配置：
   * 先双 UA 拉取（浏览器优先、okhttp 兜底），再交给 ConfigDecoder 处理
   * 「图片壳 + Base64」这类伪装格式。返回的一定是可以直接解析的文本。
   */
  private static async fetchConfigText(addr: string): Promise<string> {
    // 内置配置不发请求：直接返回代码里那份 JSON
    if (BuiltinConfig.isBuiltin(addr)) {
      return BuiltinConfig.text();
    }
    const raw: string = await HttpUtil.getConfigText(addr);
    return ConfigDecoder.unwrap(raw);
  }

  /**
   * 提前判断拉回来的内容是不是配置 JSON。
   * 导航页、影视站首页、跳转页都是 HTML，直接交给 JSON.parse 只会得到
   * "Unexpected token <"，用户看不懂，这里给出可执行的提示。
   *
   * 注意：大量真实配置以 // 注释开头（作者声明、更新日志），
   * 必须先跳过注释再判断首字符，否则合法配置会被当成网页拒掉。
   */
  private static assertConfigText(text: string): void {
    const t: string = (text ?? '').trim();
    if (t.length === 0) {
      throw new Error('返回内容为空');
    }
    // 跳过开头空白 + // 行注释 + /* */ 块注释
    let i: number = 0;
    const n: number = t.length;
    while (i < n) {
      const c: string = t.charAt(i);
      if (c === ' ' || c === '\t' || c === '\r' || c === '\n') {
        i++;
        continue;
      }
      if (c === '/' && i + 1 < n && t.charAt(i + 1) === '/') {
        while (i < n && t.charAt(i) !== '\n') {
          i++;
        }
        continue;
      }
      if (c === '/' && i + 1 < n && t.charAt(i + 1) === '*') {
        i += 2;
        while (i + 1 < n && !(t.charAt(i) === '*' && t.charAt(i + 1) === '/')) {
          i++;
        }
        i = Math.min(i + 2, n);
        continue;
      }
      break;
    }
    const body: string = t.substring(i);
    if (body.charAt(0) === '{' || body.charAt(0) === '[') {
      return;
    }
    const head: string = body.substring(0, 15).toLowerCase();
    if (head.startsWith('<!doctype') || head.startsWith('<html') || head.startsWith('<?xml')) {
      throw new Error('这个地址返回的是网页（HTML），不是配置接口。'
        + '正确地址在浏览器打开应直接显示以 { 开头的 JSON（含 sites 字段）；'
        + '导航页/影视站首页这类地址，要到站内「接口配置」处点复制再粘贴。');
    }
    // 二进制内容（图片壳）宽松解码后会有大量替换字符
    const sample: string = body.substring(0, 400);
    let bad: number = 0;
    for (let k = 0; k < sample.length; k++) {
      const code: number = sample.charCodeAt(k);
      if (code === 0xFFFD || code < 0x09) {
        bad++;
      }
    }
    if (bad > 20) {
      throw new Error('这个地址返回的是二进制文件（常见做法是把配置藏在图片里）。'
        + '已支持带「8 位字符 + **」路标的伪装配置，但这份没找到路标或解码失败；'
        + '若配置以 2423 开头，那是 AES 加密格式，当前版本还不支持。');
    }
    throw new Error('返回内容不是 JSON，开头是：' + body.substring(0, 120));
  }

  private static writeSettings(ctx: common.Context, siteKey: string, repoName: string): void {
    const st: Settings = {
      address: AppState.configUrl,
      siteKey: siteKey,
      repoName: repoName,
      apiName: AppState.configName,
      liveAddress: AppState.hasOwnLive() ? AppState.liveUrl : '',
      liveName: AppState.hasOwnLive() ? AppState.liveName : ''
    };
    FileStore.writeText(ctx, F_SET, JSON.stringify(st));
  }
}
