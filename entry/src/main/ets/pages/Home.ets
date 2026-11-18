import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../utils/AppState';
import { ConfigStore } from '../utils/ConfigStore';
import { SiteApi, VodListResult } from '../utils/SiteApi';
import { VodItem, VodClass } from '../model/VodItem';
import { SiteCfg } from '../model/TvBoxModels';
import { MarkStore, VodMark } from '../utils/MarkStore';
import { RatingStore } from '../utils/RatingStore';
import { PosterStore } from '../utils/PosterStore';
import { BackdropStore } from '../utils/BackdropStore';
import { HttpUtil } from '../utils/HttpUtil';
import { ImageCache } from '../utils/ImageCache';
import { DoubanAuth } from '../utils/DoubanAuth';
import { PinStore } from '../utils/PinStore';
import { SideNav } from '../components/SideNav';

/**
 * 影视盒 · 首页
 *
 * 版式基准：1280×720 vp（4K 屏 density 3）。
 *
 * 页面结构（顺序固定，空的整行不画）：
 *   0) 随机推荐 20 部（各分类轮流抽）—— 同时也是主推位的「换片开关」
 *   1) 我的收藏（可能空）
 *   2) 继续观看 = 播放历史（可能空）
 *
 * 主推位固定就是「随机推荐」里当前选中的那一部：进页面随机，点下方缩略图直接换。
 *   缩略图点击 = 换主推，不进详情（详情从「播放」按钮进），这样整行都是翻页键。
 *
 * 横版剧照直接铺满整个页面做背景（整屏 Cover），上面压一层**轻量**遮罩：
 * 只有左侧和底部加重，右侧留出一大块干净的图，主推位才有一眼看到画面的气势。
 * 抓不到剧照时用内置的 hero_fallback 兜底，不会退回一块纯黑背景。
 *
 * 主推位不放海报：片名 / 元信息 / 简介 / 按钮直接压在整屏剧照上，不再套毛玻璃背板。
 * 可读性靠底部遮罩自带的左侧/底部压黑；文字本身有描边级阴影兜底。
 *
 * 收藏 / 历史是本机全量记录，横向 List 直接铺完、可以一直滑到底，
 * 所以这两行不再放「查看全部」（原来截断 14 部时才需要那个入口）。
 */
/** 随机推荐凑几部（这一行同时是主推位的候选池） */
const HERO_MAX: number = 20;
/** 加载骨架画几张空卡：和首屏能露出的张数差不多，多了也没人看见 */
const SKELETON_SLOTS: number[] = [0, 1, 2, 3, 4];

/** 「换一批」时抽几个分类：每个分类出一页，够凑 20 部又不至于等太久 */
const PICK_CLS: number = 6;

/**
 * 首页不抽的分类（名字里带这些字就跳过，父分类命中则整支子分类一起跳过）。
 * 实测暴风资源的分类：理论片(29)、福利(67) 是擦边；体育赛事(53) 及其足球/篮球/网球/斯诺克
 * 是直播录像，既没有豆瓣条目也抓不到剧照；电影解说(51)/预告片(52) 不是正片；
 * 短剧大全(58) 是一两分钟一集的竖屏短剧，放主推不合适。
 */
const PICK_BAD: string[] = [
  '解说', '预告', '花絮', '片花', '专题',
  '体育', '赛事', '足球', '篮球', '网球', '斯诺克', '台球',
  '理论', '伦理', '福利', '写真', '美女', '性感', '成人', '情色',
  '短剧', '游戏', '资讯'
];

/**
 * 首页**只收这些一级分类**（名字里带任一词）。
 * 为什么不继续用黑名单：站点分类是活的，今天加个「综艺片」、明天加个「纪实频道」，
 * 黑名单永远追不上；白名单只认影视正片，其余（体育、综艺、游戏、资讯、直播录像）
 * 一律不进随机池，主推位不会突然冒出一段比赛录像或一期综艺。
 * 判的是**一级分类**：电影片的子类是「动作片/喜剧片」，名字里没有「电影」，
 * 所以白名单只在摊平前对一级分类生效。
 */
const PICK_OK: string[] = ['电影', '剧', '动漫', '动画', '纪录'];

/** 片名兜底：分类没写清但片子本身明显不是正片的，从随机池里剔掉 */
const PICK_BAD_TITLE: string[] = [
  '性感', '美臀', '写真', '无码', '巨乳', '情色', '成人', '自慰'
];

/** 一行的来源类型 */
const K_FAV: string = 'fav';
const K_HIS: string = 'his';

/** 主推位条目 */
interface HeroItem {
  siteKey: string;
  vodId: string;
  name: string;
  pic: string;
  remarks: string;
  typeName: string;
  year: string;
  score: string;
  doubanId: string;
  badge: string;
  /** 剧情简介：列表接口自带 vod_content，已去掉 HTML 与多余空白 */
  content: string;
  /** 制片地区 / 语言，拼在元信息后面 */
  area: string;
}

/** 一行片单：收藏 / 历史的本机记录 */
interface Shelf {
  kind: string;
  title: string;
  marks: VodMark[];
}

/** 随机推荐批次的存放键（AppStorage，应用级） */
const KEY_PICKS: string = 'homePicks';

/**
 * 随机推荐的批次缓存：**App 启动后只抽一次**，之后进出首页都沿用这一批。
 *
 * 之前每进一次首页就重新抽，是因为侧栏走的是 router.replaceUrl：切到点播再回来，
 * 页面实例是新建的，@State 里的候选池自然没了，boot() 又抽了一轮。
 * 放**模块级变量**没用：实测 page 文件自身的模块会随页面一起销毁重建，变量跟着归零，
 * 所以存在 AppStorage 里 —— 它是整个 UI 实例一份，跨页面存活，进程重启才清空，
 * 正好等于「启动时抽一次」。
 * 只有两种情况会换：用户点「换一批」，或者换了站点（siteKey 不同）。
 * 存 JSON 字符串而不是对象：省得纠结 ArkTS 对 AppStorage 里嵌套对象数组的序列化。
 */
class PicksPayload {
  siteKey: string = '';
  heroes: HeroItem[] = [];
}

@Entry
@Component
struct Home {
  @State heroes: HeroItem[] = [];
  /** 正在换一批（按钮换成「换一批中…」，防止连点） */
  @State picking: boolean = false;
  /** 站点分类列表，只用于随机抽片，不渲染 */
  private allCls: VodClass[] = [];
  /** 家长锁 PIN（没设置就是空串）；只用来决定首页要不要遮住受限片子 */
  private pin: string = '';
  @State heroIdx: number = 0;
  @State shelves: Shelf[] = [];
  /** 加载中：骨架呼吸动画跟着它启停，别让定时器空转 */
  @State @Watch('onLoadingChange') loading: boolean = true;
  /** 骨架呼吸相位：0/1 来回切，驱动明暗，让"还在拉片单"第一屏就能看见 */
  @State skelPhase: number = 0;
  private skelTimer: number = -1;
  @State err: string = '';
  @State siteName: string = '';
  @State needConfig: boolean = false;
  @State focusId: string = '';
  /** 灵犀遥控器是鼠标：hover 和 focus 都要能点亮 */
  @State hoverId: string = '';
  /** 当前主推位的收藏态：缓存下来，避免每帧读一次本地收藏文件 */
  @State heroFavState: boolean = false;
  /** 主推位的横版剧照（本地 file:// 路径），空则退回模糊海报铺底 */
  @State backdrop: string = '';
  /** 豆瓣类型缓存更新的信号：读一下即可让 hero 标签重绘 */
  @State metaTick: number = 0;
  /** 评分/海报/横版图的后台更新信号，读一下即可触发重绘 */
  @StorageProp('ratingTick') ratingTick: number = 0;
  @StorageProp('posterTick') posterTick: number = 0;
  @StorageProp('backdropTick') @Watch('onBackdropTick') backdropTick: number = 0;
  /** 站点外链海报本地化完成的信号：读一下即可让卡片重绘出图（全局，三页共用） */
  @StorageProp('sitePicTick') picTick: number = 0;

  private loadSeq: number = 0;
  /** 收藏 + 历史的指纹：返回首页时只有它变了才重新拉片单 */
  private rowSig: string = '';

  aboutToAppear(): void {
    this.startSkeletonAnim();
    this.boot();
  }

  aboutToDisappear(): void {
    this.stopSkeletonAnim();
  }

  /** 只在加载期让骨架明暗呼吸；数据一到就停，不空转定时器 */
  private onLoadingChange(): void {
    if (this.loading) {
      this.startSkeletonAnim();
    } else {
      this.stopSkeletonAnim();
    }
  }

  private startSkeletonAnim(): void {
    if (this.skelTimer >= 0) {
      return;
    }
    this.skelTimer = setInterval(() => {
      this.skelPhase = 1 - this.skelPhase;
    }, 520);
  }

  private stopSkeletonAnim(): void {
    if (this.skelTimer >= 0) {
      clearInterval(this.skelTimer);
      this.skelTimer = -1;
    }
  }

  /** 骨架明暗：亮 1 / 暗 0.28，反差拉到肉眼明显；过渡由各骨架条自己的 .animation() 完成 */
  private skelOpacity(): number {
    return this.skelPhase === 0 ? 1 : 0.28;
  }

  onPageShow(): void {
    // 从详情页回来：收藏 / 历史可能变了，变了才重排，没变不打扰
    if (!this.loading && this.signature() !== this.rowSig) {
      this.loadContent();
    }
  }

  // ---------------- 数据 ----------------

  private async boot(): Promise<void> {
    this.loading = true;
    const ctx = getContext(this) as common.Context;
    this.pin = PinStore.get(ctx);
    HttpUtil.init(ctx);
    DoubanAuth.init(ctx);
    RatingStore.init(ctx);
    PosterStore.init(ctx);
    BackdropStore.init(ctx);
    try {
      await ConfigStore.init(ctx);
    } catch (e) {
      this.err = (e as Error).message;
    }
    const site = AppState.currentSite;
    if (site === null) {
      this.needConfig = true;
      this.loading = false;
      return;
    }
    this.siteName = site.name;
    this.needConfig = false;
    await this.loadContent();
  }

  /**
   * 设了家长锁且当前没解锁时，把受限分类里的收藏 / 观看记录从首页行里剔掉。
   * 只锁「点播分类」而首页照旧展示，等于锁了个寂寞：主推位旁边那行
   * 「继续观看」会把片子名和海报直接摆出来。规则与点播页/记录页保持一致，
   * 从任一处解锁（点播分类或记录页）都算解锁，避免出现「解锁了首页还藏着」。
   */
  private visibleMarks(src: VodMark[]): VodMark[] {
    if (this.pin.length === 0 || PinStore.isVodUnlocked() || PinStore.isHistoryUnlocked()) {
      return src;
    }
    const out: VodMark[] = [];
    for (const m of src) {
      const tn: string = m.typeName === undefined ? '' : m.typeName;
      if (tn.length > 0) {
        if (PinStore.isRestricted(tn)) {
          continue;
        }
      } else if (PinStore.isRestricted(m.name ?? '')) {
        continue;
      }
      out.push(m);
    }
    return out;
  }

  /** 收藏 + 历史前几部的指纹 */
  private signature(): string {
    const ctx = getContext(this) as common.Context;
    const favs: VodMark[] = MarkStore.listFav(ctx);
    const his: VodMark[] = MarkStore.listHistory(ctx);
    let s: string = favs.length.toString() + ':';
    for (let i = 0; i < favs.length && i < 8; i++) {
      s += favs[i].vodId + ',';
    }
    s += '|' + his.length.toString() + ':';
    const hn: number = Math.min(his.length, 5);
    for (let i = 0; i < hn; i++) {
      s += his[i].vodId + his[i].remarks + ',';
    }
    s += '|L' + (this.pin.length === 0 ? '-' : (PinStore.isVodUnlocked() ? 'v' : (PinStore.isHistoryUnlocked() ? 'h' : '0')));
    return s;
  }

  private picOfMark(m: VodMark): string {
    const probe: VodItem = { vod_id: m.vodId, vod_name: m.name, vod_pic: m.pic };
    const local: string = PosterStore.localOf(probe);
    if (local.length > 0) {
      return local;
    }
    let p: string = m.pic.trim();
    if (p.startsWith('//')) {
      p = 'https:' + p;
    }
    return p;
  }

  private scoreOfMark(m: VodMark): string {
    if (this.ratingTick < 0) {
      return '';
    }
    const probe: VodItem = { vod_id: m.vodId, vod_name: m.name, vod_pic: m.pic };
    return RatingStore.label(probe);
  }

  private heroFromItem(it: VodItem, siteKey: string, badge: string): HeroItem {
    const raw: string | number | undefined = it.vod_douban_id;
    const did: string = raw === undefined || raw === null ? '' : raw.toString().trim();
    return {
      siteKey: it.site_key !== undefined && it.site_key.length > 0 ? it.site_key : siteKey,
      vodId: it.vod_id.toString(),
      name: it.vod_name,
      pic: this.picOf(it),
      remarks: it.vod_remarks === undefined ? '' : it.vod_remarks,
      typeName: it.type_name === undefined ? '' : it.type_name,
      year: it.vod_year === undefined ? '' : it.vod_year,
      score: this.scoreOf(it),
      doubanId: did === '0' ? '' : did,
      badge: badge,
      content: this.plotOf(it.vod_content),
      area: it.vod_area === undefined ? '' : it.vod_area
    };
  }

  /** 某个一级分类下的二级分类 */
  private childrenOf(all: VodClass[], pid: string): VodClass[] {
    const out: VodClass[] = [];
    if (pid.length === 0) {
      return out;
    }
    for (const c of all) {
      const p: string = c.type_pid === undefined ? '' : c.type_pid.toString();
      if (p === pid) {
        out.push(c);
      }
    }
    return out;
  }

  private async loadContent(): Promise<void> {
    const site = AppState.currentSite;
    if (site === null) {
      return;
    }
    const ctx = getContext(this) as common.Context;
    const seq: number = ++this.loadSeq;
    this.err = '';
    this.rowSig = this.signature();
    try {
      const rows: Shelf[] = [];

      // ---- 1) 继续观看（播放历史）----
      // 放在收藏上面：刚看过的片是「现在就要接着看」的，比静态收藏更该先看到
      const his: VodMark[] = this.visibleMarks(MarkStore.listHistory(ctx));
      if (his.length > 0) {
        rows.push({
          kind: K_HIS, title: '继续观看',
          marks: his
        });
      }

      // ---- 2) 我的收藏 ----
      const favs: VodMark[] = this.visibleMarks(MarkStore.listFav(ctx));
      if (favs.length > 0) {
        rows.push({
          kind: K_FAV, title: '我的收藏',
          marks: favs
        });
      }

      // ---- 3) 随机推荐 ----
      // 首页只铺本机收藏 / 历史；分类列表仍要拉，随机推荐那 20 部就是从这些分类里抽的。
      this.shelves = rows;
      this.loading = false;
      this.warmPics();
      try {
        const rawCls: VodClass[] = await SiteApi.getClasses(site);
        if (seq !== this.loadSeq) {
          return;
        }
        this.allCls = rawCls;
      } catch (e) {
        this.allCls = [];
      }
      if (seq !== this.loadSeq) {
        return;
      }
      // 推荐批次本进程只抽一次：有缓存就直接用，切页回来不会换片
      const cached: HeroItem[] | null = this.cachedPicks(site.key);
      if (cached !== null) {
        console.info('[home] picks cache HIT n=' + cached.length);
        this.useCached(cached);
      } else {
        console.info('[home] picks cache MISS');
        await this.repick(false);
      }
      if (seq !== this.loadSeq) {
        return;
      }
      if (this.heroes.length === 0 && rows.length === 0) {
        this.err = '当前接口没有返回任何内容，可以在设置里换个站点';
      }
      const h: HeroItem | null = this.hero();
      console.info('[home] rows=' + rows.length + ' picks=' + this.heroes.length
        + ' hero=' + (h === null ? '-' : h.name));
    } catch (e) {
      if (seq === this.loadSeq) {
        this.err = (e as Error).message;
        this.loading = false;
      }
    }
  }

  /**
   * 随机推荐 20 部：先把每个分类各自打乱，再「轮转抽取」——
   * 第 1 轮每个分类各出 1 部，第 2 轮再各出 1 部……
   * 不直接整体随机的原因：动作片一个分类就有 5000 多部，整体随机的话
   * 20 个名额会被它吃光，其它分类一部都进不来。
   */
  private picksFromGroups(groups: VodItem[][], names: string[], siteKey: string): HeroItem[] {
    const pools: VodItem[][] = [];
    const titles: string[] = [];
    for (let i = 0; i < groups.length; i++) {
      const clean: VodItem[] = [];
      for (const it of groups[i]) {
        const tn: string = it.type_name === undefined ? '' : it.type_name;
        if (PinStore.isRestricted(tn)) {
          continue;
        }
        if (!this.hitBad(it.vod_name, PICK_BAD_TITLE)) {
          clean.push(it);
        }
      }
      if (clean.length > 0) {
        pools.push(this.shuffled(clean));
        titles.push(i < names.length ? names[i] : '');
      }
    }
    const out: HeroItem[] = [];
    if (pools.length === 0) {
      return out;
    }
    let round: number = 0;
    let more: boolean = true;
    while (out.length < HERO_MAX && more) {
      more = false;
      for (let p = 0; p < pools.length && out.length < HERO_MAX; p++) {
        if (round < pools[p].length) {
          out.push(this.heroFromItem(pools[p][round], siteKey, titles[p]));
          more = true;
        }
      }
      round++;
    }
    return this.shuffledHeroes(out);
  }

  /**
   * 取本进程里已抽好的那一批（同一站点才算命中）。
   * 顺手按家长锁过滤一次：锁定状态是用户后来才开的，缓存里的片子可能已经被锁。
   * 过滤后一部不剩就当作没命中，重新抽。
   */
  private cachedPicks(siteKey: string): HeroItem[] | null {
    const raw: string | undefined = AppStorage.get<string>(KEY_PICKS);
    if (raw === undefined || raw.length === 0) {
      return null;
    }
    let p: PicksPayload;
    try {
      p = JSON.parse(raw) as PicksPayload;
    } catch (e) {
      return null;
    }
    if (p === undefined || p === null || p.siteKey !== siteKey || p.heroes === undefined) {
      return null;
    }
    const out: HeroItem[] = [];
    for (const h of p.heroes) {
      if (PinStore.isRestricted(h.typeName)) {
        continue;
      }
      out.push(h);
    }
    return out.length > 0 ? out : null;
  }

  /** 抽完一批就存起来，供下次进首页直接复用 */
  private savePicks(siteKey: string): void {
    if (this.heroes.length === 0) {
      return;
    }
    const p: PicksPayload = new PicksPayload();
    p.siteKey = siteKey;
    p.heroes = this.heroes;
    AppStorage.setOrCreate<string>(KEY_PICKS, JSON.stringify(p));
  }

  /** 有缓存就直接上屏（切页回来走的都是这条路，不会再抽） */
  private useCached(h: HeroItem[]): void {
    this.heroes = h;
    this.heroIdx = 0;
    this.syncHero();
    this.warmPics();
  }

  /**
   * 「换一批」：重新从站点里随机取分类、随机翻页，凑一批全新的 20 部。
   * 不重用首屏那几十部的原因：只洗牌的话第二次点就会看到大量重复，
   * 根本不像「换了一批」。
   */
  private async repick(randomPage: boolean): Promise<void> {
    const site = AppState.currentSite;
    if (site === null || this.picking) {
      return;
    }
    this.picking = true;
    const seq: number = this.loadSeq;
    try {
      const cands: VodClass[] = this.pickCandidates();
      const groups: VodItem[][] = [];
      // 分类名一起带上：卡片下面那行小字要写「动作片」而不是重复 20 次「随机推荐」
      const names: string[] = [];
      for (let i = 0; i < cands.length; i++) {
        if (seq !== this.loadSeq) {
          return;
        }
        try {
          const got: VodItem[] = await this.pageOf(site, cands[i].type_id.toString(), randomPage);
          if (got.length > 0) {
            groups.push(got);
            names.push(cands[i].type_name);
          }
        } catch (e) {
          continue;
        }
      }
      if (groups.length === 0 || seq !== this.loadSeq) {
        return;
      }
      this.heroes = this.picksFromGroups(groups, names, site.key);
      this.heroIdx = 0;
      // 先落缓存再同步界面：同步里要读上下文，页面万一已经被销毁也不能影响这批被记住
      this.savePicks(site.key);
      this.syncHero();
      this.warmPics();
      const warm: VodItem[] = [];
      for (const g of groups) {
        for (const it of g) {
          warm.push(it);
        }
      }
      RatingStore.warm(warm);
      console.info('[home] picks=' + this.heroes.length + ' groups=' + groups.length);
    } finally {
      this.picking = false;
    }
  }

  /** 抽一个分类的一页；randomPage 时随机翻到靠后的页，避免永远是「最新上架那 20 条」 */
  private async pageOf(site: SiteCfg, typeId: string, randomPage: boolean): Promise<VodItem[]> {
    if (!randomPage) {
      const r: VodListResult = await SiteApi.getList(site, typeId, 1, '');
      return r.items;
    }
    const pg: number = 1 + Math.floor(Math.random() * 30);
    try {
      if (pg === 1) {
        const r1: VodListResult = await SiteApi.getList(site, typeId, 1, '');
        return r1.items;
      }
      const r2: VodListResult = await SiteApi.getList(site, typeId, pg, '');
      if (r2.items.length > 0) {
        return r2.items;
      }
    } catch (e) {
      // 页数不够会报错或返回空，退回第一页
    }
    const r0: VodListResult = await SiteApi.getList(site, typeId, 1, '');
    return r0.items;
  }

  private hitBad(name: string, words: string[]): boolean {
    for (const w of words) {
      if (name.indexOf(w) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 自己命中黑名单，或者父分类命中（「重生民国」这种子类，光看名字看不出是短剧） */
  private classBad(c: VodClass): boolean {
    // 家长锁关键词（PinStore.WORDS）优先：点播页会把命中的分类锁掉，
    // 首页随机推荐要是还抽它，主推位就等于把锁里的东西摆到最显眼处。
    if (PinStore.isRestricted(c.type_name)) {
      return true;
    }
    if (this.hitBad(c.type_name, PICK_BAD)) {
      return true;
    }
    const pid: string = c.type_pid === undefined ? '' : c.type_pid.toString();
    if (pid === '' || pid === '0') {
      return false;
    }
    for (const p of this.allCls) {
      if (p.type_id.toString() === pid) {
        return PinStore.isRestricted(p.type_name) || this.hitBad(p.type_name, PICK_BAD);
      }
    }
    return false;
  }

  /** 一级分类是不是影视正片分类（电影 / 剧 / 动漫 / 动画 / 纪录片） */
  private classWanted(name: string): boolean {
    return this.hitBad(name, PICK_OK);
  }

  /**
   * 可选分类摊平：一级分类下有子分类时用子分类（一级本身只有个位数片子，
   * 实测「电影片」14 部、「连续剧」7 部，而子类「动作片」5000 多部）。
   *
   * 两道门：先黑名单（体育/综艺/解说/短剧/擦边…，按父级连带），
   * 再白名单（一级名里必须带 电影/剧/动漫/动画/纪录）。
   * 白名单放前面会把「短剧大全」「电影解说」放进来，所以顺序不能反。
   */
  private pickCandidates(): VodClass[] {
    const flat: VodClass[] = [];
    for (const c of this.allCls) {
      const pid: string = c.type_pid === undefined ? '' : c.type_pid.toString();
      if (pid !== '' && pid !== '0') {
        continue;   // 只看一级，子类跟着父类走
      }
      if (this.classBad(c) || !this.classWanted(c.type_name)) {
        continue;
      }
      const kids: VodClass[] = this.childrenOf(this.allCls, c.type_id.toString());
      if (kids.length > 0) {
        for (const k of kids) {
          if (!this.classBad(k)) {
            flat.push(k);
          }
        }
      } else {
        flat.push(c);
      }
    }
    // 兜底：换个站点可能没有「电影/剧/动漫」这种命名（比如叫「片库」「频道」），
    // 白名单一个都不命中时退回「只过黑名单」的那批，而不是退回全部分类 ——
    // 否则体育赛事、综艺、擦边又会从兜底口子漏回主推位。
    let src: VodClass[] = flat;
    if (src.length === 0) {
      for (const c of this.allCls) {
        const pid2: string = c.type_pid === undefined ? '' : c.type_pid.toString();
        if (pid2 !== '' && pid2 !== '0') {
          continue;
        }
        if (this.classBad(c)) {
          continue;
        }
        const kids2: VodClass[] = this.childrenOf(this.allCls, c.type_id.toString());
        if (kids2.length > 0) {
          for (const k of kids2) {
            if (!this.classBad(k)) {
              src.push(k);
            }
          }
        } else {
          src.push(c);
        }
      }
    }
    if (src.length === 0) {
      return src;
    }
    for (let i = src.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const t: VodClass = src[i];
      src[i] = src[j];
      src[j] = t;
    }
    const take: number = src.length < PICK_CLS ? src.length : PICK_CLS;
    return src.slice(0, take);
  }

  private shuffled(src: VodItem[]): VodItem[] {
    const a: VodItem[] = src.slice(0);
    for (let i = a.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const t: VodItem = a[i];
      a[i] = a[j];
      a[j] = t;
    }
    return a;
  }

  private shuffledHeroes(src: HeroItem[]): HeroItem[] {
    const a: HeroItem[] = src.slice(0);
    for (let i = a.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const t: HeroItem = a[i];
      a[i] = a[j];
      a[j] = t;
    }
    return a;
  }

  /** 简介原文带 HTML 与换行，压成一行纯文本 */
  private plain(s: string | undefined): string {
    if (s === undefined || s.length === 0) {
      return '';
    }
    let t: string = s.replace(/<[^>]*>/g, ' ');
    t = t.replace(/&nbsp;/g, ' ');
    t = t.replace(/&amp;/g, '&');
    t = t.replace(/[\r\n\t]+/g, ' ');
    t = t.replace(/\s{2,}/g, ' ');
    return t.trim();
  }

  /**
   * 采集站的占位简介（「暂无简介，敬请期待」「剧情简介：」这种）不要占三行版面，
   * 长度不到 20 字也当没有——那不是简介，只是一句占位话。
   */
  private plotOf(s: string | undefined): string {
    const t: string = this.plain(s);
    if (t.length < 20) {
      return '';
    }
    if (t.indexOf('暂无简介') >= 0 || t.indexOf('暂无剧情') >= 0) {
      return '';
    }
    return t;
  }

  private hero(): HeroItem | null {
    if (this.heroes.length === 0) {
      return null;
    }
    const i: number = this.heroIdx < this.heroes.length ? this.heroIdx : 0;
    return this.heroes[i];
  }

  /** 切换主推位后同步两样东西：收藏态、横版剧照 */
  private syncHero(): void {
    const h: HeroItem | null = this.hero();
    if (h === null) {
      this.backdrop = '';
      this.heroFavState = false;
      return;
    }
    const ctx = getContext(this) as common.Context;
    this.heroFavState = MarkStore.isFav(ctx, h.siteKey, h.vodId);
    this.syncBackdrop();
    this.warmHeroMeta(h);
  }

  /** 上一次给 hero 请求豆瓣类型的时间 */
  private metaTs: number = 0;

  /**
   * 给当前主推位补一次豆瓣类型标签。
   * 只补「当前这一部」且 6 秒最多一次：rexxar 详情接口限流极狠，
   * 一屏 20 部全补会被锁死，而 hero 同一时刻只有一部在用。
   */
  private warmHeroMeta(h: HeroItem): void {
    if (h.doubanId.length === 0 || RatingStore.metaCached(h.doubanId) !== null) {
      return;
    }
    const now: number = Date.now();
    if (now - this.metaTs < 6000) {
      return;
    }
    this.metaTs = now;
    RatingStore.ensureMeta(h.doubanId).then((m) => {
      if (m !== null) {
        this.metaTick++;
      }
    }).catch(() => {});
  }

  /**
   * 横版剧照：先看本地缓存，没有再排队去豆瓣抓。
   * 抓完 BackdropStore 会 +1 backdropTick，本页 Watch 到之后重新取一次。
   */
  private syncBackdrop(): void {
    const h: HeroItem | null = this.hero();
    if (h === null) {
      this.backdrop = '';
      return;
    }
    const local: string = BackdropStore.localOf(h.name);
    this.backdrop = local;
    if (local.length === 0) {
      BackdropStore.ensure(h.name, h.year, h.doubanId);
    }
  }

  onBackdropTick(): void {
    const h: HeroItem | null = this.hero();
    if (h !== null) {
      this.backdrop = BackdropStore.localOf(h.name);
    }
  }

  /**
   * 整屏背景图的来源：当前主推位的横版剧照，没有就用内置的兜底大图。
   * 兜底图是一张暗调暖光的氛围图（1920×1080），目的在于「任何时候都有画面」，
   * 而不是让背景空成一块纯黑 —— 主推位旁边那块空地如果没有图，整个首页会很空。
   */
  private bgSource(): ResourceStr {
    if (this.backdrop.length > 0) {
      return this.backdrop;
    }
    return $r('app.media.hero_fallback');
  }

  private picOf(item: VodItem): string {
    const local: string = PosterStore.localOf(item);
    if (local.length > 0) {
      return local;
    }
    let p: string = item.vod_pic === undefined ? '' : item.vod_pic.trim();
    if (p.startsWith('//')) {
      p = 'https:' + p;
    }
    if (p.length > 0 && !p.startsWith('http') && !p.startsWith('file')) {
      return '';
    }
    return p;
  }

  /**
   * 真正能画的地址。豆瓣图床回 418/403，QQ 音乐这类 http 明文外链在电视上也常画不出来，
   * Image 组件又带不了 Referer —— 统一交给 ImageCache 本地化后再画。
   * 读一下 picTick 让后台落地后本页跟着重绘。
   */
  private picReady(u: string): string {
    if (this.picTick < 0) {
      return u;
    }
    return ImageCache.display(u);
  }

  /** 投递外链海报本地化；完成后 ImageCache 会 +sitePicTick 触发重绘 */
  private warmPic(u: string): void {
    ImageCache.warm(u);
  }

  /** 主推位、缩略图、收藏/记录行里的外链海报统一预热一遍 */
  private warmPics(): void {
    for (const h of this.heroes) {
      this.warmPic(h.pic);
    }
    for (const s of this.shelves) {
      for (const m of s.marks) {
        this.warmPic(this.picOfMark(m));
      }
    }
  }

  private scoreOf(item: VodItem): string {
    if (this.ratingTick < 0 || this.posterTick < 0) {
      return '';
    }
    return RatingStore.label(item);
  }

  private metaOf(h: HeroItem): string {
    const parts: string[] = [];
    if (h.year.length > 0) {
      parts.push(h.year);
    }
    // 分类不再放这里：它已经在上面那排标签里了，重复一遍只是占地方
    if (h.area.length > 0) {
      parts.push(h.area);
    }
    if (h.remarks.length > 0) {
      parts.push(h.remarks);
    }
    return parts.join(' · ');
  }

  /**
   * 主推位的类型标签：优先读豆瓣类型缓存（悬疑 / 犯罪 / 剧情）。
   * 这里只读缓存、不发请求 —— hero 换片频繁，一换就请求会被 rexxar 限流锁死；
   * 缓存来自详情页那一次请求，看过一次详情后首页也就有了。
   */
  private heroTags(h: HeroItem): string[] {
    if (h.doubanId.length > 0) {
      const m = RatingStore.metaCached(h.doubanId);
      if (m !== null && m.genres.length > 0) {
        return m.genres.slice(0, 3);
      }
    }
    if (h.typeName.length > 0) {
      return [h.typeName];
    }
    return [];
  }

  private heroFaved(): boolean {
    return this.heroFavState;
  }

  /** 高亮：遥控器焦点 + 鼠标 hover（灵犀遥控器按鼠标上报） */
  private hot(id: string): boolean {
    return this.focusId === id || this.hoverId === id;
  }

  private clearHot(id: string): void {
    if (this.focusId === id) {
      this.focusId = '';
    }
  }

  private goDetail(siteKey: string, vodId: string, name: string, pic: string): void {
    router.pushUrl({
      url: 'pages/Detail',
      params: { key: siteKey, vodId: vodId, name: name, pic: pic }
    }).catch(() => {});
  }

  private goMark(m: VodMark): void {
    this.goDetail(m.siteKey, m.vodId, m.name, m.pic);
  }

  private toggleHeroFav(): void {
    const h: HeroItem | null = this.hero();
    if (h === null) {
      return;
    }
    const ctx = getContext(this) as common.Context;
    MarkStore.toggleFav(ctx, {
      siteKey: h.siteKey,
      vodId: h.vodId,
      name: h.name,
      pic: h.pic,
      remarks: h.remarks,
      time: Date.now(),
      typeName: h.typeName
    });
    this.heroFavState = MarkStore.isFav(ctx, h.siteKey, h.vodId);
    this.rowSig = this.signature();
  }

  /** 历史只存了时间戳，这里换成「刚刚 / 3 小时前 / 昨天 / 5 天前」 */
  private ago(t: number): string {
    const d: number = Date.now() - t;
    if (d < 0) {
      return '';
    }
    const min: number = Math.floor(d / 60000);
    if (min < 2) {
      return '刚刚看过';
    }
    if (min < 60) {
      return min.toString() + ' 分钟前';
    }
    const h: number = Math.floor(min / 60);
    if (h < 24) {
      return h.toString() + ' 小时前';
    }
    const day: number = Math.floor(h / 24);
    if (day === 1) {
      return '昨天看过';
    }
    if (day < 30) {
      return day.toString() + ' 天前';
    }
    return '';
  }

  private errorText(): string {
    // 「正在加载」的提示已经放进主推骨架的转圈里（第一屏可见），这里只报错误，
    // 免得加载期底部再重复一行同样的字。
    return this.err;
  }

  // ---------------- 视图 ----------------

  private heroTagList(): string[] {
    // 读一下计数，豆瓣类型补到之后才能重绘
    if (this.metaTick < 0) {
      return [];
    }
    const h: HeroItem | null = this.hero();
    return h === null ? [] : this.heroTags(h);
  }

  @Builder
  heroChip(text: string, accent: boolean) {
    Row() {
      Text(text)
        .fontSize(12)
        .fontWeight(accent ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(accent ? '#FFB37A' : '#C9C9D4')
        .maxLines(1)
    }
    .height(27)
    .padding({ left: 12, right: 12 })
    .borderRadius(8)
    .backgroundColor(accent ? '#22FF8A3D' : '#14FFFFFF')
    .border({ width: 1, color: accent ? '#73FF8A3D' : '#28FFFFFF' })
  }

  /**
   * 主推位骨架：数据没到之前用它占住 724×334 的位置。
   * 尺寸每一段都对着真面板排（标签 27 / 片名 60 / 元信息 45 / 简介 86 / 按钮 52），
   * 所以「骨架 → 真内容」这一步不会有任何位移。
   */
  @Builder
  heroSkeleton() {
    Column({ space: 0 }) {
      // 标签行
      Row({ space: 9 }) {
        Row().width(76).height(27).borderRadius(8).backgroundColor('#1AFFFFFF')
          .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
        Row().width(58).height(27).borderRadius(8).backgroundColor('#12FFFFFF')
          .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
      }
      .margin({ bottom: 14 })

      // 片名条：46 + 14 = 60，与 44 号字的行盒等高
      Row()
        .width(420)
        .height(46)
        .borderRadius(10)
        .backgroundColor('#1FFFFFFF')
        .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
        .margin({ bottom: 14 })

      // 加载指示：转圈 + 文案，第一屏正中就看得见「正在加载」
      Row({ space: 10 }) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color('#FF8A3D')
        Text('正在加载片单…')
          .fontSize(14)
          .fontColor('#B9B9C4')
      }
      .height(24)
      .margin({ top: 9, bottom: 14 })

      // 简介三条
      Column({ space: 10 }) {
        Row().width(656).height(12).borderRadius(6).backgroundColor('#0FFFFFFF')
          .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
        Row().width(612).height(12).borderRadius(6).backgroundColor('#0FFFFFFF')
          .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
        Row().width(548).height(12).borderRadius(6).backgroundColor('#0FFFFFFF')
          .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
      }
      .width(660)
      .height(66)
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 20 })

      // 两个按钮
      Row({ space: 14 }) {
        Row().width(178).height(52).borderRadius(16).backgroundColor('#1CFFA847')
        Row().width(126).height(52).borderRadius(16).backgroundColor('#12FFFFFF')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(724)
    .padding({ left: 0, right: 34, top: 24, bottom: 26 })
    // 跟 heroInfo 同步：玻璃背板已去掉，骨架也别再画毛玻璃板
    .margin({ bottom: 22 })
  }

  /** 随机推荐的一张骨架：132×198 与真卡片同宽同高，整行高度固定 244 */
  @Builder
  pickSkeleton() {
    Column() {
      Row()
        .width(132)
        .height(198)
        .borderRadius(13)
        .backgroundColor('#14151C')
        .border({ width: 1, color: '#12FFFFFF' })
        .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
      Row()
        .width(94)
        .height(12)
        .borderRadius(6)
        .backgroundColor('#14FFFFFF')
        .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
        .margin({ top: 9 })
      Row()
        .width(56)
        .height(10)
        .borderRadius(5)
        .backgroundColor('#0FFFFFFF')
        .opacity(this.skelOpacity()).animation({ duration: 460, curve: Curve.EaseInOut })
        .margin({ top: 6 })
    }
    .width(132)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  heroInfo() {
    // 文案直接压在整屏剧照上（玻璃背板已去掉）。可读性靠两层：底图自带的左侧/底部
    // 压黑遮罩 + 每段文字自己的黑色 textShadow。别再套回毛玻璃板。
    Column({ space: 0 }) {
      // 标签行：来源角标 + 豆瓣类型（悬疑 / 犯罪 / 剧情），没有豆瓣数据才退回采集站分类
      Row({ space: 9 }) {
        if (this.hero() !== null && this.hero()!.badge.length > 0
          && this.hero()!.badge !== this.hero()!.typeName) {
          this.heroChip(this.hero()!.badge, true)
        }
        ForEach(this.heroTagList(), (t: string) => {
          this.heroChip(t, false)
        }, (t: string, i: number) => 'ht' + String(i) + t)
      }
      .margin({ bottom: 14 })

      // 片名
      Text(this.hero() === null ? '' : this.hero()!.name)
        .fontSize(44)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 660 })
        .textShadow({ radius: 6, color: '#CC000000', offsetX: 0, offsetY: 2 })

      // 评分 + 元信息
      Row({ space: 10 }) {
        if (this.hero() !== null && this.hero()!.score.length > 0) {
          Text('★')
            .fontSize(15)
            .fontColor('#FFC24B')
          Text(this.hero()!.score)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD08A')
          Text('·')
            .fontSize(15)
            .fontColor('#55555F')
        }
        Text(this.hero() === null ? '' : this.metaOf(this.hero()!))
          .fontSize(14.5)
          .fontColor('#B4B4BF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textShadow({ radius: 4, color: '#99000000', offsetX: 0, offsetY: 1 })
      }
      .width(660)
      // 固定行高：有评分时那行会冒出 ★ 和 17 号数字，不锁高度会把这行撑高 2~3px，
      // 切片时整块玻璃跟着上下抖一下
      .height(24)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 9, bottom: 14 })

      // 剧情简介：列表接口自带，不用等详情页。
      // 这块**固定占 3 行的高度**：有简介 / 没简介、简介长 / 简介短，面板高度都不变，
      // 切片时主推位不会跟着「一会儿高一截、一会儿矮一截」。
      Column() {
        if (this.hero() !== null && this.hero()!.content.length > 0) {
          Text(this.hero()!.content)
            .fontSize(13.5)
            .lineHeight(22)
            .fontColor('#B8B8C2')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(660)
            .textShadow({ radius: 4, color: '#B3000000', offsetX: 0, offsetY: 1 })
        }
      }
      .width(660)
      .height(66)
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 20 })

      // 操作按钮
      Row({ space: 14 }) {
        // 主按钮：去详情页。首页拿不到播放地址（列表接口不带），
        // 点这里直接起播要先补一次详情请求；而电影也要选线路、剧集要选集，
        // 所以统一进详情页，文案就老实写「查看详情」，不写成「播放」骗人。
        Row({ space: 9 }) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(17)
            .fontColor(['#150A04'])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          Text('查看详情')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor('#150A04')
        }
        .height(52)
        .padding({ left: 28, right: 32 })
        .borderRadius(16)
        .linearGradient({
          angle: 90,
          colors: [['#FFA847', 0.0], ['#FF6138', 1.0]]
        })
        .shadow({ radius: 26, color: '#66FF7833', offsetX: 0, offsetY: 10 })
        .id('hero-play')
        .focusable(true)
        .onFocus(() => { this.focusId = 'hero-play'; })
        .onBlur(() => { this.clearHot('hero-play'); })
        .onHover((isHover: boolean) => { this.hoverId = isHover ? 'hero-play' : ''; })
        .scale({ x: this.hot('hero-play') ? 1.05 : 1, y: this.hot('hero-play') ? 1.05 : 1 })
        .animation({ duration: 130 })
        .onClick(() => {
          const h: HeroItem | null = this.hero();
          if (h !== null) {
            this.goDetail(h.siteKey, h.vodId, h.name, h.pic);
          }
        })

        // 收藏
        Row({ space: 9 }) {
          SymbolGlyph(this.heroFaved() ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark'))
            .fontSize(17)
            .fontColor([this.heroFaved() ? '#FFB37A' : '#EDEDF2'])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          Text(this.heroFaved() ? '已收藏' : '收藏')
            .fontSize(17)
            .fontColor(this.heroFaved() ? '#FFB37A' : '#EDEDF2')
        }
        .height(52)
        .padding({ left: 24, right: 28 })
        .borderRadius(16)
        .backgroundColor('#16FFFFFF')
        .border({ width: 1, color: '#2EFFFFFF' })
        .focusable(true)
        .onFocus(() => { this.focusId = 'hero-fav'; })
        .onBlur(() => { this.clearHot('hero-fav'); })
        .onHover((isHover: boolean) => { this.hoverId = isHover ? 'hero-fav' : ''; })
        .scale({ x: this.hot('hero-fav') ? 1.05 : 1, y: this.hot('hero-fav') ? 1.05 : 1 })
        .animation({ duration: 130 })
        .onClick(() => { this.toggleHeroFav(); })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 0, right: 34, top: 24, bottom: 26 })
    // 玻璃背板已去掉：文字直接压在整屏剧照上，靠底图自带的左侧/底部压黑遮罩保证可读。
    // 面板底沿和下一行「随机推荐」之间留气口；左沿归零，与随机推荐卡片同一起点。
    .margin({ bottom: 22 })
  }

  /** 随机推荐行标题：左边名字，右边「换一批」 */
  @Builder
  pickTitle() {
    Row() {
      Text('随机推荐')
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      // 加载中不写「共 0 部」，也别挂着点不动的按钮，但行高度固定 32，标题不会上下跳
      if (this.heroes.length > 0) {
        Text('点海报换上面的主推 · 共 ' + this.heroes.length.toString() + ' 部')
          .fontSize(12.5)
          .fontColor('#6E6E7A')
          .margin({ left: 12 })
      }
      Blank()
      if (this.heroes.length > 0) {
        Row({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(13)
            .fontColor([this.hot('shuffle') ? '#FFD9BC' : '#C9C9D4'])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          Text(this.picking ? '换一批中…' : '换一批')
            .fontSize(13)
            .fontColor(this.hot('shuffle') ? '#FFD9BC' : '#C9C9D4')
        }
        .height(32)
        .padding({ left: 14, right: 16 })
        .borderRadius(16)
        .backgroundColor(this.hot('shuffle') ? '#242530' : '#12FFFFFF')
        .border({ width: 1, color: this.hot('shuffle') ? '#FFD9BC' : '#22FFFFFF' })
        .focusable(true)
        .onFocus(() => { this.focusId = 'shuffle'; })
        .onBlur(() => { this.clearHot('shuffle'); })
        .onHover((isHover: boolean) => { this.hoverId = isHover ? 'shuffle' : ''; })
        .onClick(() => {
          // 真的重新随机一批 20 部（重拉分类随机页），不是把旧的往后翻
          this.repick(true);
        })
      }
    }
    .width('100%')
    .height(32)
    .alignItems(VerticalAlign.Center)
    .padding({ right: 56 })
    // 标题和下面那排缩略图之间留出呼吸：贴太近像同一块的两行
    .margin({ bottom: 20 })
  }

  /** 随机推荐里的一张：点它 = 换上面的主推，不进详情 */
  @Builder
  pickCard(it: HeroItem, idx: number) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Row()
          .width(132)
          .height(198)
          .borderRadius(13)
          .backgroundColor('#1A1B22')
        if (this.picReady(it.pic).length > 0) {
          Image(this.picReady(it.pic))
            .width(132)
            .height(198)
            .objectFit(ImageFit.Cover)
            .borderRadius(13)
        } else {
          // 规则站片子常常没海报也没刮到图，别只留一个黑框，给个明确占位
          Column() {
            Text('暂无海报')
              .fontSize(12)
              .fontColor('#6E6E7A')
          }
          .width(132)
          .height(198)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
        Column()
          .width(132)
          .height(56)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.0], ['#A6000000', 1.0]]
          })
        if (it.score.length > 0) {
          Text(it.score)
            .fontSize(11.5)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD08A')
            .backgroundColor('#B3000000')
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .margin({ left: 9, bottom: 9 })
        }
      }
      .width(132)
      .height(198)
      .clip(true)
      .borderRadius(13)
      .border({
        width: this.heroIdx === idx ? 2 : 1,
        color: this.heroIdx === idx ? '#FF8A3D'
          : (this.hot('p-' + idx) ? '#FFD9BC' : '#1AFFFFFF')
      })
      .shadow({
        radius: this.heroIdx === idx ? 28 : (this.hot('p-' + idx) ? 26 : 0),
        color: this.heroIdx === idx ? '#80FF8A3D' : '#59FF8A3D',
        offsetX: 0,
        offsetY: 0
      })
      .scale({
        x: this.hot('p-' + idx) ? 1.05 : 1,
        y: this.hot('p-' + idx) ? 1.05 : 1
      })
      .animation({ duration: 130 })

      Text(it.name)
        .fontSize(13.5)
        .fontColor(this.heroIdx === idx ? '#FFD9BC' : '#E4E4EC')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(132)
        .margin({ top: 7 })
      Text(it.badge)
        .fontSize(11)
        .fontColor('#8E8E9A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(132)
        .margin({ top: 3 })
    }
    .width(132)
    .focusable(true)
    .onFocus(() => { this.focusId = 'p-' + idx; })
    .onBlur(() => { this.clearHot('p-' + idx); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'p-' + idx : ''; })
    .onClick(() => {
      this.heroIdx = idx;
      this.syncHero();
    })
  }

  /** 行标题：收藏 / 历史都铺全量，右侧不再需要「查看全部」 */
  @Builder
  sectionTitle(s: Shelf) {
    Row() {
      Text(s.title)
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
    }
    .width('100%')
    .height(30)
    .padding({ right: 56 })
    .margin({ bottom: 18 })
  }

  /** 收藏 / 历史卡片：竖版海报 + 片名 + 一行状态 */
  @Builder
  markCard(m: VodMark, rowIdx: number, idx: number, isHis: boolean) {
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        Row()
          .width(150)
          .height(226)
          .borderRadius(13)
          .backgroundColor('#1A1B22')
        if (this.picReady(this.picOfMark(m)).length > 0) {
          Image(this.picReady(this.picOfMark(m)))
            .width(150)
            .height(226)
            .objectFit(ImageFit.Cover)
            .borderRadius(13)
        }
        Column()
          .width(150)
          .height(66)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.0], ['#99000000', 1.0]]
          })
        if (this.scoreOfMark(m).length > 0) {
          Text(this.scoreOfMark(m))
            .fontSize(11.5)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFD08A')
            .backgroundColor('#B3000000')
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 3, bottom: 3 })
            .margin({ left: 9, bottom: 9 })
        }
      }
      .width(150)
      .height(226)
      .clip(true)
      .borderRadius(13)
      .border({
        width: this.hot('m-' + rowIdx + '-' + idx) ? 2 : 1,
        color: this.hot('m-' + rowIdx + '-' + idx) ? '#FFD9BC' : '#1AFFFFFF'
      })
      .shadow(this.hot('m-' + rowIdx + '-' + idx)
        ? { radius: 26, color: '#59FF8A3D', offsetX: 0, offsetY: 0 }
        : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
      .scale({
        x: this.hot('m-' + rowIdx + '-' + idx) ? 1.05 : 1,
        y: this.hot('m-' + rowIdx + '-' + idx) ? 1.05 : 1
      })
      .animation({ duration: 130 })

      Text(m.name)
        .fontSize(13.5)
        .fontColor('#E4E4EC')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(150)
        .margin({ top: 9 })
      Text(isHis ? this.ago(m.time) : (m.remarks.length > 0 ? m.remarks : ''))
        .fontSize(11)
        .fontColor('#8E8E9A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(150)
        .margin({ top: 3 })
    }
    .width(150)
    .focusable(true)
    .onFocus(() => { this.focusId = 'm-' + rowIdx + '-' + idx; })
    .onBlur(() => { this.clearHot('m-' + rowIdx + '-' + idx); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'm-' + rowIdx + '-' + idx : ''; })
    .onClick(() => { this.goMark(m); })
  }

  @Builder
  content() {
    Scroll() {
      Column() {
        // ---- 顶部：主推位。不再放海报，文案自己就是一块玻璃浮在整屏剧照上 ----
        // 数据没到先画骨架：位置和真面板一样，避免「先空着、来了再撑开」的跳动
        Row() {
          if (this.hero() === null) {
            this.heroSkeleton()
          } else {
            this.heroInfo()
          }
        }
        .width('100%')
        .height(366)
        .alignItems(VerticalAlign.Bottom)
        .padding({ right: 56 })
        .margin({ top: 4 })

        // ---- 随机推荐：既是片单，也是主推位的换片开关 ----
        // 整块**始终存在**（标题 + 5 张骨架卡），否则它要等 20 部抽完才「长」出来，
        // 页面高度会从 366 一下跳到 620，观感就是忽小忽大。
        Column() {
          this.pickTitle()
          if (this.heroes.length > 0) {
            List({ space: 16 }) {
              ForEach(this.heroes, (h: HeroItem, i: number) => {
                ListItem() {
                  this.pickCard(h, i)
                }
              }, (h: HeroItem) => 'pk' + h.siteKey + h.vodId)
            }
            .listDirection(Axis.Horizontal)
            .width('100%')
            .height(244)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          } else {
            Row({ space: 16 }) {
              ForEach(SKELETON_SLOTS, (k: number) => {
                this.pickSkeleton()
              }, (k: number) => 'skel' + k.toString())
            }
            .width('100%')
            .height(244)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 10 })

        // ---- 片单：继续观看 → 收藏（空的整行不画） ----
        ForEach(this.shelves, (s: Shelf, ri: number) => {
          Column() {
            this.sectionTitle(s)
            List({ space: 18 }) {
              ForEach(s.marks, (m: VodMark, ci: number) => {
                ListItem() {
                  this.markCard(m, ri, ci, s.kind === K_HIS)
                }
              }, (m: VodMark) => 'm' + m.siteKey + m.vodId)
            }
            .listDirection(Axis.Horizontal)
            .width('100%')
            .height(276)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 18 })
        }, (s: Shelf) => s.kind + s.title)

        // ---- 加载/错误提示 ----
        if (this.errorText().length > 0) {
          Text(this.errorText())
            .fontSize(14)
            .fontColor(this.err.length > 0 ? '#FF8B7A' : '#8E8E9A')
            .margin({ top: 24, bottom: 50 })
        } else {
          Row()
            .height(40)
        }
      }
      .width('100%')
      .padding({ left: 56, right: 0 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 背景：当前主推位的横版剧照，整屏 Cover 铺满；没有剧照用内置兜底图 ----
      // 版面底色仍是 #08090B，图片没解码出来那一刻也不会闪白。
      Image(this.bgSource())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .zIndex(0)

      // ---- 遮罩一：水平方向 ----
      // 左边压深，保证片名 / 简介 / 按钮在图上能读；右边几乎不压，把画面留给眼睛。
      // 这里不是「整层黑纱」，而是一侧偏重、一侧透明的渐变，图才不会被捂死。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [['#C80B0A0C', 0.0], ['#9E0B0A0C', 0.30], ['#4A0B0A0C', 0.62], ['#140B0A0C', 1.0]]
        })
        .zIndex(1)

      // ---- 遮罩二：垂直方向 ----
      // 上半基本不压（主推位那一段要看到图），往下渐到实底，
      // 否则下面那排随机推荐卡片会和背景的花纹搅在一起。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#0008090B', 0.0],
                   ['#1F08090B', 0.44],
                   ['#9908090B', 0.66],
                   ['#F508090B', 0.84],
                   ['#08090B', 1.0]]
        })
        .zIndex(1)

      Row() {
        SideNav({ active: 0 })
        // 必须 layoutWeight(1)：写 width('100%') 会按整个 Row 的宽度算，
        // 再加上左边 88 的导航栏就顶出屏幕，右侧内容被挤出可视区
        Column() {
          this.content()
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .zIndex(2)

      // ---- 右上角：当前源名 + 搜索圆钮 ----
      // 底下现在是整屏剧照，两者都自带暗底，否则在亮画面上会看不见。
      // 用同一个 Row 承载、右对齐到原搜索按钮的位置（右边缘 x=1224），
      // 源名在左、搜索在右，不用再单独给标签算锚点。
      Row({ space: 10 }) {
        // 当前点播源名字：一眼看清在刷哪个站，不用点进设置
        if (this.siteName.length > 0) {
          Text(this.siteName)
            .fontSize(13)
            .fontColor(this.hot('search') ? '#FFD9BC' : '#E8E8EF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 200 })
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(20)
            .backgroundColor(this.hot('search') ? '#A61C1620' : '#80000000')
            .border({ width: 1, color: this.hot('search') ? '#FFD9BC' : '#4DFFFFFF' })
        }
        Row() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(19)
            .fontColor([this.hot('search') ? '#FFD9BC' : '#E8E8EF'])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.hot('search') ? '#A61C1620' : '#80000000')
        .border({ width: 1, color: this.hot('search') ? '#FFD9BC' : '#4DFFFFFF' })
        .focusable(true)
        .onFocus(() => { this.focusId = 'search'; })
        .onBlur(() => { this.clearHot('search'); })
        .onHover((isHover: boolean) => { this.hoverId = isHover ? 'search' : ''; })
        .onClick(() => { router.pushUrl({ url: 'pages/Search' }).catch(() => {}); })
      }
      // 右边缘锚在原搜索按钮的右沿 x=1224：源名往左长，搜索按钮位置不动
      .position({ x: 1224, y: 22 })
      .markAnchor({ x: '100%', y: 0 })
      .height(44)
      .zIndex(3)

      // ---- 未配置源时的引导 ----
      if (this.needConfig) {
        Column({ space: 18 }) {
          Text('还没有配置片源')
            .fontSize(26)
            .fontColor('#FFFFFF')
          Text('去设置里载入一份配置接口')
            .fontSize(15)
            .fontColor('#9C9CA8')
          Text('打开设置')
            .fontSize(16)
            .fontColor('#150A04')
            .height(48)
            .padding({ left: 28, right: 28 })
            .borderRadius(24)
            .backgroundColor('#FF8A3D')
            .textAlign(TextAlign.Center)
            .focusable(true)
            .onClick(() => { router.pushUrl({ url: 'pages/Settings' }).catch(() => {}); })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#E608090B')
        .zIndex(4)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}
