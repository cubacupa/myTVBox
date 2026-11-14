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
import { SideNav } from '../components/SideNav';
import { RatingStore } from '../utils/RatingStore';
import { PosterStore } from '../utils/PosterStore';
import { HttpUtil } from '../utils/HttpUtil';
import { PinStore } from '../utils/PinStore';
import { DoubanAuth } from '../utils/DoubanAuth';

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

/** 从首页「查看全部」进来时带的参数 */
interface LibParams {
  typeId?: string;
  typeName?: string;
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
  /** 从首页「查看全部」带过来的分类 id：进页面后直接落到这一栏 */
  private wantTypeId: string = '';
  @State page: number = 1;
  @State pageCount: number = 1;
  /** 当前分类的真实总数（接口 total）。0 = 站点没给，界面就不显示数量 */
  @State totalCount: number = 0;
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
  /** 灵犀遥控器按鼠标上报：hover 与 focus 都要能点亮 */
  @State hoverId: string = '';
  @State focusId: string = '';
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
    return this.inMySites(s.api) ? '已在 Default' : '收进 Default';
  }

  /** 顶栏「收进 Default」按钮的图标：已收用对勾，未收用加号 */
  private collectIcon(): Resource {
    const s: SiteCfg | null = AppState.currentSite;
    if (s !== null && this.inMySites(s.api)) {
      return $r('sys.symbol.checkmark_circle');
    }
    return $r('sys.symbol.plus_circle');
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
    if (this.pinInput.trim() !== this.pin) {
      this.pinErr = 'PIN 不对，再试一次';
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
    // 从首页分类行的「查看全部 / 全部 XX」进来时，落到指定分类
    const lp = router.getParams() as LibParams;
    if (lp !== undefined && lp !== null && lp.typeId !== undefined) {
      this.wantTypeId = lp.typeId;
    }
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
    this.pin = PinStore.get(ctx);   // 家长锁：读 4 位 PIN（没设置就是空串）
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
      // 一级点过一次以后二级高亮就永远不亮（暴风影音、淘片都踩过这个坑）。
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
      // 「查看全部」带过来的分类优先：可能是一级（电影），也可能是二级（动作片）
      let useTop: VodClass | null = firstTop;
      let useClass: string = '';
      const wanted: VodClass | null = this.classOf(this.wantTypeId);
      if (wanted !== null) {
        const wpid: string = wanted.type_pid === undefined ? '' : wanted.type_pid.toString();
        if (wpid === '' || wpid === '0') {
          useTop = wanted;
          const kids: VodClass[] = this.childrenOf(this.pidKey(wanted.type_id));
          useClass = kids.length > 0 ? kids[0].type_id : this.pidKey(wanted.type_id);
        } else {
          const parent: VodClass | null = this.classOf(wpid);
          useTop = parent === null ? firstTop : parent;
          useClass = this.pidKey(wanted.type_id);
        }
        this.wantTypeId = '';
      }
      this.curTop = useTop === null ? '' : this.pidKey(useTop.type_id);
      this.applySubs(useTop === null ? [] : this.childrenOf(this.curTop));
      // 落到第一个子分类而不是一级本身：苹果CMS 的一级（电影片/连续剧）
      // 只装着没归到子类的少数片，所以直接进一级经常只有一两部
      this.curClass = useClass.length > 0 ? useClass
        : (this.subs.length > 0 ? this.subs[0].type_id
          : (useTop === null ? '' : this.pidKey(useTop.type_id)));
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
      this.totalCount = r.total;
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
      this.totalCount = r.total;
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

  /** 按 id 找分类（一级二级都找），找不到返回 null */
  private classOf(id: string): VodClass | null {
    if (id.length === 0) {
      return null;
    }
    for (const c of this.classes) {
      if (this.pidKey(c.type_id) === id) {
        return c;
      }
    }
    return null;
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
      this.totalCount = r.total;
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
    this.totalCount = 0;
    this.err = '';
    this.lastSig = '';
    this.classNote = '';
    this.loading = true;
    await ConfigStore.setSite(ctx, s);
    await this.loadAll();
  }

  // ---------------- 视图（现代版：与首页同一套视觉语言） ----------------

  /** 遥控器焦点 + 鼠标悬停（灵犀遥控器按鼠标上报） */
  private hot(id: string): boolean {
    return this.focusId === id || this.hoverId === id;
  }

  private clearHot(id: string): void {
    if (this.focusId === id) {
      this.focusId = '';
    }
  }

  /** 顶栏动作统一分发，@Builder 里不传函数指针 */
  private onTopAction(id: string): void {
    if (id === 'search') {
      router.pushUrl({ url: 'pages/Search' }).catch(() => {});
    } else if (id === 'filter') {
      this.showFilter = true;
    } else if (id === 'sites') {
      this.showSites = true;
    } else if (id === 'collect') {
      this.toggleCurrent();
    }
  }

  /**
   * 「共 N 部」用接口返回的 total，不是已加载条数。
   * 列表是懒加载的，用 items.length 会随着下拉不断变大（20 → 40 → 60），
   * 那是个假数字。站点不返回 total 时干脆不显示，宁缺勿错。
   */
  private countText(): string {
    if (this.totalCount <= 0) {
      return '';
    }
    return '共 ' + this.totalCount.toString() + ' 部';
  }

  /** 顶栏的胶囊按钮：图标 + 文字，焦点/悬停时描边点亮 */
  @Builder
  topAction(id: string, label: string, sym: Resource) {
    Row({ space: 7 }) {
      SymbolGlyph(sym)
        .fontSize(15)
        .fontColor([this.hot(id) ? '#FFD9BC' : '#A5A5B0'])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(label)
        .fontSize(13.5)
        .fontColor(this.hot(id) ? '#FFD9BC' : '#C9C9D4')
    }
    .height(40)
    .padding({ left: 16, right: 18 })
    .borderRadius(20)
    .backgroundColor(this.hot(id) ? '#1C1D25' : '#12FFFFFF')
    .border({ width: this.hot(id) ? 1.5 : 1, color: this.hot(id) ? '#FFD9BC' : '#22FFFFFF' })
    .focusable(true)
    .onFocus(() => { this.focusId = id; })
    .onBlur(() => { this.clearHot(id); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? id : ''; })
    .onClick(() => { this.onTopAction(id); })
  }

  /**
   * 顶栏的「资源站」下拉入口：直接显示当前站点名，右侧一个小三角。
   *
   * 为什么不放图标：站名本身就带表情图标（「🎬暴风资源」），再叠一个硬盘图标
   * 就是两个图标抢位置；而且十尺外看，站名比图标有用得多。
   */
  @Builder
  siteButton() {
    Row({ space: 7 }) {
      Text(this.siteName.length > 0 ? this.siteName : '选择资源站')
        .fontSize(13.5)
        .fontColor((this.hot('sites') || this.showSites) ? '#FFD9BC' : '#C9C9D4')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 200 })
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(11)
        .fontColor([(this.hot('sites') || this.showSites) ? '#FFD9BC' : '#8E8E9A'])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        .rotate({ angle: this.showSites ? 180 : 0 })
        .animation({ duration: 120 })
    }
    .height(40)
    .padding({ left: 16, right: 14 })
    .borderRadius(20)
    .backgroundColor((this.hot('sites') || this.showSites) ? '#1C1D25' : '#12FFFFFF')
    .border({
      width: (this.hot('sites') || this.showSites) ? 1.5 : 1,
      color: (this.hot('sites') || this.showSites) ? '#FFD9BC' : '#22FFFFFF'
    })
    .focusable(true)
    .onFocus(() => { this.focusId = 'sites'; })
    .onBlur(() => { this.clearHot('sites'); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'sites' : ''; })
    .onClick(() => { this.showSites = !this.showSites; })
  }

  /** 一级分类 */
  @Builder
  topChip(c: VodClass) {
    Row() {
      Text(c.type_name)
        .fontSize(16.5)
        .fontWeight(this.pidKey(c.type_id) === this.curTop ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.pidKey(c.type_id) === this.curTop ? '#150A04' : '#C9C9D4')
    }
    .height(40)
    .padding({ left: 20, right: 20 })
    .borderRadius(13)
    .backgroundColor(this.pidKey(c.type_id) === this.curTop ? '#FF8A3D'
      : (this.hot('T' + c.type_id) ? '#1FFFFFFF' : '#12FFFFFF'))
    .shadow(this.pidKey(c.type_id) === this.curTop
      ? { radius: 22, color: '#59FF8A3D', offsetX: 0, offsetY: 6 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .focusable(true)
    .onFocus(() => { this.focusId = 'T' + c.type_id; })
    .onBlur(() => { this.clearHot('T' + c.type_id); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'T' + c.type_id : ''; })
    .onClick(() => { this.switchTop(c); })
  }

  /** 二级分类 */
  @Builder
  subChip(c: VodClass) {
    Row() {
      Text(c.type_name)
        .fontSize(13.5)
        .fontColor(c.type_id === this.curClass ? '#FFB37A' : '#9C9CA8')
    }
    .height(33)
    .padding({ left: 15, right: 15 })
    .borderRadius(11)
    .backgroundColor(c.type_id === this.curClass ? '#22FF8A3D'
      : (this.hot('S' + c.type_id) ? '#1AFFFFFF' : '#0DFFFFFF'))
    .border({
      width: 1,
      color: c.type_id === this.curClass ? '#73FF8A3D'
        : (this.hot('S' + c.type_id) ? '#2EFFFFFF' : Color.Transparent)
    })
    .focusable(true)
    .onFocus(() => { this.focusId = 'S' + c.type_id; })
    .onBlur(() => { this.clearHot('S' + c.type_id); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'S' + c.type_id : ''; })
    .onClick(() => { this.switchClass(c); })
  }

  /** 排序 / 方向 / 解锁这一排小胶囊 */
  @Builder
  miniPill(id: string, label: string, on: boolean, accent: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontWeight(on ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(on ? (accent ? '#150A04' : '#FFB37A') : '#9C9CA8')
    }
    .height(32)
    .padding({ left: 14, right: 14 })
    .borderRadius(11)
    .backgroundColor(on ? (accent ? '#FF8A3D' : '#22FF8A3D')
      : (this.hot(id) ? '#1AFFFFFF' : '#0DFFFFFF'))
    .border({ width: 1, color: on ? Color.Transparent : (this.hot(id) ? '#2EFFFFFF' : Color.Transparent) })
    .focusable(true)
    .onFocus(() => { this.focusId = id; })
    .onBlur(() => { this.clearHot(id); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? id : ''; })
    .onClick(() => { this.onPill(id); })
  }

  /** 受限分类总数：解锁按钮上的数字按它算，不用管受限项挂在一级还是二级 */
  private lockTotal(): number {
    return this.lockedTopCount + this.lockedCount;
  }

  /** 解锁入口：位置固定在一级分类行最右端，样式独立于排序胶囊，带锁图标更好认 */
  @Builder
  lockChip() {
    Row({ space: 6 }) {
      SymbolGlyph(this.unlocked ? $r('sys.symbol.lock_open_fill') : $r('sys.symbol.lock_fill'))
        .fontSize(12)
        .fontColor(['#FFB37A'])
        .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      Text(this.unlocked ? '重新上锁' : '解锁 ' + this.lockTotal().toString())
        .fontSize(12.5)
        .fontColor('#FFB37A')
        .maxLines(1)
    }
    .height(32)
    .padding({ left: 12, right: 13 })
    .borderRadius(11)
    .backgroundColor(this.hot('lock') ? '#2EFF8A3D' : '#1AFF8A3D')
    .border({ width: 1, color: '#73FF8A3D' })
    .margin({ left: 12 })
    .focusable(true)
    .onFocus(() => { this.focusId = 'lock'; })
    .onBlur(() => { this.clearHot('lock'); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'lock' : ''; })
    .onClick(() => { this.onPill('lock'); })
  }

  private onPill(id: string): void {
    if (id === 's-dir') {
      this.toggleSortDir();
    } else if (id === 's-new') {
      this.setSort(SORT_NEW);
    } else if (id === 's-score') {
      this.setSort(SORT_SCORE);
    } else if (id === 'lock') {
      if (this.unlocked) {
        this.relockVod();
      } else {
        this.openPinDialog();
      }
    }
  }

  /** 顶栏 + 分类区 + 海报墙 */
  @Builder
  main() {
    Column() {
      // ---------- 顶栏 ----------
      Row() {
        // 标题 / 计数 / 说明并成一行：小字另起一行会把顶栏撑高，显得又空又挤
        Row({ space: 12 }) {
          Text('点播')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          if (this.countText().length > 0) {
            Text(this.countText())
              .fontSize(12.5)
              .fontColor('#8E8E9A')
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(7)
              .backgroundColor('#12FFFFFF')
          }
          if (this.totalCount > 0) {
            Text('按最新上架排序 · 下拉站点切换')
              .fontSize(12.5)
              .fontColor('#7E7E8A')
          }
        }
        // 居中对齐：34 号标题的行框比小字高得多，底对齐会让小字贴到字形底缘，
        // 看着像被往下拽了一截
        .alignItems(VerticalAlign.Center)

        Blank()

        Row({ space: 10 }) {
          this.topAction('search', '搜索', $r('sys.symbol.magnifyingglass'))
          this.topAction('filter',
            this.activeFilterCount() > 0 ? '筛选 ' + this.activeFilterCount().toString() : '筛选',
            $r('sys.symbol.line_3_horizontal'))
          this.siteButton()
          this.topAction('collect', this.collectLabel(), this.collectIcon())
        }
      }
      .width('100%')
      .height(56)
      .padding({ left: 44, right: 36 })
      .margin({ top: 26 })

      // ---------- 一级分类 + 排序 ----------
      Row() {
        List({ space: 9 }) {
          ForEach(this.tops, (c: VodClass) => {
            ListItem() {
              this.topChip(c)
            }
          }, (c: VodClass) => 'T' + c.type_id)
        }
        .listDirection(Axis.Horizontal)
        .height(48)
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        // 排序：采集站 API 不认 order 参数，能真正改变结果的只有两个维度 + 一个方向
        Row({ space: 7 }) {
          this.miniPill('s-dir', this.sortAsc ? '升序 ↑' : '降序 ↓', false, false)
          this.miniPill('s-new', '最新', this.sortMode === SORT_NEW, true)
          this.miniPill('s-score', '评分', this.sortMode === SORT_SCORE, true)
        }
        .margin({ left: 12 })

        // 解锁入口**固定在这一行的最右端**：原来它跟着「受限项在一级还是二级」两头跑，
        // 有时挂在一级分类行、有时挤到二级分类行末尾，看起来位置飘忽。
        // 现在不管当前分类下有没有受限项，入口永远在同一个位置。
        if (this.lockTotal() > 0 && this.pin.length > 0) {
          this.lockChip()
        }
      }
      .width('100%')
      .height(48)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 44, right: 36 })
      .margin({ top: 2 })

      // ---------- 二级分类 ----------
      if (this.subs.length > 0) {
        Row() {
          List({ space: 8 }) {
            ForEach(this.subs, (c: VodClass) => {
              ListItem() {
                this.subChip(c)
              }
            }, (c: VodClass) => 'S' + c.type_id)
          }
          .listDirection(Axis.Horizontal)
          .height(40)
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)
        .padding({ left: 44, right: 36 })
        .margin({ top: 8 })
      }

      // 站点分类接口没真过滤时，点完给一句说明，别让用户以为点坏了
      if (this.classNote.length > 0) {
        Row() {
          Text(this.classNote)
            .fontSize(12.5)
            .fontColor('#FFB37A')
            .backgroundColor('#1AFF8A3D')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(9)
            .maxLines(2)
        }
        .width('100%')
        .padding({ left: 44, right: 36 })
        .margin({ top: 8 })
      }

      // 已选筛选条件回显
      if (this.activeFilterCount() > 0) {
        Row() {
          ForEach(this.sels, (s: FilterSel, i: number) => {
            if (s.value) {
              Text(s.label)
                .fontSize(11.5)
                .fontColor('#FFB37A')
                .backgroundColor('#1AFF8A3D')
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(8)
                .margin({ right: 8 })
            }
          }, (s: FilterSel, i: number) => s.key + s.value)
        }
        .width('100%')
        .padding({ left: 44, right: 36 })
        .margin({ top: 8 })
      }

      // ---------- 主区 ----------
      if (this.needConfig) {
        Column({ space: 16 }) {
          Text('还没有可用的点播站点')
            .fontSize(24)
            .fontColor('#FFFFFF')
          Text('去「设置」载入一个配置地址')
            .fontSize(14)
            .fontColor('#9C9CA8')
          Text('打开设置')
            .fontSize(15)
            .fontColor('#150A04')
            .height(46)
            .padding({ left: 26, right: 26 })
            .borderRadius(23)
            .backgroundColor('#FF8A3D')
            .textAlign(TextAlign.Center)
            .focusable(true)
            .onClick(() => { router.replaceUrl({ url: 'pages/Settings' }).catch(() => {}); })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.loading && this.items.length === 0) {
        Column({ space: 12 }) {
          LoadingProgress().width(44).height(44).color('#FF8A3D')
          Text('正在加载…')
            .fontSize(13.5)
            .fontColor('#8E8E9A')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        if (this.err.length > 0) {
          Text(this.err)
            .fontSize(13)
            .fontColor('#FF8B7A')
            .width('100%')
            .padding({ left: 44, top: 8 })
        }
        Grid() {
          ForEach(this.items, (item: VodItem) => {
            GridItem() {
              PosterCard({
                item: item,
                modern: true,
                cardW: 172,
                cardH: 258,
                onSelect: () => this.goDetail(item)
              })
            }
          }, (item: VodItem) => String(item.site_key ? item.site_key : '') + '_' + String(item.vod_id))
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
        .columnsGap(16)
        .rowsGap(20)
        // 左 44 + 右 36 = 1112，正好 6×172 + 5×16，卡片与栅格严丝合缝
        .padding({ left: 44, right: 36, top: 14, bottom: 26 })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(6)
        .onReachEnd(() => { this.loadMore(); })

        // 翻页提示：加载下一批时给个明确的在跑的信号
        if (this.loading && this.items.length > 0) {
          Row({ space: 8 }) {
            LoadingProgress().width(16).height(16).color('#FF8A3D')
            Text('正在加载更多…')
              .fontSize(12)
              .fontColor('#8E8E9A')
          }
          .width('100%')
          .padding({ left: 44, bottom: 10 })
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------- 背景：暗底 + 顶部一层琥珀暖光 ----------
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#1F1A1208', 0.0], ['#0C08090B', 0.45], ['#08090B', 1.0]]
        })

      Row() {
        SideNav({ active: 1, siteName: this.siteName })
        // 必须 layoutWeight(1)：写 width('100%') 会按整个 Row 的宽度算，
        // 再加上左边 88 的导航栏就顶出屏幕
        Column() {
          this.main()
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')

      // ---------- 资源站下拉菜单：贴着顶栏按钮正下方展开 ----------
      if (this.showSites) {
        // 点空白处收起（透明遮罩，不压暗：这是下拉，不是模态）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#01000000')
          .onClick(() => { this.showSites = false; })

        Column() {
          Row() {
            Text('切换资源站')
              .fontSize(12)
              .fontColor('#7E7E8A')
            Blank()
            Text(this.sites.length.toString() + ' 个')
              .fontSize(11.5)
              .fontColor('#5F5F6B')
          }
          .width('100%')
          .padding({ left: 4, right: 4 })
          .margin({ bottom: 9 })

          List({ space: 6 }) {
            ForEach(this.sites, (s: SiteCfg) => {
              ListItem() {
                Row() {
                  Text(s.name)
                    .fontSize(15)
                    .fontColor(s.key === this.siteKey ? '#FFB37A' : '#DDDDE6')
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .padding({ left: 14, right: 12, top: 11, bottom: 11 })
                    .backgroundColor(s.key === this.siteKey ? '#22FF8A3D' : Color.Transparent)
                    .borderRadius(11)
                    .border({
                      width: 1,
                      color: s.key === this.siteKey ? '#73FF8A3D' : Color.Transparent
                    })
                    .focusable(true)
                    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'st_' + s.key : ''; })
                    .onClick(() => { this.switchSite(s); })
                  Text(this.mySiteLabel(s))
                    .fontSize(11.5)
                    .fontColor(this.inMySites(s.api) ? '#8FE09A' : '#FFB37A')
                    .backgroundColor('#12FFFFFF')
                    .padding({ left: 10, right: 10, top: 11, bottom: 11 })
                    .borderRadius(11)
                    .margin({ left: 6 })
                    .focusable(true)
                    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'cl_' + s.key : ''; })
                    .onClick(() => { this.toggleMySite(s); })
                }
                .width('100%')
              }
            }, (s: SiteCfg) => s.key + '_' + this.myRev)
          }
          .width('100%')
          .constraintSize({ maxHeight: 300 })
          .scrollBar(BarState.Off)

          Text('点站名切换 · 右侧按钮把站收进 Default')
            .fontSize(10.5)
            .fontColor('#5F5F6B')
            .width('100%')
            .padding({ left: 4 })
            .margin({ top: 10 })
        }
        .width(340)
        .padding(16)
        .backgroundColor('#14151C')
        .border({ width: 1, color: '#1AFFFFFF' })
        .borderRadius(18)
        .shadow({ radius: 44, color: '#B3000000', offsetX: 0, offsetY: 18 })
        // 右边缘与顶栏按钮对齐：1280 - 36(右内距) - 340(菜单宽)
        .position({ x: 904, y: 88 })
      }

      // ---------- 筛选浮层 ----------
      if (this.showFilter) {
        Column() {
          Column() {
            Row() {
              Text('筛选')
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Blank()
              Row() {
                Text('重置')
                  .fontSize(13.5)
                  .fontColor('#C9C9D4')
              }
              .height(36)
              .padding({ left: 18, right: 18 })
              .borderRadius(18)
              .backgroundColor('#1FFFFFFF')
              .focusable(true)
              .onClick(() => { this.resetFilters(); })
              Row() {
                Text('关闭')
                  .fontSize(13.5)
                  .fontColor('#150A04')
              }
              .height(36)
              .padding({ left: 18, right: 18 })
              .borderRadius(18)
              .backgroundColor('#FF8A3D')
              .margin({ left: 10 })
              .focusable(true)
              .onClick(() => { this.showFilter = false; })
            }
            .width('100%')
            .margin({ bottom: 16 })

            Scroll() {
              Column() {
                ForEach(this.filterGroups, (g: FilterGroup, gi: number) => {
                  Column() {
                    Text(g.name)
                      .fontSize(12.5)
                      .fontColor('#7E7E8A')
                      .width('100%')
                      .margin({ bottom: 9 })
                    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
                      ForEach(g.values, (v: FilterValue) => {
                        Text(v.n)
                          .fontSize(13.5)
                          .fontColor(this.isSel(gi, v.v) ? '#150A04' : '#C9C9D4')
                          .backgroundColor(this.isSel(gi, v.v) ? '#FF8A3D' : '#12FFFFFF')
                          .padding({ left: 15, right: 15, top: 9, bottom: 9 })
                          .borderRadius(11)
                          .margin({ right: 9, bottom: 9 })
                          .focusable(true)
                          .onClick(() => { this.pickFilter(gi, v); })
                      }, (v: FilterValue) => g.key + '_' + v.v + '_' + v.n)
                    }
                    .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .margin({ bottom: 16 })
                }, (g: FilterGroup) => g.key)
              }
              .width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 440 })
            .align(Alignment.Top)
            .scrollBar(BarState.Off)
          }
          .width('62%')
          .constraintSize({ maxHeight: '78%' })
          .backgroundColor('#14151C')
          .border({ width: 1, color: '#1AFFFFFF' })
          .borderRadius(22)
          .padding(24)
          .shadow({ radius: 60, color: '#B3000000', offsetX: 0, offsetY: 24 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
      }

      // ---------- 家长锁 ----------
      if (this.pinOpen) {
        Column() {
          Column() {
            Text('家长锁')
              .fontSize(19)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Text('输入 4 位 PIN 解锁')
              .fontSize(12.5)
              .fontColor('#8E8E9A')
              .margin({ top: 8 })
            TextInput({ text: this.pinInput, placeholder: '4 位数字' })
              .width('100%')
              .height(48)
              .fontSize(18)
              .fontColor('#FFFFFF')
              .placeholderColor('#6E6E7A')
              .backgroundColor('#12FFFFFF')
              .borderRadius(12)
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
              Text(this.pinErr)
                .fontSize(12.5)
                .fontColor('#FF8B7A')
                .width('100%')
                .margin({ top: 8 })
            }
            Row({ space: 10 }) {
              Row() {
                Text('取消')
                  .fontSize(13.5)
                  .fontColor('#C9C9D4')
              }
              .height(40)
              .padding({ left: 20, right: 20 })
              .borderRadius(20)
              .backgroundColor('#1FFFFFFF')
              .focusable(true)
              .onClick(() => { this.pinOpen = false; })
              Row() {
                Text('解锁')
                  .fontSize(13.5)
                  .fontColor('#150A04')
              }
              .height(40)
              .padding({ left: 22, right: 22 })
              .borderRadius(20)
              .backgroundColor('#FF8A3D')
              .focusable(true)
              .onClick(() => { this.confirmPin(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: 18 })
          }
          .width(400)
          .backgroundColor('#14151C')
          .border({ width: 1, color: '#1AFFFFFF' })
          .borderRadius(22)
          .padding(24)
          .shadow({ radius: 60, color: '#B3000000', offsetX: 0, offsetY: 24 })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
      }

      // ---------- 收集反馈（不吃遥控器点击） ----------
      if (this.toast) {
        Column() {
          Text(this.toast)
            .fontSize(14.5)
            .fontColor('#F2F2F6')
            .backgroundColor('#E61A1B22')
            .border({ width: 1, color: '#1AFFFFFF' })
            .padding({ left: 22, right: 22, top: 12, bottom: 12 })
            .borderRadius(20)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .padding({ bottom: 42 })
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}
