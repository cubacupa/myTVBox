import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { MarkStore, VodMark } from '../utils/MarkStore';
import { PosterStore } from '../utils/PosterStore';
import { RatingStore } from '../utils/RatingStore';
import { VodItem } from '../model/VodItem';
import { SideNav } from '../components/SideNav';

/**
 * 收藏（现代版视觉）。
 *
 * 版式与「点播」海报墙一致：左侧 88 窄导航 + 6 列 172×258 海报栅格，
 * 所以从首页「我的收藏 ›」进来不会像换了个 App。
 *
 * 删除做成「管理」开关：电视上遥控器很难精准点中卡片角上的小叉，
 * 与其塞一个点不到的按钮，不如开一个模式——开着的时候点卡片就是移除，
 * 关着的时候点卡片才是打开详情。灵犀遥控器当鼠标用，两种都快。
 */
@Entry
@Component
struct My {
  @State favs: VodMark[] = [];
  /** 管理态：点卡片 = 移除，而不是打开详情 */
  @State manage: boolean = false;
  @State focusId: string = '';
  @State hoverId: string = '';
  @State siteName: string = '';
  @StorageProp('ratingTick') ratingTick: number = 0;
  @StorageProp('posterTick') posterTick: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  onPageShow(): void {
    this.refresh();
  }

  private refresh(): void {
    const ctx = getContext(this) as common.Context;
    this.favs = MarkStore.listFav(ctx);
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
    return p;
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
      params: { key: m.siteKey, vodId: m.vodId }
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

  @Builder
  topPill(id: string, label: string, accent: boolean) {
    Row() {
      Text(label)
        .fontSize(13.5)
        .fontWeight(accent ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(accent ? '#150A04' : (this.hot(id) ? '#FFD9BC' : '#C9C9D4'))
    }
    .height(40)
    .padding({ left: 18, right: 18 })
    .borderRadius(20)
    .backgroundColor(accent ? '#FF8A3D'
      : (this.hot(id) ? '#1C1D25' : '#12FFFFFF'))
    .border({
      width: 1,
      color: accent ? Color.Transparent : (this.hot(id) ? '#FFD9BC' : '#22FFFFFF')
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
        SideNav({ active: 3, siteName: this.siteName })
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
              Text(this.favs.length === 0 ? '在详情页点「收藏」，片子就会出现在这里'
                : (this.manage ? '管理态：点任意海报即可移出收藏' : ''))
                .fontSize(12.5)
                .fontColor(this.manage ? '#FFB37A' : '#7E7E8A')
            }
            // 与标题垂直居中
            .alignItems(VerticalAlign.Center)

            Blank()

            Row({ space: 10 }) {
              this.topPill('manage', this.manage ? '完成' : '管理', this.manage)
              if (this.favs.length > 0) {
                this.topPill('clear', '清空', false)
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
              Text('还没有收藏的影片')
                .fontSize(20)
                .fontColor('#DDDDE6')
              Text('打开一部片子，点详情页的「收藏」，它就会出现在这里')
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
