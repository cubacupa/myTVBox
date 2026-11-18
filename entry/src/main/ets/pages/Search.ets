import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../utils/AppState';
import { SniffWeb } from '../components/SniffWeb';
import { SiteApi } from '../utils/SiteApi';
import { VodItem } from '../model/VodItem';
import { SiteCfg } from '../model/TvBoxModels';
import { PosterCard } from '../components/PosterCard';
import { RatingStore } from '../utils/RatingStore';
import { SideNav } from '../components/SideNav';
import { FileStore } from '../utils/FileStore';
import { PinStore } from '../utils/PinStore';

const F_HIST: string = 'tvbox_search_history.json';
const HIST_MAX: number = 20;

/**
 * 搜索页：当前站点搜索，或聚合当前配置里所有可用站点（最多 8 个，避免长时间等待）。
 *
 * 视觉跟其它页面一致：全屏渐变底 + 左侧 88 导航栏 + 34px 标题栏。
 * 主体左右分栏：左边固定一列放搜索历史 chip（本机沙箱持久化，最近用过的在最前），
 * 右边是 4 列现代海报卡结果区。
 */
@Entry
@Component
struct SearchPage {
  @State wd: string = '';
  @State items: VodItem[] = [];
  @State loading: boolean = false;
  @State msg: string = '';
  @State agg: boolean = false;
  @State siteName: string = '';
  @State history: string[] = [];
  @State confirmClear: boolean = false;
  @State focusId: string = '';
  @State hoverId: string = '';
  /** 家长锁：设了 PIN 且没解锁时，搜索结果里敏感分类的片直接不出现 */
  @State pin: string = '';
  @State unlocked: boolean = false;

  aboutToAppear(): void {
    this.wd = '';
    const site = AppState.currentSite;
    if (site !== null) {
      this.siteName = site.name;
    }
    const ctx = getContext(this) as common.Context;
    this.history = this.readHistory(ctx);
    this.pin = PinStore.get(ctx);
    this.unlocked = PinStore.isVodUnlocked();
  }

  /** 家长锁：搜索结果按分类名过滤（分类名缺失时按片名兜底，跟历史页一个口径） */
  private allowed(it: VodItem): boolean {
    if (this.pin.length === 0 || this.unlocked) {
      return true;
    }
    const tn: string = it.type_name ?? '';
    return tn.length > 0
      ? !PinStore.shouldHide(tn, this.pin, this.unlocked)
      : !PinStore.shouldHide(it.vod_name ?? '', this.pin, this.unlocked);
  }

  // ---------------- 搜索历史：本机文件，最近优先、去重、最多 20 条 ----------------

  private readHistory(ctx: common.Context): string[] {
    const txt: string = FileStore.readText(ctx, F_HIST);
    if (txt.length === 0) {
      return [];
    }
    try {
      const arr = JSON.parse(txt) as string[];
      if (!Array.isArray(arr)) {
        return [];
      }
      const out: string[] = [];
      for (const w of arr) {
        if (typeof w === 'string' && w.trim().length > 0 && out.indexOf(w) < 0) {
          out.push(w);
        }
        if (out.length >= HIST_MAX) {
          break;
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  private addHistory(ctx: common.Context, word: string): string[] {
    const w: string = word.trim();
    if (w.length === 0) {
      return this.readHistory(ctx);
    }
    const next: string[] = [w];
    for (const old of this.readHistory(ctx)) {
      if (old !== w && next.length < HIST_MAX) {
        next.push(old);
      }
    }
    FileStore.writeText(ctx, F_HIST, JSON.stringify(next));
    return next;
  }

  private hot(id: string): boolean {
    return this.focusId === id || this.hoverId === id;
  }

  private clearHot(id: string): void {
    if (this.focusId === id) {
      this.focusId = '';
    }
    if (this.hoverId === id) {
      this.hoverId = '';
    }
  }

  // ---------------- 搜索 ----------------

  private async doSearch(): Promise<void> {
    const w = this.wd.trim();
    if (!w) {
      this.msg = '请输入关键词';
      return;
    }
    const ctx = getContext(this) as common.Context;
    this.history = this.addHistory(ctx, w);
    // 搜索一开始就清空输入框：关键词已经进了历史 chip，框里不用再留一份
    this.wd = '';
    this.confirmClear = false;
    this.loading = true;
    this.msg = '';
    this.items = [];
    try {
      if (this.agg) {
        // 网页模式规则要在隐藏 WebView 里真跑页面，一个站就能拖十几秒，
        // 聚合时跳过；关掉聚合单独搜这个站才有结果
        const all = AppState.usableSites();
        const sites: SiteCfg[] = [];
        for (const s of all) {
          if (!SiteApi.isWebRule(s)) {
            sites.push(s);
          }
        }
        const limit = sites.length > 8 ? 8 : sites.length;
        for (let i = 0; i < limit; i++) {
          try {
            const r = await SiteApi.search(sites[i], w, 1);
            for (const it of r.items) {
              it.site_key = sites[i].key;
            }
            this.items = this.items.concat(r.items);
          } catch (e) {
            // 单个站点失败不影响聚合
          }
        }
      } else {
        const site = AppState.currentSite;
        if (site === null) {
          this.msg = '没有可用的资源站';
          this.loading = false;
          return;
        }
        const r = await SiteApi.search(site, w, 1);
        for (const it of r.items) {
          it.site_key = site.key;
        }
        this.items = r.items;
      }
      const rawN: number = this.items.length;
      this.items = this.items.filter((it: VodItem) => this.allowed(it));
      if (this.items.length === 0) {
        this.msg = rawN > 0 ? '结果已按家长锁隐藏，解锁后可见' : '没有搜到结果，换个关键词或站点试试';
      } else {
        // 搜索结果同样参与评分补齐与海报刮削
        RatingStore.warm(this.items);
      }
    } catch (e) {
      this.msg = '搜索失败：' + (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private goDetail(item: VodItem): void {
    const site = AppState.currentSite;
    let key = item.site_key ? item.site_key : '';
    if (!key && site !== null) {
      key = site.key;
    }
    router.pushUrl({
      url: 'pages/Detail',
      params: { key: key, vodId: String(item.vod_id), name: item.vod_name, pic: item.vod_pic }
    }).catch(() => {});
  }

  // ---------------- UI ----------------

  /**
   * 胶囊的文案和强调态必须在 Builder 内部读状态：
   * @Builder 的参数是**按值传递**的，外面算好传进来，状态变了里面不会刷新
   * （表现就是「聚合：关」永远不变成「聚合：开」，橙色底也不亮）。
   */
  private pillLabel(id: string): string {
    return id === 'agg' ? (this.agg ? '聚合：开' : '聚合：关') : '返回';
  }

  private pillAccent(id: string): boolean {
    return id === 'agg' && this.agg;
  }

  /** 顶栏右侧胶囊，跟记录/设置页同一套 */
  @Builder
  topPill(id: string) {
    Row() {
      Text(this.pillLabel(id))
        .fontSize(13.5)
        .fontWeight(this.pillAccent(id) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.pillAccent(id) ? '#150A04' : (this.hot(id) ? '#FFD9BC' : '#C9C9D4'))
    }
    .height(40)
    .padding({ left: 18, right: 18 })
    .borderRadius(20)
    .backgroundColor(this.pillAccent(id) ? '#FF8A3D'
      : (this.hot(id) ? '#1C1D25' : '#12FFFFFF'))
    .border({
      width: 1,
      color: this.pillAccent(id) ? Color.Transparent : (this.hot(id) ? '#FFD9BC' : '#22FFFFFF')
    })
    .focusable(true)
    .onFocus(() => { this.focusId = id; })
    .onBlur(() => { this.clearHot(id); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? id : ''; })
    .onClick(() => {
      if (id === 'agg') {
        this.agg = !this.agg;
      } else if (id === 'back') {
        router.back();
      }
    })
  }

  /** 历史词 chip：点一下就按这个词搜 */
  @Builder
  historyChip(word: string, idx: number) {
    Row() {
      Text(word)
        .fontSize(13)
        .fontColor(this.hot('h' + idx) ? '#150A04' : '#C9C9D4')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 168 })
    }
    .height(36)
    .padding({ left: 14, right: 14 })
    .borderRadius(18)
    .backgroundColor(this.hot('h' + idx) ? '#FF8A3D' : '#12FFFFFF')
    .border({
      width: 1,
      color: this.hot('h' + idx) ? Color.Transparent : '#22FFFFFF'
    })
    .margin({ right: 8, bottom: 10 })
    .focusable(true)
    .onFocus(() => { this.focusId = 'h' + idx; })
    .onBlur(() => { this.clearHot('h' + idx); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'h' + idx : ''; })
    .onClick(() => {
      this.wd = word;
      this.doSearch();
    })
  }

  /** 清空历史：两次点击，防遥控误触 */
  @Builder
  clearPill() {
    Row() {
      Text(this.confirmClear ? '确认清空' : '清空历史')
        .fontSize(12.5)
        .fontColor(this.confirmClear ? '#FF8A6B' : '#7E7E8A')
    }
    .height(34)
    .padding({ left: 12, right: 12 })
    .borderRadius(10)
    .backgroundColor(this.confirmClear ? '#22FF8A3D' : Color.Transparent)
    .margin({ top: 6 })
    .focusable(true)
    .onClick(() => {
      if (!this.confirmClear) {
        this.confirmClear = true;
        return;
      }
      const ctx = getContext(this) as common.Context;
      FileStore.remove(ctx, F_HIST);
      this.history = [];
      this.confirmClear = false;
    })
  }

  /** 左侧：搜索历史列表空间 */
  @Builder
  historyPane() {
    Column() {
      Row() {
        Text('搜索历史')
          .fontSize(13)
          .fontColor('#8E8E9A')
      }
      .width('100%')

      if (this.history.length === 0) {
        Text('搜过的关键词会留在这里')
          .fontSize(12.5)
          .fontColor('#5C5C68')
          .width('100%')
          .margin({ top: 16 })
        Blank()
      } else {
        Scroll() {
          Column() {
            Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Start, alignContent: FlexAlign.Start }) {
              ForEach(this.history, (w: string, idx: number) => {
                this.historyChip(w, idx)
              }, (w: string) => w)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .justifyContent(FlexAlign.Start)
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
        // 关键：ArkUI 通用 .align() 默认是 Alignment.Center。Scroll 的内容比视口矮时，
        // 整块 chip 流会被摆在垂直正中，光改 Flex 的 alignItems / alignContent 没用。
        .align(Alignment.TopStart)
        .margin({ top: 16 })

        this.clearPill()
      }
    }
    .width(224)
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ right: 16, top: 16, bottom: 16 })
    .margin({ left: 44, top: 18, bottom: 22 })
  }

  /** 右侧：结果区 */
  @Builder
  resultPane() {
    Column() {
      if (this.msg.length > 0) {
        Text(this.msg)
          .fontSize(13)
          .fontColor('#FF8A6B')
          .width('100%')
          .margin({ top: 14, left: 24 })
      }

      if (this.loading) {
        Column() {
          LoadingProgress().width(44).height(44)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column({ space: 12 }) {
          Text('输入片名开始搜索')
            .fontSize(20)
            .fontColor('#DDDDE6')
          Text('也可以点左边的历史关键词')
            .fontSize(13)
            .fontColor('#7E7E8A')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.items, (item: VodItem) => {
            GridItem() {
              PosterCard({
                item: item,
                cardW: 0,
                cardH: 264,
                onSelect: () => this.goDetail(item)
              })
            }
          }, (item: VodItem) => String(item.site_key ? item.site_key : '') + '_' + String(item.vod_id))
        }
        .columnsTemplate('1fr 1fr 1fr 1fr')
        .columnsGap(16)
        .rowsGap(20)
        .padding({ left: 24, right: 36, top: 14, bottom: 26 })
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .cachedCount(4)
      }
    }
    .layoutWeight(1)
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------- 背景：与其它页面同一套暗底 + 顶部琥珀暖光 ----------
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#1F1A1208', 0.0], ['#0C08090B', 0.45], ['#08090B', 1.0]]
        })

      Row() {
        SideNav({ active: 1 })
        // layoutWeight(1)：写 width('100%') 会把左侧 88 的导航栏顶出屏幕
        Column() {
          // ---------- 顶栏 ----------
          Row() {
            Row({ space: 12 }) {
              Text('搜索')
                .fontSize(34)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Text(this.agg ? '聚合全部可用站点' : this.siteName)
                .fontSize(12.5)
                .fontColor('#8E8E9A')
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .borderRadius(7)
                .backgroundColor('#12FFFFFF')
            }
            .alignItems(VerticalAlign.Center)

            Blank()

            Row({ space: 10 }) {
              this.topPill('agg')
              this.topPill('back')
            }
          }
          .width('100%')
          .height(56)
          .padding({ left: 44, right: 36 })
          .margin({ top: 26 })

          // ---------- 搜索输入行 ----------
          Row({ space: 12 }) {
            TextInput({ text: this.wd, placeholder: '输入片名，OK 键搜索' })
              .layoutWeight(1)
              .height(48)
              .fontSize(16)
              .fontColor('#FFFFFF')
              // placeholder 字号要单独用 placeholderFont 设，fontSize 管不到它
              .placeholderFont({ size: 13 })
              .placeholderColor('#777780')
              .backgroundColor('#12FFFFFF')
              .borderRadius(14)
              .border({ width: 1, color: '#22FFFFFF' })
              .padding({ left: 18, right: 18 })
              .onChange((v: string) => { this.wd = v; })
              .onSubmit(() => { this.doSearch(); })
            Button('搜索')
              .height(48)
              .fontSize(14)
              .fontColor('#150A04')
              .backgroundColor('#FF8A3D')
              .borderRadius(14)
              .padding({ left: 24, right: 24 })
              .onClick(() => { this.doSearch(); })
          }
          .width('100%')
          .padding({ left: 44, right: 36 })
          .margin({ top: 6 })

          // ---------- 左：历史 chip / 右：结果 ----------
          Row() {
            this.historyPane()
            this.resultPane()
          }
          .width('100%')
          .layoutWeight(1)
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')

      // 网页模式（XPath）规则的搜索要在真页面里跑，这里挂一个隐藏 WebView
      SniffWeb()
    }
    .width('100%')
    .height('100%')
  }
}
