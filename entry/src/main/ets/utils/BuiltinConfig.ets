/**
 * 内置配置「Default」：一个**空的**站点容器，不预置任何内容源。
 *
 * 本工程只做协议解析与播放，不附带、不推荐任何第三方内容接口。
 * 首次启动进设置页填入你自己的配置地址，或把试出来的站点「收进 Default」，
 * 之后地址簿里点 Default 就能直接用。
 *
 * 之所以用 builtin:// 这种伪地址，是为了让它能走完整的「地址簿 → 导入 →
 * 解析 → 落盘」流程，设置页里能和普通地址一样点一下切换；
 * ConfigStore.fetchConfigText 会拦下这个前缀，直接返回 text()，不发网络请求。
 *
 * 直播同理：`builtin://live` 这条地址只在你自己把直播源塞进 Default 时才有内容，
 * 工程里不预置任何频道表（原版曾内置一份日/港/台名单，开源版已剔除）。
 */
export class BuiltinConfig {
  static readonly URL: string = 'builtin://default';
  static readonly NAME: string = 'Default';

  // 地址簿副标题：别让用户以为这是一个能点开的网址
  static readonly DESC: string = '内置空容器 · 自己收集的站点都放这里';

  /**
   * 内置站点的 api，MySitesStore 用它把「Default 自带站」和「用户收集站」区分开。
   *
   * 本工程不预置任何站点，这里留空字符串：规范化后是 ''，任何真实站点都不会命中，
   * 因此 Default 里所有站点都来自用户自己收集，随时可以删。
   */
  static readonly BUILTIN_API: string = '';

  /**
   * 内置直播列表的伪地址与显示名。工程里没有随包频道表，
   * 这里的常量只是让「内置直播」这条链路（设置页展示 → 直播页解析）保持完整。
   */
  static readonly LIVE_URL: string = 'builtin://live';
  static readonly LIVE_NAME: string = '内置直播';

  /**
   * 直播频道表的文件名约定：如果打包时往 resources/rawfile/live_builtin.m3u
   * 放一份自己的频道表，EntryAbility.onCreate 会读进 liveTextCache，
   * liveM3u() 就直接返回它。没放这个文件时读失败，返回空串（直播页就是空列表）。
   */
  static readonly LIVE_RAWFILE: string = 'live_builtin.m3u';

  private static readonly HEAD: string = '{"name":"Default","sites":[';

  /**
   * lives 留空数组：直播源同样不预置。
   * flags 是播放器的解析规则（优酷 / 腾讯 / 爱奇艺 / 芒果），不是内容源，保留。
   */
  private static readonly TAIL: string =
    '],"parses":[],"lives":[],' +
    '"flags":["youku","qq","iqiyi","mgtv"]}';

  /**
   * 用户从别的接口收进来的站点，每个元素是一段已经 JSON.stringify 好的站点对象。
   * 由 MySitesStore.init / toggle 在读写 tvbox_my_sites.json 时同步进来。
   * 放在静态变量里，是为了让 fetchConfigText 这种没有 ctx 参数的调用点
   * （多仓扫描 scanOne 就是）也能拿到最新的 Default 文本。
   */
  private static extras: string[] = [];

  /**
   * rawfile 读进来的直播文本。EntryAbility.onCreate 里通过 setLiveText 灌入。
   * 开源版不随包附带频道表，正常情况下这里一直是空串。
   */
  private static liveTextCache: string = '';

  static setLiveText(text: string): void {
    BuiltinConfig.liveTextCache = text ?? '';
  }

  /** 内置直播列表文本：只可能来自你自己放进 rawfile 的那份频道表 */
  static liveM3u(): string {
    return BuiltinConfig.liveTextCache;
  }

  static isBuiltinLive(url: string): boolean {
    return (url ?? '').trim() === BuiltinConfig.LIVE_URL;
  }

  static setExtras(parts: string[]): void {
    BuiltinConfig.extras = parts;
  }

  static isBuiltin(url: string): boolean {
    return (url ?? '').trim() === BuiltinConfig.URL;
  }

  /** 内置站 + 用户收集的站，拼成一份完整配置文本 */
  static text(): string {
    let body: string = '';
    for (const p of BuiltinConfig.extras) {
      if (p.length > 0) {
        body += (body.length > 0 ? ',' : '') + p;
      }
    }
    return BuiltinConfig.HEAD + body + BuiltinConfig.TAIL;
  }

  /** Default 里现在有没有站点（首页空态用它给提示） */
  static hasSites(): boolean {
    return BuiltinConfig.extras.length > 0;
  }
}
