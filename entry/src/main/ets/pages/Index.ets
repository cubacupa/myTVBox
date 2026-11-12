import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../utils/AppState';
import { ConfigStore } from '../utils/ConfigStore';
import { MySitesStore } from '../utils/MySitesStore';
import { BuiltinConfig } from '../utils/BuiltinConfig';
import { SiteApi } from '../utils/SiteApi';
import { FilterUtil, FilterGroup, FilterValue, FilterSel } from '../utils/FilterUtil';
import { SiteCfg } from '../model/TvBoxModels';
import { VodItem, VodClass } from '../model/VodItem';
import { PosterCard } from '../components/PosterCard';
import { RatingStore } from '../utils/RatingStore';
import { PosterStore } from '../utils/PosterStore';
import { HttpUtil } from '../utils/HttpUtil';
import { PinStore } from '../utils/PinStore';
import { DoubanAuth } from '../utils/DoubanAuth';
import { TopBar } from '../components/TopBar';

/**
 * 点播首页（TVBox 形态）：
 * 顶部分类横排（右侧带排序切换）+ 筛选（地区/年份）+ 海报墙，滚动到底自动加载下一页。
 * 排序分两种维度（最新 / 评分）× 两个方向（降序 / 升序，可切换）。
 */

/** 排序：new = 站点原始顺序，score = 按已刮到的豆瓣分排序；方向由 sortAsc 决定 */
const SORT_NEW: string = 'new';
const SORT_SCORE: string = 'score';
const SORT_KEY: string = 'indexSortMode';
const SORT_ASC_KEY: string = 'indexSortAsc';

/**
 * 常见大类名。只有站点里真的存在两个以上这种大类，才启用「按名字分组」的兜底，
 * 免得把本来就单级平铺的站点拆坏。
 */
const PARENT_NAMES: string[] = ['电影', '电视剧', '综艺', '动漫', '体育'];

/**
 * 站里经常只给子类、不给大类名的两个组。站里没有同名分类时，
 * 如果子项够多（≥2）就补一个虚拟一级，点进去自动落第一个子类。
 */
const EXTRA_PARENTS: string[] = ['体育', '短剧'];

/**
 * 「子分类名:父分类名」对照表。
 * 有些采集站的 class 只回 type_id / type_name，完全没有 type_pid（百度采集就是这样），
 * 层级在接口层就丢了，只能靠分类名把子类挂回大类；否则一级二级会全挤在一行。
 */
const CHILD_PARENT: string[] = [
  '动作片:电影', '喜剧片:电影', '爱情片:电影', '科幻片:电影', '恐怖片:电影',
  '剧情片:电影', '战争片:电影', '纪录片:电影', '记录片:电影', '动画片:电影',
  '悬疑片:电影', '惊悚片:电影', '犯罪片:电影', '冒险片:电影', '奇幻片:电影',
  '武侠片:电影', '古装片:电影', '家庭片:电影', '运动片:电影', '音乐片:电影',
  '歌舞片:电影', '历史片:电影', '传记片:电影', '灾难片:电影', '枪战片:电影',
  '伦理片:电影', '理论片:电影', '福利片:电影', '福利:电影', '解说片:电影',
  '电影解说:电影', '影视解说:电影', '预告片:电影', '其他片:电影', '网络电影:电影',
  '微电影:电影', '经典电影:电影', '4K电影:电影', '邵氏电影:电影', '动画电影:电影',
  '伦理:电影', '港台三级:电影', '韩国伦理:电影', '西方伦理:电影', '日本伦理:电影',
  '两性课堂:电影', '写真热舞:电影',
  '喜剧:电影', '爱情:电影', '科幻:电影', '恐怖:电影',
  '剧情:电影', '动作:电影', '战争:电影', '冒险:电影', '奇幻:电影',
  '悬疑:电影', '惊悚:电影', '犯罪:电影',
  '国产剧:电视剧', '大陆剧:电视剧', '香港剧:电视剧', '台湾剧:电视剧', '欧美剧:电视剧',
  '韩国剧:电视剧', '韩剧:电视剧', '日本剧:电视剧', '日剧:电视剧', '泰国剧:电视剧',
  '泰剧:电视剧', '海外剧:电视剧', '其他剧:电视剧', '港剧:电视剧', '台剧:电视剧',
  '美剧:电视剧', '英剧:电视剧', '新加坡剧:电视剧', '马来西亚剧:电视剧', '内地剧:电视剧',
  '连续剧:电视剧', '港澳剧:电视剧', '港台剧:电视剧',
  '大陆综艺:综艺', '港台综艺:综艺', '日韩综艺:综艺', '欧美综艺:综艺', '海外综艺:综艺',
  '综艺频道:综艺', '日本综艺:综艺', '韩国综艺:综艺', '台湾综艺:综艺', '香港综艺:综艺',
  '新马泰综艺:综艺', '内地综艺:综艺', '演唱会:综艺',
  '国产动漫:动漫', '日本动漫:动漫', '欧美动漫:动漫', '海外动漫:动漫', '中国动漫:动漫',
  '国漫:动漫', '日漫:动漫', '动漫片:动漫', '动画:动漫',
  '日韩动漫:动漫', '港台动漫:动漫', '有声动漫:动漫',
  '体育赛事:体育', '足球:体育', '篮球:体育', '网球:体育', '斯诺克:体育', '台球:体育',
  '羽毛球:体育', '乒乓球:体育', '赛车:体育', '拳击:体育', '电竞:体育',
  '女频恋爱:短剧', '反转爽剧:短剧', '古装仙侠:短剧', '年代穿越:短剧', '脑洞悬疑:短剧',
  '现代都市:短剧', 'ai短剧:短剧', '短剧大全:短剧'
];

interface SortRef {
  it: VodItem;
  s: number;
  i: number;
}

@Entry
@Component
struct Index {
  @State classes: VodClass[] = [];
  @State tops: VodClass[] = [];      // 一级分类（type_pid 为 0）
  @State subs: VodClass[] = [];      // 当前一级下的二级分类
  @State curTop: string = '';        // 当前一级分类 id
  @State items: VodItem[] = [];
  @State curClass: string = '';
  @State page: number = 1;
  @State pageCount: number = 1;
  @State loading: boolean = false;
  @State err: string = '';
  @State needConfig: boolean = false;
  @State siteName: string = '';
  @State siteKey: string = '';
  @State showSites: boolean = false;
  @State sites: SiteCfg[] = [];
  @State filterGroups: FilterGroup[] = [];
  @State sels: FilterSel[] = [];
  @State showFilter: boolean = false;
  @State sortMode: string = SORT_NEW;
  /** 排序方向：false = 降序（默认），true = 升序 */
  @State sortAsc: boolean = false;
  /** 已收进 Default 的站点 api（规范化后），顶栏按钮和站点浮层都读它 */
  @State myApis: string[] = [];
  /** 每次收集/移出自增，用来强制站点浮层的 ForEach 重建（key 里带上） */
  @State myRev: number = 0;
  @State toast: string = '';
  /** 分类切换后如果接口返回的还是同一批片，用这行字说明是站点的问题，免得用户反复白点 */
  @State classNote: string = '';

  // ---- 家长锁 ----
  /** 已设置的 4 位 PIN；空串表示没设置，所有分类照常显示 */
  @State pin: string = '';
  /** 是否已解锁（30 分钟有效，过期自动重新上锁；见 PinStore） */
  @State unlocked: boolean = false;
  /** 家长锁时效巡检定时器 */
  private pinTimer: number = -1;
  /** 当前一级下被隐藏的受限分类数量，用来决定 🔒 按钮显不显示 */
  @State lockedCount: number = 0;
  /** 一级分类里被隐藏的受限项数量（有些站直接有一级「伦理片」这种） */
  @State lockedTopCount: number = 0;
  @State pinOpen: boolean = false;
  @State pinInput: string = '';
  @State pinErr: string = '';

  /** 豆瓣分 / 海报陆续到货时收到通知，用来判断「按评分排序」什么时候重新排一次 */
  @StorageProp('posterTick') @Watch('onScoreTick') posterTick: number = 0;
  /** 站点返回的原始顺序，切回「最新」时靠它还原（items 只是排序后的展示副本） */
  private raw: VodItem[] = [];
  private sortDirty: boolean = false;
  private sortTimer: number = -1;
  /** 分类/筛选请求序号：快速连点时只认最后一次的结果，避免旧请求后返回把新内容覆盖 */
  private fetchSeq: number = 0;
  /** 站点加载序号：快速连切站点时，旧站点的加载结果不覆盖新站点 */
  private loadSeq: number = 0;
  private toastTimer: number = -1;
  /** 上一次结果前几部片的 id 指纹，用来判断「换了分类但内容没变」 */
  private lastSig: string = '';
  /** 本次请求是不是用户主动切分类/筛选触发的（首次加载和翻页不算） */
  private byUserClass: boolean = false;
  /** 完整的二级分类（含受限项），解锁后用它恢复 subs */
  private allSubs: VodClass[] = [];
  /** 完整的一级分类（含受限项），解锁后用它恢复 tops */
  private allTops: VodClass[] = [];

  private normApi(api: string): string {
    let s: string = (api ?? '').trim().toLowerCase();
    while (s.length > 0 && s.charAt(s.length - 1) === '/') {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  private inMySites(api: string): boolean {
    const k: string = this.normApi(api);
    if (k.length === 0) {
      return false;
    }
    for (const a of this.myApis) {
      if (a === k) {
        return true;
      }
    }
    return false;
  }

  private refreshMy(): void {
    const ctx = getContext(this) as common.Context;
    this.myApis = MySitesStore.apis(ctx);
    this.myRev++;
  }

  /** 顶栏第 4 个按钮的文字：跟着当前站点与收集状态走 */
  private collectLabel(): string {
    const s: SiteCfg | null = AppState.currentSite;
    if (s === null) {
      return '';
    }
    return this.inMySites(s.api) ? '✓ 已在 Default' : '＋ 收进 Default';
  }

  private mySiteLabel(s: SiteCfg): string {
    return this.inMySites(s.api) ? '✓ 已收' : '＋ 收进 Default';
  }

  private showToast(msg: string): void {
    this.toast = msg;
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
    }
    this.toastTimer = setTimeout(() => {
      this.toast = '';
      this.toastTimer = -1;
    }, 2800);
  }

  /**
   * 按 PIN 状态生成「可见的二级分类」。
   * 直接过滤 subs 而不是在 UI 里跳过，是为了让默认落点、空分类兜底、高亮比较
   * 全都自动跟着走，不会出现「一进站就默认落进被锁的分类」。
   */
  private applySubs(all: VodClass[]): void {
    this.allSubs = all;
    const vis: VodClass[] = [];
    let n: number = 0;
    for (const c of all) {
      if (PinStore.isRestricted(c.type_name ?? '')) {
        n++;
      } else {
        vis.push(c);
      }
    }
    // 解锁后也保留受限项总数：标题行需要一个「🔓 重新上锁」的入口
    this.lockedCount = n;
    this.subs = (this.pin.length === 0 || this.unlocked) ? all : vis;
  }

  /**
   * 按 PIN 状态生成「可见的一级分类」。
   * 和二级一样直接过滤数组，这样默认落点、子分类来源、高亮比较都自动跟着走，
   * 不会出现「一进站就停在被锁的一级上」。
   */
  private applyTops(all: VodClass[]): void {
    this.allTops = all;
    const vis: VodClass[] = [];
    let n: number = 0;
    for (const c of all) {
      if (PinStore.isRestricted(c.type_name ?? '')) {
        n++;
      } else {
        vis.push(c);
      }
    }
    this.lockedTopCount = n;
    this.tops = (this.pin.length === 0 || this.unlocked) ? all : vis;
  }

  private openPinDialog(): void {
    this.pinInput = '';
    this.pinErr = '';
    this.pinOpen = true;
  }

  /** 输对 PIN 后开一个 30 分钟的解锁窗口；不落盘 */
  private confirmPin(): void {
    const ctx = getContext(this) as common.Context;
    const res: string = PinStore.verify(ctx, this.pinInput);
    if (res.length > 0) {
      this.pinErr = res;
      return;
    }
    this.unlocked = true;
    PinStore.unlockVod();   // 只解锁点播分类；历史页有自己独立的解锁态
    this.pinOpen = false;
    this.pinInput = '';
    this.pinErr = '';
    this.applyTops(this.allTops);
    this.applySubs(this.allSubs);
    this.showToast('已解锁：受限分类 30 分钟内可见，到期自动上锁');
  }

  /** 顶栏按钮：对当前正在出内容的站点一键收集 */
  private toggleCurrent(): void {
    const s: SiteCfg | null = AppState.currentSite;
    if (s === null) {
      this.showToast('当前没有可用站点');
      return;
    }
    this.toggleMySite(s);
  }

  /**
   * 加入 / 移出自己的 Default。
   * 收集的是站点本身，不是配置地址：第三方接口以后失效了，收下来的站照常能播。
   * 当前正好在用 Default 时，顺手把首页的站点列表刷新一遍，不用重新载入接口。
   */
  private toggleMySite(s: SiteCfg): void {
    const ctx = getContext(this) as common.Context;
    const before: string = this.siteKey;
    this.showToast(MySitesStore.toggle(ctx, s));
    this.refreshMy();
    if (BuiltinConfig.isBuiltin(AppState.configUrl)) {
      ConfigStore.applyText(BuiltinConfig.text());
      this.sites = AppState.usableSites();
      const cur: SiteCfg | null = AppState.currentSite;
      this.siteKey = cur === null ? '' : cur.key;
      this.siteName = cur === null ? '' : cur.name;
      if (cur !== null && cur.key !== before) {
        // 当前站被移出了，落到新站要重新拉一次内容
        this.loadAll();
      }
    }
  }

  aboutToAppear(): void {
    const saved: string | undefined = AppStorage.get<string>(SORT_KEY);
    if (saved === SORT_SCORE || saved === SORT_NEW) {
      this.sortMode = saved;
    }
    const asc: boolean | undefined = AppStorage.get<boolean>(SORT_ASC_KEY);
    if (asc !== undefined) {
      this.sortAsc = asc;
    }
    this.boot();
    this.startPinPoll();
  }

  /**
   * 从设置页回来时重读 PIN：设置 / 修改 / 清除都要立刻生效，并重新上锁。
   * 只在值变化时重载分类，避免每次切页都白拉一次接口。
   */
  onPageShow(): void {
    const ctx = getContext(this) as common.Context;
    const p: string = PinStore.get(ctx);
    const changed: boolean = p !== this.pin;
    if (changed) {
      this.pin = p;
      PinStore.relock();   // 改了 / 清了 PIN，分类和历史两处一起重新上锁
      this.pinOpen = false;
    }
    // isVodUnlocked() 读的时候顺带清掉过期态：从播放页 / 别的页签回来这一刻就该收回。
    // 只靠冷启动重置是不够的 —— 电视进程几周不死，等于解锁一次永久解锁。
    const valid: boolean = PinStore.isVodUnlocked();
    if (this.unlocked && !valid) {
      this.relockVod(true);
    } else if (changed || this.unlocked !== valid) {
      this.unlocked = valid;
      this.applyTops(this.allTops);
      this.applySubs(this.allSubs);
    }
    if (changed) {
      this.loadAll();
    }
  }

  aboutToDisappear(): void {
    this.stopSortPoll();
    this.stopPinPoll();
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  private async boot(): Promise<void> {
    this.loading = true;
    const ctx = getContext(this) as common.Context;
    // 读回「哪些域名的 https 走不通」，冷启动第一次请求就省掉 15 秒白等
    HttpUtil.init(ctx);
    // 豆瓣登录 Cookie（可选）：必须在第一次豆瓣请求前读回来，否则等于没登录
    DoubanAuth.init(ctx);
    this.pin = PinStore.get(ctx);   // 家长锁：读 PIN 指纹（空串 = 没设置，拿不到原文）
    this.unlocked = PinStore.isVodUnlocked();   // 冷启动一定是 false；热启动要查有没有过期
    RatingStore.init(ctx);
    PosterStore.init(ctx);
    try {
      await ConfigStore.init(ctx);
    } catch (e) {
      this.err = (e as Error).message;
    }
    this.refreshMy();
    this.sites = AppState.usableSites();
    const site = AppState.currentSite;
    if (site === null) {
      this.needConfig = true;
      this.loading = false;
      return;
    }
    this.siteName = site.name;
    this.siteKey = site.key;
    this.needConfig = false;
    await this.loadAll();
    if (this.sortMode === SORT_SCORE) {
      this.sortDirty = true;
      this.startSortPoll();
    }
  }

  private async loadAll(): Promise<void> {
    const site = AppState.currentSite;
    if (site === null) {
      return;
    }
    const seq: number = ++this.loadSeq;
    this.loading = true;
    this.err = '';
    // 切站点后旧内容不要挂在新站点下面：先清空列表，分类稍后由接口重新填
    this.raw = [];
    this.items = [];
    this.page = 1;
    try {
      // type_id / type_pid 有的站给数字、有的给字符串。先在这里统一成字符串，
      // 否则界面里 `c.type_id === curClass` 会退化成 number 与 string 比较，
      // 一级点过一次以后二级高亮就永远不亮（不同站点的分类树都会踩这个坑）。
      const rawCls: VodClass[] = await SiteApi.getClasses(site);
      // 快速连切站点时，旧站点的分类可能晚到：已被更新的加载取代就直接丢弃
      if (seq !== this.loadSeq) {
        return;
      }
      const normCls: VodClass[] = [];
      for (const c of rawCls) {
        const p: string | number | undefined = c.type_pid;
        const pid: string = p === undefined ? '' : this.pidKey(p);
        normCls.push({
          type_id: this.pidKey(c.type_id),
          type_name: c.type_name,
          type_pid: pid
        });
      }
      this.classes = normCls;
      this.buildClassTree();
      const firstTop: VodClass | null = this.tops.length > 0 ? this.tops[0] : null;
      this.curTop = firstTop === null ? '' : this.pidKey(firstTop.type_id);
      this.applySubs(firstTop === null ? [] : this.childrenOf(this.curTop));
      // 落到第一个子分类而不是一级本身：苹果CMS 的一级（电影片/连续剧）
      // 只装着没归到子类的少数片，所以直接进一级经常只有一两部
      this.curClass = this.subs.length > 0 ? this.subs[0].type_id
        : (firstTop === null ? '' : firstTop.type_id);
      this.initFilters();
      let r = await SiteApi.getList(site, this.curClass, 1, FilterUtil.toQuery(this.sels));
      if (seq !== this.loadSeq) {
        return;
      }

      // 兜底：首个分类常常是空的，这时在同一一级的兄弟分类里再试 2 个，
      // 命中就停在那里。不跨一级跳，否则高亮的父分类和实际内容对不上。
      if (r.items.length === 0) {
        const pool: VodClass[] = this.subs.length > 0 ? this.subs : this.tops;
        const maxTry = Math.min(pool.length, 3);
        let hit = false;
        for (let i = 1; i < maxTry; i++) {
          this.curClass = pool[i].type_id;
          this.initFilters();
          try {
            r = await SiteApi.getList(site, this.curClass, 1, FilterUtil.toQuery(this.sels));
          } catch (e) {
            // 单个分类请求失败不影响继续尝试下一个
            continue;
          }
          if (seq !== this.loadSeq) {
            return;
          }
          if (r.items.length > 0) {
            hit = true;
            break;
          }
        }
        if (!hit) {
          // 试过的分类都没数据，回到本一级的第一个，保持界面与分类高亮一致
          this.curClass = this.subs.length > 0 ? this.subs[0].type_id
            : (firstTop === null ? '' : firstTop.type_id);
          this.initFilters();
        }
      }

      this.lastSig = this.sigOf(r.items);
      this.classNote = '';
      this.raw = r.items;
      this.items = this.withSort(this.raw);
      this.page = 1;
      this.pageCount = r.pageCount;
      RatingStore.warm(this.items);
      if (this.items.length === 0) {
        this.err = '该站点的分类接口没有返回数据（可能已失效，换个站点试试）';
      }
    } catch (e) {
      if (seq !== this.loadSeq) {
        return;
      }
      this.classes = [];
      this.raw = [];
      this.items = [];
      this.err = '加载失败：' + (e as Error).message + '（站点可能已失效）';
    } finally {
      if (seq === this.loadSeq) {
        this.loading = false;
      }
    }
  }

  // 筛选维度：优先取配置 ext.filter（去掉排序，采集站不认），取不到用内置地区/年份
  private initFilters(): void {
    const site = AppState.currentSite;
    if (site === null) {
      this.filterGroups = [];
      this.sels = [];
      return;
    }
    let groups = FilterUtil.withoutSort(FilterUtil.fromExt(site, this.curClass));
    if (groups.length === 0) {
      groups = FilterUtil.builtin();
    }
    this.filterGroups = groups;
    this.sels = FilterUtil.defaultSels(groups);
  }

  private isSel(gi: number, v: string): boolean {
    if (gi >= this.sels.length) {
      return false;
    }
    return this.sels[gi].value === v;
  }

  private activeFilterCount(): number {
    let n = 0;
    for (const s of this.sels) {
      if (s.value) {
        n++;
      }
    }
    return n;
  }

  /**
   * 按当前排序维度和方向产出展示列表。
   * 「评分」是纯客户端排序：采集站 API 没有 order 参数，只能拿我们已经刮到的豆瓣分来排。
   * 有分的按分数排前面，没分（豆瓣未开分 / 还没刮到）的一律垫底，
   * 所以刚进页面时看起来和「最新」一样，等分数陆续到货才会往前挪。
   * 「最新」= 站点原始顺序：降序保持原样，升序把整个列表倒过来。
   */
  private withSort(list: VodItem[]): VodItem[] {
    if (list.length < 2) {
      return list;
    }
    const asc: boolean = this.sortAsc;
    if (this.sortMode !== SORT_SCORE) {
      if (!asc) {
        return list;
      }
      const rev: VodItem[] = [];
      for (let i = list.length - 1; i >= 0; i--) {
        rev.push(list[i]);
      }
      return rev;
    }
    const refs: SortRef[] = [];
    for (let i = 0; i < list.length; i++) {
      refs.push({ it: list[i], s: RatingStore.scoreOf(list[i]), i: i });
    }
    refs.sort((a: SortRef, b: SortRef) => {
      const aHas: boolean = a.s > 0;
      const bHas: boolean = b.s > 0;
      if (aHas !== bHas) {
        return aHas ? -1 : 1;          // 有分的一律排前面，升序也不例外
      }
      if (aHas && a.s !== b.s) {
        return asc ? a.s - b.s : b.s - a.s;
      }
      return a.i - b.i;                // 同分 / 都没分：保持站点原序，别让无分组乱跳
    });
    const out: VodItem[] = [];
    for (let i = 0; i < refs.length; i++) {
      out.push(refs[i].it);
    }
    return out;
  }

  private setSort(mode: string): void {
    if (this.sortMode === mode) {
      return;
    }
    this.sortMode = mode;
    AppStorage.setOrCreate(SORT_KEY, mode);
    this.items = this.withSort(this.raw);
    if (mode === SORT_SCORE) {
      this.sortDirty = true;
      this.startSortPoll();
    } else {
      this.stopSortPoll();
    }
  }

  private toggleSortDir(): void {
    this.sortAsc = !this.sortAsc;
    AppStorage.setOrCreate(SORT_ASC_KEY, this.sortAsc);
    this.items = this.withSort(this.raw);
  }

  private onScoreTick(): void {
    if (this.sortMode === SORT_SCORE) {
      this.sortDirty = true;
    }
  }

  /**
   * 真正重排只放在「这一轮刮削彻底跑完」之后，不做逐条实时插入。
   * 否则每 6 秒来一个分数就把卡片挪一次位，电视上用遥控器正好点错片。
   */
  private startSortPoll(): void {
    if (this.sortTimer !== -1) {
      return;
    }
    this.sortTimer = setInterval(() => {
      this.pollSort();
    }, 2000) as number;
  }

  private pollSort(): void {
    if (this.sortMode !== SORT_SCORE) {
      this.stopSortPoll();
      return;
    }
    if (!this.sortDirty) {
      return;
    }
    if (RatingStore.pending() > 0 || PosterStore.namesPending() > 0) {
      return;
    }
    this.sortDirty = false;
    this.items = this.withSort(this.raw);
  }

  private stopSortPoll(): void {
    if (this.sortTimer !== -1) {
      clearInterval(this.sortTimer);
      this.sortTimer = -1;
    }
  }

  /** 手动 / 到期重新上锁：收回分类，并把还停在受限分类上的视图切回第一个可见分类 */
  private relockVod(silent: boolean = false): void {
    PinStore.lockVod();
    const was: boolean = this.unlocked;
    this.unlocked = false;
    this.applyTops(this.allTops);
    this.applySubs(this.allSubs);
    if (was && this.subs.length > 0 && !this.isCurClassVisible()) {
      this.switchClass(this.subs[0]).catch(() => {});
    }
    if (!silent) {
      this.showToast('已重新上锁：受限分类重新隐藏');
    }
  }

  private isCurClassVisible(): boolean {
    for (const c of this.subs) {
      if (this.pidKey(c.type_id) === this.curClass) {
        return true;
      }
    }
    return false;
  }

  /** 家长锁时效巡检：人一直停在首页不动、进程又长期不重启时，也要按时自动上锁 */
  private startPinPoll(): void {
    if (this.pinTimer !== -1) {
      return;
    }
    this.pinTimer = setInterval(() => {
      if (this.unlocked && !PinStore.isVodUnlocked()) {
        this.relockVod(true);
      }
    }, 60000) as number;
  }

  private stopPinPoll(): void {
    if (this.pinTimer !== -1) {
      clearInterval(this.pinTimer);
      this.pinTimer = -1;
    }
  }

  private async fetchFirst(byUser: boolean = false): Promise<void> {
    const site = AppState.currentSite;
    if (site === null) {
      return;
    }
    // 换分类/筛选时先把旧内容清掉，界面立刻变成「加载中」，
    // 而不是挂着上一批影片等网络回来才换（用户要求：点了马上换内容）
    const seq: number = ++this.fetchSeq;
    this.loading = true;
    this.raw = [];
    this.items = [];
    this.page = 1;
    this.err = '';
    this.classNote = '';
    try {
      const r = await SiteApi.getList(site, this.curClass, 1, FilterUtil.toQuery(this.sels));
      // 快速连点分类时，先发出的请求可能后返回：只认最后一次点击的结果
      if (seq !== this.fetchSeq) {
        return;
      }
      // 有些采集站（比如淘片）的接口只把分类名回填进结果，压根没按分类过滤：
      // 换了分类、返回的前几部片却一模一样。识别出来直接说明白，省得用户以为点坏了。
      const sig: string = this.sigOf(r.items);
      if (byUser && this.lastSig.length > 0 && sig.length > 0 && sig === this.lastSig) {
        this.classNote = '这个站的分类接口没真筛：换了分类，返回的还是同一批影片（站点问题）';
      } else {
        this.classNote = '';
      }
      this.lastSig = sig;
      this.raw = r.items;
      this.items = this.withSort(this.raw);
      this.page = 1;
      this.pageCount = r.pageCount;
      RatingStore.warm(this.items);
      this.err = this.items.length === 0 ? '这个筛选条件下没有结果' : '';
    } catch (e) {
      if (seq !== this.fetchSeq) {
        return;
      }
      this.raw = [];
      this.items = [];
      this.err = '加载失败：' + (e as Error).message;
    } finally {
      // 只有最新一次请求收尾时才关加载态，避免旧请求提前把新请求的「加载中」关掉
      if (seq === this.fetchSeq) {
        this.loading = false;
      }
    }
  }

  /** 取结果前几部片的 id 做指纹，用来判断两次请求拿到的是不是同一批 */
  private sigOf(list: VodItem[]): string {
    const n: number = list.length < 3 ? list.length : 3;
    let s: string = '';
    for (let i = 0; i < n; i++) {
      s = s + String(list[i].vod_id) + '|';
    }
    return s;
  }

  // ---------- 两级分类 ----------

  /** type_id 站内给的是数字，统一转字符串再比较，免得数字/字符串混比永远不相等 */
  private pidKey(v: string | number): string {
    return v === undefined || v === null ? '' : v.toString().trim();
  }

  /** 父分类 id；站点用 0 表示顶级，这里统一成空串 */
  private pidOf(c: VodClass): string {
    const p = c.type_pid;
    if (p === undefined || p === null) {
      return '';
    }
    const s: string = p.toString().trim();
    return s === '0' ? '' : s;
  }

  /**
   * 拆分类树。采集站有三种形态：
   * 1) 接口给了 type_pid：按父子关系拆（正常苹果 CMS）；
   * 2) 没给 type_pid，但分类名写成 "动漫/海外动漫"：按 "/" 拆出虚拟一级，
   *    前半段当一级、后半段当二级（淘片这类站就是这么写的）；
   * 3) 两种都没有：退化成单行，保持旧行为。
   */
  private buildClassTree(): void {
    let hasChild: boolean = false;
    for (const c of this.classes) {
      if (this.pidOf(c).length > 0) {
        hasChild = true;
        break;
      }
    }
    if (hasChild) {
      const tops: VodClass[] = [];
      for (const c of this.classes) {
        if (this.pidOf(c).length === 0) {
          tops.push(c);
        }
      }
      this.applyTops(tops.length > 0 ? tops : this.classes);
      return;
    }

    // 只有一个名字带 "/" 可能只是名字里恰好有斜杠，两个以上才当成层级写法
    let slash: number = 0;
    for (const c of this.classes) {
      const n: string = c.type_name ?? '';
      if (n.indexOf('/') > 0 && n.indexOf('/') < n.length - 1) {
        slash++;
      }
    }
    if (slash < 2) {
      // 名字里没有 "/" 时，退回按分类名分组的兜底；连大类都分不出来就平铺
      if (this.groupByNames()) {
        return;
      }
      this.applyTops(this.classes);
      return;
    }

    const tops: VodClass[] = [];
    const flat: VodClass[] = [];
    const seen: string[] = [];
    for (const c of this.classes) {
      const name: string = (c.type_name ?? '').trim();
      const at: number = name.indexOf('/');
      if (at > 0 && at < name.length - 1) {
        const g: string = name.substring(0, at).trim();
        const sub: string = name.substring(at + 1).trim();
        if (seen.indexOf(g) < 0) {
          seen.push(g);
          const gv: VodClass = { type_id: 'g:' + g, type_name: g, type_pid: '' };
          tops.push(gv);
          flat.push(gv);
        }
        // 二级保留站点真实的 type_id，请求列表时还得用它
        const cv: VodClass = {
          type_id: this.pidKey(c.type_id),
          type_name: sub,
          type_pid: 'g:' + g
        };
        flat.push(cv);
      } else {
        const cv: VodClass = {
          type_id: this.pidKey(c.type_id),
          type_name: name,
          type_pid: ''
        };
        tops.push(cv);
        flat.push(cv);
      }
    }
    this.classes = flat;
    this.applyTops(tops);
  }

  /** 按分类名推断它属于哪个大类；查不到返回空串 */
  private parentNameOf(name: string): string {
    const prefix: string = name + ':';
    for (const row of CHILD_PARENT) {
      if (row.indexOf(prefix) === 0) {
        return row.substring(prefix.length);
      }
    }
    return '';
  }

  /**
   * 接口既没给 type_pid、分类名也不是 "动漫/海外动漫" 这种写法时的兜底：
   * 用分类名把子类挂回站点里真实存在的大类。
   * 百度采集就是这类——`ac=list` 只回 type_id/type_name，1 电影 / 2 电视剧 / 3 综艺 / 4 动漫
   * 后面直接跟着 6 动作片、13 大陆剧、25 大陆综艺，层级全靠名字猜。
   * 只有站点里同时存在两个以上大类才动手，避免把单级站点拆坏。
   */
  private groupByNames(): boolean {
    const names: string[] = [];
    for (const c of this.classes) {
      names.push((c.type_name ?? '').trim());
    }
    // 每个分类想归到哪个大类（'' 表示它自己就是大类）
    const want: string[] = [];
    for (const n of names) {
      if (PARENT_NAMES.indexOf(n) >= 0 || EXTRA_PARENTS.indexOf(n) >= 0) {
        want.push('');
      } else {
        want.push(this.parentNameOf(n));
      }
    }
    // 统计各大类下的子项数
    const pnames: string[] = [];
    const pcount: number[] = [];
    for (const w of want) {
      if (w.length === 0) {
        continue;
      }
      const i: number = pnames.indexOf(w);
      if (i < 0) {
        pnames.push(w);
        pcount.push(1);
      } else {
        pcount[i] = pcount[i] + 1;
      }
    }
    // 站里有同名分类、或子项 ≥2（可以补虚拟一级）才算成立
    const okParents: string[] = [];
    const parentIds: string[] = [];
    for (let i = 0; i < pnames.length; i++) {
      let real: string = '';
      for (const c of this.classes) {
        if ((c.type_name ?? '').trim() === pnames[i]) {
          real = this.pidKey(c.type_id);
          break;
        }
      }
      if (real.length > 0 || pcount[i] >= 2) {
        okParents.push(pnames[i]);
        parentIds.push(real);
      }
    }
    if (okParents.length < 2) {
      return false;
    }
    const flat: VodClass[] = [];
    const tops: VodClass[] = [];
    for (let k = 0; k < this.classes.length; k++) {
      const name: string = names[k];
      let pid: string = '';
      const w: string = want[k];
      if (w.length > 0) {
        const i: number = okParents.indexOf(w);
        if (i >= 0) {
          pid = parentIds[i].length > 0 ? parentIds[i] : ('g:' + w);
        }
      }
      const cv: VodClass = {
        type_id: this.pidKey(this.classes[k].type_id),
        type_name: name,
        type_pid: pid
      };
      flat.push(cv);
      if (pid.length === 0) {
        tops.push(cv);
      }
    }
    // 站里没有对应分类的大类，补一个虚拟一级（点进去落第一个子类）
    for (let i = 0; i < okParents.length; i++) {
      if (parentIds[i].length === 0) {
        const gv: VodClass = {
          type_id: 'g:' + okParents[i],
          type_name: okParents[i],
          type_pid: ''
        };
        flat.push(gv);
        tops.push(gv);
      }
    }
    this.classes = flat;
    this.applyTops(tops);
    return true;
  }

  private childrenOf(pid: string): VodClass[] {
    const out: VodClass[] = [];
    if (pid.length === 0) {
      return out;
    }
    for (const c of this.classes) {
      if (this.pidOf(c) === pid) {
        out.push(c);
      }
    }
    return out;
  }

  /** 点一级：切到它的第一个二级；一级本身没有子分类就直接用它 */
  private async switchTop(t: VodClass): Promise<void> {
    // 同一个保险：一级分类里也可能有限制项（站点直接给一级「伦理片」），
    // 万一从别的入口点到，先要 PIN，不直接加载内容
    if (PinStore.isRestricted(t.type_name ?? '') && this.pin.length > 0 && !this.unlocked) {
      this.openPinDialog();
      return;
    }
    const key: string = this.pidKey(t.type_id);
    if (this.curTop === key) {
      return;
    }
    this.curTop = key;
    this.applySubs(this.childrenOf(key));
    this.curClass = this.subs.length > 0 ? this.pidKey(this.subs[0].type_id) : key;
    this.initFilters();
    await this.fetchFirst(true);
  }

  private async switchClass(c: VodClass): Promise<void> {
    // 保险：万一从别的入口点到受限分类，先要 PIN，不直接加载内容
    if (PinStore.isRestricted(c.type_name ?? '') && this.pin.length > 0 && !this.unlocked) {
      this.openPinDialog();
      return;
    }
    const id: string = this.pidKey(c.type_id);
    if (this.curClass === id) {
      return;
    }
    this.curClass = id;
    // 跨组点击时（二级栏理论上不会出现别组的项）把一级高亮一起挪过去
    const pid: string = this.pidOf(c);
    if (pid.length > 0 && pid !== this.curTop) {
      this.curTop = pid;
      this.applySubs(this.childrenOf(pid));
    }
    this.initFilters();
    await this.fetchFirst(true);
  }

  private async pickFilter(gi: number, v: FilterValue): Promise<void> {
    if (gi >= this.filterGroups.length) {
      return;
    }
    const next: FilterSel[] = [];
    for (let i = 0; i < this.filterGroups.length; i++) {
      const g = this.filterGroups[i];
      let value = '';
      let label = '全部';
      if (i === gi) {
        value = v.v;
        label = v.n;
      } else if (i < this.sels.length) {
        value = this.sels[i].value;
        label = this.sels[i].label;
      }
      const s: FilterSel = { key: g.key, value: value, label: label };
      next.push(s);
    }
    this.sels = next;
    this.showFilter = false;
    await this.fetchFirst(true);
  }

  private async resetFilters(): Promise<void> {
    this.sels = FilterUtil.defaultSels(this.filterGroups);
    this.showFilter = false;
    await this.fetchFirst(true);
  }

  private async loadMore(): Promise<void> {
    if (this.loading || this.page >= this.pageCount) {
      return;
    }
    const site = AppState.currentSite;
    if (site === null) {
      return;
    }
    this.loading = true;
    try {
      const next = this.page + 1;
      const r = await SiteApi.getList(site, this.curClass, next, FilterUtil.toQuery(this.sels));
      this.raw = this.raw.concat(r.items);
      this.items = this.withSort(this.raw);
      this.page = next;
      this.pageCount = r.pageCount;
      RatingStore.warm(r.items);
    } catch (e) {
      // 加载更多失败不打断浏览
    } finally {
      this.loading = false;
    }
  }

  private goDetail(item: VodItem): void {
    const site = AppState.currentSite;
    const key = item.site_key ? item.site_key : (site !== null ? site.key : '');
    router.pushUrl({
      url: 'pages/Detail',
      params: { key: key, vodId: String(item.vod_id) }
    });
  }

  private async switchSite(s: SiteCfg): Promise<void> {
    const ctx = getContext(this) as common.Context;
    // 先立即把界面切过去（不等写盘、不等网络）：下拉关掉、站点名换掉、
    // 旧列表和旧分类全部清空、进入加载态；然后才落盘并拉新站点的数据。
    // 这样点一下站点就是「秒切」，不是先卡一下再变。
    this.siteName = s.name;
    this.siteKey = s.key;
    this.showSites = false;
    this.classes = [];
    this.tops = [];
    this.allTops = [];
    this.lockedTopCount = 0;
    this.subs = [];
    this.curTop = '';
    this.curClass = '';
    this.raw = [];
    this.items = [];
    this.page = 1;
    this.pageCount = 1;
    this.err = '';
    this.lastSig = '';
    this.classNote = '';
    this.loading = true;
    await ConfigStore.setSite(ctx, s);
    await this.loadAll();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        TopBar({
          active: 0,
          showActions: true,
          siteName: this.siteName,
          filterCount: this.activeFilterCount(),
          collectText: this.collectLabel(),
          onFilter: () => { this.showFilter = true; },
          onSites: () => { this.showSites = true; },
          onSearch: () => { router.pushUrl({ url: 'pages/Search' }); },
          onCollect: () => { this.toggleCurrent(); }
        })

        // 一级分类（电影片 / 连续剧 / 综艺片 / 动漫片 …）
        Row() {
          List({ space: 10 }) {
            ForEach(this.tops, (c: VodClass) => {
              ListItem() {
                Text(c.type_name)
                  .fontSize(17)
                  .fontWeight(this.pidKey(c.type_id) === this.curTop ? FontWeight.Bold : FontWeight.Normal)
                  .fontColor(this.pidKey(c.type_id) === this.curTop ? '#ffffff' : '#cccccc')
                  .backgroundColor(this.pidKey(c.type_id) === this.curTop ? '#FF6B00' : '#2a2a2a')
                  .padding({ left: 18, right: 18, top: 9, bottom: 9 })
                  .borderRadius(6)
                  .focusable(true)
                  .onClick(() => { this.switchTop(c); })
              }
            }, (c: VodClass) => 'T' + c.type_id)
          }
          .listDirection(Axis.Horizontal)
          .height(56)
          .layoutWeight(1)
          .scrollBar(BarState.Off)

          // 一级分类里也可能有受限项（站点直接把「伦理片」当一级给出），
          // 这时解锁入口放在这一行；解锁是全局的，一次把一级 + 二级全放出来
          if (this.lockedTopCount > 0 && this.pin.length > 0) {
            Text(this.unlocked ? '🔓 重新上锁'
              : '🔒 解锁 ' + (this.lockedTopCount + this.lockedCount))
              .fontSize(14)
              .fontColor('#FFB35C')
              .backgroundColor('#2a2013')
              .padding({ left: 14, right: 14, top: 6, bottom: 6 })
              .borderRadius(14)
              .margin({ left: 10 })
              .focusable(true)
              .onClick(() => {
                if (this.unlocked) {
                  this.relockVod();
                } else {
                  this.openPinDialog();
                }
              })
          }

          // 排序：采集站 API 不认 order 参数，能真正改变结果的只有两个维度 + 一个方向。
          // 「最新」= 站点返回的原始顺序；「评分」= 客户端按已刮到的豆瓣分重排。
          // 左边那个橙色胶囊是方向开关，点一下在降序 / 升序之间切。
          Row() {
            Text(this.sortAsc ? '升序 ↑' : '降序 ↓')
              .fontSize(14)
              .fontColor('#FFB35C')
              .backgroundColor('#2a2013')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .margin({ right: 14 })
              .focusable(true)
              .onClick(() => { this.toggleSortDir(); })
            Text('排序')
              .fontSize(13)
              .fontColor('#777777')
              .margin({ right: 8 })
            Text('最新')
              .fontSize(14)
              .fontColor(this.sortMode === SORT_NEW ? '#ffffff' : '#9aa9b8')
              .backgroundColor(this.sortMode === SORT_NEW ? '#3a3a3a' : '#1f1f1f')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .focusable(true)
              .onClick(() => { this.setSort(SORT_NEW); })
            Text('评分')
              .fontSize(14)
              .fontColor(this.sortMode === SORT_SCORE ? '#ffffff' : '#9aa9b8')
              .backgroundColor(this.sortMode === SORT_SCORE ? '#FF6B00' : '#1f1f1f')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(14)
              .margin({ left: 8 })
              .focusable(true)
              .onClick(() => { this.setSort(SORT_SCORE); })
          }
          .margin({ left: 16 })
        }
        .width('100%')
        .padding({ left: 28, right: 28, top: 6 })

        // 二级分类：只有当前一级真的有子分类时才出现（没有 pid 的站点不会多出这一行）
        if (this.subs.length > 0 || (this.lockedCount > 0 && this.lockedTopCount === 0)) {
          Row() {
            // 行顶部对齐：二级芯片是"上对齐+6px 内边距"，解锁文字若随行居中会整体偏低
            List({ space: 8 }) {
              ForEach(this.subs, (c: VodClass) => {
                ListItem() {
                  Text(c.type_name)
                    .fontSize(15)
                    .fontColor(c.type_id === this.curClass ? '#FF6B00' : '#9aa9b8')
                    .backgroundColor(c.type_id === this.curClass ? '#332613' : '#1f1f1f')
                    .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .focusable(true)
                    .onClick(() => { this.switchClass(c); })
                }
              }, (c: VodClass) => 'S' + c.type_id)
            }
            .listDirection(Axis.Horizontal)
            .height(46)
            .layoutWeight(1)
            .scrollBar(BarState.Off)

            // 分类栏末尾的解锁入口：输对 PIN 后本次运行内把隐藏的分类放出来
            // （一级栏那个按钮已经在显示时，这里不重复出现，免得两个一样的按钮）
            if (this.lockedCount > 0 && this.lockedTopCount === 0
              && this.pin.length > 0) {
              Text(this.unlocked ? '🔓 重新上锁' : '🔒 解锁 ' + this.lockedCount)
                .fontSize(14)
                .fontColor('#FFB35C')
                .backgroundColor('#2a2013')
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .borderRadius(14)
                .margin({ left: 10 })
                .focusable(true)
                .onClick(() => {
                  if (this.unlocked) {
                    this.relockVod();
                  } else {
                    this.openPinDialog();
                  }
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ left: 28, right: 28, top: 2 })
        }

        // 站点分类接口没真过滤时，点完给一句说明，别让用户以为点坏了
        if (this.classNote.length > 0) {
          Row() {
            Text(this.classNote)
              .fontSize(13)
              .fontColor('#FFB35C')
              .backgroundColor('#2a2013')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(8)
              .maxLines(2)
          }
          .width('100%')
          .padding({ left: 28, right: 28, top: 6 })
        }

        // 已选条件回显
        if (this.activeFilterCount() > 0) {
          Row() {
            ForEach(this.sels, (s: FilterSel, i: number) => {
              if (s.value) {
                Text(s.label)
                  .fontSize(12)
                  .fontColor('#FF6B00')
                  .backgroundColor('#332613')
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .borderRadius(10)
                  .margin({ right: 8 })
              }
            }, (s: FilterSel, i: number) => s.key + s.value)
          }
          .width('100%')
          .padding({ left: 28, top: 6 })
        }

        if (this.needConfig) {
          Column() {
            Text('还没有点播源').fontSize(22).fontColor('#dddddd')
            Text('去「设置」填入一个配置地址，或把你的采集站收进 Default')
              .fontSize(15).fontColor('#888888').margin({ top: 12 })
              .maxLines(2)
              .textAlign(TextAlign.Center)
            Button('去设置').margin({ top: 26 })
              .onClick(() => { router.replaceUrl({ url: 'pages/Settings' }); })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.loading && this.items.length === 0) {
          Column() {
            LoadingProgress().width(48).height(48)
            Text('加载中…').fontSize(14).fontColor('#999999').margin({ top: 10 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          if (this.err) {
            Text(this.err).fontSize(14).fontColor('#ff7777')
              .width('100%').padding({ left: 28, top: 6 })
          }
          Grid() {
            ForEach(this.items, (item: VodItem) => {
              GridItem() {
                PosterCard({ item: item, onSelect: () => this.goDetail(item) })
              }
            }, (item: VodItem) => String(item.site_key ? item.site_key : '') + '_' + String(item.vod_id))
          }
          .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
          .columnsGap(14)
          .rowsGap(18)
          .padding({ left: 28, right: 28, top: 12, bottom: 20 })
          .layoutWeight(1)
          .onReachEnd(() => { this.loadMore(); })
        }
      }
      .width('100%')
      .height('100%')

      // 站点选择浮层
      if (this.showSites) {
        Column() {
          Column() {
            Row() {
              Text('选择资源站').fontSize(20).fontColor('#ffffff').fontWeight(FontWeight.Bold)
              Blank()
              Button('关闭').fontSize(14).height(36)
                .onClick(() => { this.showSites = false; })
            }
            .width('100%')
            .margin({ bottom: 8 })

            Text('点名字切换站点 · 点右侧按钮把能出内容的站收进 Default'
              + '（已收 ' + Math.max(0, this.myApis.length - 1) + ' 个，重启后仍在）')
              .fontSize(12)
              .fontColor('#888888')
              .width('100%')
              .margin({ bottom: 12 })

            List({ space: 10 }) {
              ForEach(this.sites, (s: SiteCfg) => {
                ListItem() {
                  Row() {
                    Text(s.name)
                      .fontSize(16)
                      .fontColor(s.key === this.siteKey ? '#FF6B00' : '#dddddd')
                      .layoutWeight(1)
                      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                      .backgroundColor(s.key === this.siteKey ? '#332613' : '#2a2a2a')
                      .borderRadius(8)
                      .focusable(true)
                      .onClick(() => { this.switchSite(s); })
                    Text(this.mySiteLabel(s))
                      .fontSize(13)
                      .fontColor(this.inMySites(s.api) ? '#7fd88a' : '#FF9F45')
                      .backgroundColor('#1b1b1b')
                      .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                      .borderRadius(8)
                      .margin({ left: 10 })
                      .focusable(true)
                      .onClick(() => { this.toggleMySite(s); })
                  }
                  .width('100%')
                }
              }, (s: SiteCfg) => s.key + '_' + this.myRev)
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)
          }
          .width('56%')
          .height('70%')
          .backgroundColor('#222222')
          .borderRadius(14)
          .padding(20)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000aa')
        .justifyContent(FlexAlign.Center)
      }

      // 筛选浮层
      if (this.showFilter) {
        Column() {
          Column() {
            Row() {
              Text('筛选').fontSize(20).fontColor('#ffffff').fontWeight(FontWeight.Bold)
              Blank()
              Button('重置').fontSize(14).height(36).backgroundColor('#3a3a3a')
              .fontColor('#ffffff')
                .onClick(() => { this.resetFilters(); })
              Button('关闭').fontSize(14).height(36).margin({ left: 10 })
                .onClick(() => { this.showFilter = false; })
            }
            .width('100%')
            .margin({ bottom: 14 })

            Scroll() {
              Column() {
                ForEach(this.filterGroups, (g: FilterGroup, gi: number) => {
                  Column() {
                    Text(g.name).fontSize(14).fontColor('#888888').width('100%')
                      .margin({ bottom: 8 })
                    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                      ForEach(g.values, (v: FilterValue) => {
                        Text(v.n)
                          .fontSize(14)
                          .fontColor(this.isSel(gi, v.v) ? '#ffffff' : '#cccccc')
                          .backgroundColor(this.isSel(gi, v.v) ? '#FF6B00' : '#2a2a2a')
                          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
                          .borderRadius(6)
                          .margin({ right: 10, bottom: 10 })
                          .focusable(true)
                          .onClick(() => { this.pickFilter(gi, v); })
                      }, (v: FilterValue) => g.key + '_' + v.v + '_' + v.n)
                    }
                    .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .margin({ bottom: 18 })
                }, (g: FilterGroup) => g.key)
              }
              .width('100%')
            }
            .layoutWeight(1)
            .width('100%')
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
          }
          .width('62%')
          .height('72%')
          .backgroundColor('#222222')
          .borderRadius(14)
          .padding(22)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000aa')
        .justifyContent(FlexAlign.Center)
      }

      // 家长锁：输入 4 位 PIN，解锁本次运行内被隐藏的二级分类
      if (this.pinOpen) {
        Column() {
          Column() {
            Text('家长锁').fontSize(20).fontColor('#ffffff').fontWeight(FontWeight.Bold)
            Text('输入 4 位 PIN 解锁')
              .fontSize(13).fontColor('#9aa9b8').margin({ top: 8 })
            TextInput({ text: this.pinInput, placeholder: '4 位数字' })
              .width('100%').height(48).fontSize(18)
              .fontColor('#ffffff').placeholderColor('#777777')
              .backgroundColor('#2a2a2a').borderRadius(8)
              // NUMBER_PASSWORD = 数字键盘 + 圆点掩码，电视上不显示明文也不弹全键盘
              .type(InputType.NUMBER_PASSWORD)
              .showPasswordIcon(false)
              .enableAutoFill(false)
              .inputFilter('[0-9]')
              .maxLength(4)
              .margin({ top: 16 })
              .defaultFocus(true)
              .onChange((v: string) => { this.pinInput = v; })
            if (this.pinErr.length > 0) {
              Text(this.pinErr).fontSize(13).fontColor('#ff9999').width('100%').margin({ top: 8 })
            }
            Row() {
              Button('取消')
                .fontSize(14).height(40).backgroundColor('#3a3a3a').fontColor('#ffffff')
                .onClick(() => { this.pinOpen = false; })
              Button('解锁')
                .fontSize(14).height(40).backgroundColor('#FF6B00').fontColor('#ffffff')
                .margin({ left: 12 })
                .onClick(() => { this.confirmPin(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: 16 })
          }
          .width(400)
          .backgroundColor('#222222')
          .borderRadius(14)
          .padding(24)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000aa')
        .justifyContent(FlexAlign.Center)
      }

      // 收集反馈：不管站点浮层开没开都能看见，且不吃遥控器点击
      if (this.toast) {
        Column() {
          Text(this.toast)
            .fontSize(15)
            .fontColor('#ffffff')
            .backgroundColor('#e6333333')
            .padding({ left: 24, right: 24, top: 12, bottom: 12 })
            .borderRadius(22)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: 46 })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#161616')
  }
}
