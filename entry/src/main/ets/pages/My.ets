import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { MarkStore, VodMark } from '../utils/MarkStore';
import { PosterStore } from '../utils/PosterStore';
import { ImageCache } from '../utils/ImageCache';
import { RatingStore } from '../utils/RatingStore';
import { VodItem } from '../model/VodItem';
import { SideNav } from '../components/SideNav';
import { PinStore } from '../utils/PinStore';

/**
 * 收藏。
 *
 * 版式与「点播」海报墙一致：左侧 88 窄导航 + 6 列 172×258 海报栅格，
 * 所以从侧栏进来不会像换了个 App。
 *
 * 删除做成「管理」开关：电视上遥控器很难精准点中卡片角上的小叉，
 * 与其塞一个点不到的按钮，不如开一个模式——开着的时候点卡片就是移除，
 * 关着的时候点卡片才是打开详情。灵犀遥控器当鼠标用，两种都快。
 */
@Entry
@Component
struct My {
  @State favs: VodMark[] = [];
  /** 被家长锁挡掉的条数：只用于空态文案，不参与渲染 */
  @State hiddenN: number = 0;
  /** 管理态：点卡片 = 移除，而不是打开详情 */
  @State manage: boolean = false;
  @State focusId: string = '';
  @State hoverId: string = '';
  @State siteName: string = '';
  @StorageProp('ratingTick') ratingTick: number = 0;
  @StorageProp('posterTick') posterTick: number = 0;
  /** 外链海报本地化完成信号：读一下即触发卡片重绘 */
  @StorageProp('sitePicTick') sitePicTick: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  onPageShow(): void {
    this.refresh();
  }

  private refresh(): void {
    const ctx = getContext(this) as common.Context;
    const all: VodMark[] = MarkStore.listFav(ctx);
    // 家长锁：设了 PIN 且没解锁时，敏感分类下的收藏不显示（分类名缺失的老记录按片名兜底）
    const pin: string = PinStore.get(ctx);
    const unlocked: boolean = PinStore.isVodUnlocked();
    const out: VodMark[] = [];
    for (const m of all) {
      const tn: string = m.typeName === undefined ? '' : m.typeName;
      const nm: string = tn.length > 0 ? tn : (m.name === undefined ? '' : m.name);
      if (PinStore.shouldHide(nm, pin, unlocked)) {
        continue;
      }
      out.push(m);
    }
    this.hiddenN = all.length - out.length;
    this.favs = out;
    for (const m of out) {
      ImageCache.warm(m.pic);
    }
  }

  private hot(id: string): boolean {
    return this.focusId === id || this.hoverId === id;
  }

  private clearHot(id: string): void {
    if (this.focusId === id) {
      this.focusId = '';
    }
  }

  private picOf(m: VodMark): string {
    const probe: VodItem = { vod_id: m.vodId, vod_name: m.name, vod_pic: m.pic };
    const local: string = PosterStore.localOf(probe);
    if (local.length > 0) {
      return local;
    }
    let p: string = m.pic.trim();
    if (p.startsWith('//')) {
      p = 'https:' + p;
    }
    if (p.length > 0 && !p.startsWith('http') && !p.startsWith('file')) {
      return '';
    }
    // 读一下信号触发重绘；外链统一走本地化通道
    if (this.sitePicTick < 0) {
      return p;
    }
    return ImageCache.display(p);
  }

  private scoreOf(m: VodMark): string {
    if (this.ratingTick < 0 || this.posterTick < 0) {
      return '';
    }
    const probe: VodItem = { vod_id: m.vodId, vod_name: m.name, vod_pic: m.pic };
    return RatingStore.label(probe);
  }

  private open(m: VodMark): void {
    router.pushUrl({
      url: 'pages/Detail',
      params: { key: m.siteKey, vodId: m.vodId, name: m.name, pic: m.pic }
    }).catch(() => {});
  }

  private onCard(m: VodMark): void {
    if (this.manage) {
      const ctx = getContext(this) as common.Context;
      MarkStore.removeFav(ctx, m.siteKey, m.vodId);
      this.refresh();
      return;
    }
    this.open(m);
  }

  private clear(): void {
    const ctx = getContext(this) as common.Context;
    MarkStore.clearFav(ctx);
    this.manage = false;
    this.refresh();
  }

  /**
   * 文案与强调态在 Builder 内部读状态：@Builder 参数按值传递，外面算好传进来后
   * 状态变化不会刷新（「管理」会永远不变成「完成」）。
   */
  private pillLabel(id: string): string {
    if (id === 'manage') {
      return this.manage ? '完成' : '管理';
    }
    return id === 'clear' ? '清空' : '返回';
  }

  private pillAccent(id: string): boolean {
    return id === 'manage' && this.manage;
  }

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
      if (id === 'manage') {
        this.manage = !this.manage;
      } else if (id === 'clear') {
        this.clear();
      } else if (id === 'back') {
        router.replaceUrl({ url: 'pages/Home' }).catch(() => {});
      }
    })
  }

  @Builder
  card(m: VodMark, idx: number) {
    Column() {
      Stack({ alignContent: Alignment.TopEnd }) {
        Row()
          .width(172)
          .height(258)
          .borderRadius(13)
          .backgroundColor('#1A1B22')
        if (this.picOf(m).length > 0) {
          Image(this.picOf(m))
            .width(172)
            .height(258)
            .objectFit(ImageFit.Cover)
            .borderRadius(13)
        }
        // 底部压暗，评分角标才有底
        Column()
          .width(172)
          .height(76)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.0], ['#A6000000', 1.0]]
          })
          .margin({ top: 182 })
          .hitTestBehavior(HitTestMode.None)

        if (this.scoreOf(m).length > 0) {
          Text('★ ' + this.scoreOf(m))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFD08A')
            .backgroundColor('#B3000000')
            .borderRadius(6)
            .padding({ left: 7, right: 7, top: 2, bottom: 3 })
            .margin({ top: 218, right: 9 })
            .hitTestBehavior(HitTestMode.None)
        }

        // 管理态：整张卡加一层暗红蒙版 + 中间的叉，明确「点一下就删」
        if (this.manage) {
          Column() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(26)
              .fontColor(['#FF8B7A'])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          }
          .width(172)
          .height(258)
          .borderRadius(13)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor('#99000000')
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width(172)
      .height(258)
      .clip(true)
      .borderRadius(13)
      .border({
        width: this.hot('c' + idx) ? 2 : 1,
        color: this.hot('c' + idx) ? (this.manage ? '#FF8B7A' : '#FFD9BC') : '#1AFFFFFF'
      })
      .shadow(this.hot('c' + idx)
        ? {
          radius: 26,
          color: this.manage ? '#66FF6B4A' : '#59FF8A3D',
          offsetX: 0, offsetY: 0
        }
        : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
      .scale({ x: this.hot('c' + idx) ? 1.05 : 1, y: this.hot('c' + idx) ? 1.05 : 1 })
      .animation({ duration: 130 })

      Text(m.name)
        .fontSize(13.5)
        .fontColor('#E4E4EC')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(172)
        .margin({ top: 9 })
      Text(m.remarks.length > 0 ? m.remarks : (m.typeName === undefined ? '' : m.typeName))
        .fontSize(11)
        .fontColor('#8E8E9A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(172)
        .margin({ top: 3 })
    }
    .width(172)
    .focusable(true)
    .onFocus(() => { this.focusId = 'c' + idx; })
    .onBlur(() => { this.clearHot('c' + idx); })
    .onHover((isHover: boolean) => { this.hoverId = isHover ? 'c' + idx : ''; })
    .onClick(() => { this.onCard(m); })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：暗底 + 左上角一层暖光
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#1F1A1208', 0.0], ['#0C08090B', 0.45], ['#08090B', 1.0]]
        })

      Row() {
        SideNav({ active: 4 })
        Column() {
          // ---------- 顶栏 ----------
          Row() {
            Row({ space: 12 }) {
              Text('收藏')
                .fontSize(34)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Text(this.favs.length.toString() + ' 部')
                .fontSize(12.5)
                .fontColor('#8E8E9A')
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .borderRadius(7)
                .backgroundColor('#12FFFFFF')
              Text(this.favs.length === 0
                ? (this.hiddenN > 0 ? '有 ' + this.hiddenN.toString() + ' 部已按家长锁隐藏，解锁后可见'
                  : '在详情页点「收藏」，片子就会出现在这里')
                : (this.manage ? '管理态：点任意海报即可移出收藏' : ''))
                .fontSize(12.5)
                .fontColor(this.manage ? '#FFB37A' : '#7E7E8A')
            }
            // 与标题垂直居中
            .alignItems(VerticalAlign.Center)

            Blank()

            Row({ space: 10 }) {
              this.topPill('manage')
              if (this.favs.length > 0) {
                this.topPill('clear')
              }
            }
          }
          .width('100%')
          .height(56)
          .padding({ left: 44, right: 36 })
          .margin({ top: 26 })

          // ---------- 空态 / 栅格 ----------
          if (this.favs.length === 0) {
            Column({ space: 14 }) {
              SymbolGlyph($r('sys.symbol.bookmark'))
                .fontSize(46)
                .fontColor(['#3A3B45'])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              Text(this.hiddenN > 0 && this.favs.length === 0 ? '家长锁已开启' : '还没有收藏的影片')
                .fontSize(20)
                .fontColor('#DDDDE6')
              Text(this.hiddenN > 0 && this.favs.length === 0
                ? '在点播页解锁后回来就能看到'
                : '打开一部片子，点详情页的「收藏」，它就会出现在这里')
                .fontSize(13.5)
                .fontColor('#7E7E8A')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Grid() {
              ForEach(this.favs, (m: VodMark, idx: number) => {
                GridItem() {
                  this.card(m, idx)
                }
              }, (m: VodMark) => m.siteKey + '_' + m.vodId)
            }
            .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
            .columnsGap(16)
            .rowsGap(20)
            .padding({ left: 44, right: 36, top: 14, bottom: 26 })
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .cachedCount(6)
          }
        }
        .layoutWeight(1)
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}
