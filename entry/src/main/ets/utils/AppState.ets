import { TvBoxConfig, SiteCfg, RepoCfg, LiveCfg } from '../model/TvBoxModels';

/**
 * 全局运行态。
 *
 * 点播与直播是**两份可以来自不同配置地址**的源：
 *   - 点播：configUrl / configName / cfg（sites + parses）
 *   - 直播：liveUrl / liveName / lives
 * 直播源默认「跟点播源同一份配置」（liveUrl 为空时 lives 取 cfg.lives）；
 * 用户在设置里单独载入过直播地址，就用自己那份。这样某个接口点播废了、
 * 但里面的直播能用（或者反过来）时，两边各自换，不会互相拖累。
 */
export class AppState {
  static configUrl: string = '';
  // 当前接口的自定义名字（用户自己起，或从域名推出来），用于区分多份配置
  static configName: string = '';
  static repoName: string = '';
  static cfg: TvBoxConfig = new TvBoxConfig();
  // 多仓的仓库列表：解析结果直接放内存，页面不再经过"落盘 → 读回 → 再解析"，
  // 少两道可能静默失败的环节（文件写入失败时列表会空白）。
  static repos: RepoCfg[] = [];
  static currentSite: SiteCfg | null = null;
  static loaded: boolean = false;
  static err: string = '';

  // ---- 直播源（可与点播源不同地址） ----
  static liveUrl: string = '';
  static liveName: string = '';
  static lives: LiveCfg[] = [];

  /**
   * 可直接请求的采集站（type 0 / 1，api 是 http）。
   *
   * type 3 / 4 一律排除，且**不做放宽兜底**：老版本在"一个可用站点都没有"时
   * 会把所有 http 站点都放出来，结果设置页里列一堆类型 3 的站点、点哪一个都报
   * spider 不可用。现在只列真能跑的，过滤掉多少由设置页明确告知。
   */
  static usableSites(): SiteCfg[] {
    const out: SiteCfg[] = [];
    for (const s of AppState.cfg.sites) {
      if (AppState.isUsable(s)) {
        out.push(s);
      }
    }
    return out;
  }

  /** 被过滤掉的站点数（type 3/4 或 api 指向脚本），设置页用来给个交代 */
  static droppedSites(): number {
    let n: number = 0;
    for (const s of AppState.cfg.sites) {
      if (!AppState.isUsable(s)) {
        n++;
      }
    }
    return n;
  }

  /** api 是否是可直接请求的 http 接口（排除指向 js/jar/py 脚本的） */
  static isHttpApi(s: SiteCfg): boolean {
    const low = (s.api ?? '').trim().toLowerCase();
    if (!low.startsWith('http')) {
      // csp_xxx 这类是 spider 类名，必须 jar 才能跑
      return false;
    }
    if (low.endsWith('.js') || low.endsWith('.jar') || low.endsWith('.py')) {
      return false;
    }
    return true;
  }

  static isUsable(s: SiteCfg): boolean {
    if (!AppState.isHttpApi(s)) {
      return false;
    }
    // type 0 = XML、1 = JSON 采集接口；3/4 需要 spider 运行时（jar 或 JS 引擎），
    // 鸿蒙 NEXT 没有 JVM 和 drpy 运行环境，一律不可用（按需求直接过滤、不展示）。
    return s.type === 0 || s.type === 1;
  }

  static findSite(key: string): SiteCfg | null {
    for (const s of AppState.cfg.sites) {
      if (s.key === key) {
        return s;
      }
    }
    return null;
  }

  /** 直播源是否用了独立地址（而不是跟点播源同一份配置） */
  static hasOwnLive(): boolean {
    const u: string = (AppState.liveUrl ?? '').trim();
    return u.length > 0 && u !== AppState.configUrl;
  }

  static reset(): void {
    AppState.configUrl = '';
    AppState.configName = '';
    AppState.repoName = '';
    AppState.cfg = new TvBoxConfig();
    AppState.repos = [];
    AppState.currentSite = null;
    AppState.liveUrl = '';
    AppState.liveName = '';
    AppState.lives = [];
    AppState.loaded = false;
    AppState.err = '';
  }
}
