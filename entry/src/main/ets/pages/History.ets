import { router } from '@kit.ArkUI';
import { RatingStore } from '../utils/RatingStore';
import { common } from '@kit.AbilityKit';
import { MarkStore, VodMark } from '../utils/MarkStore';
import { PosterStore } from '../utils/PosterStore';
import { ImageCache } from '../utils/ImageCache';
import { VodItem } from '../model/VodItem';
import { PinStore } from '../utils/PinStore';
import { SideNav } from '../components/SideNav';
import { PinPad } from '../components/PinPad';

/**
 * 播放历史。
 *
 * 数据来自 MarkStore 的 tvbox_history.json（详情页点播放时写入，按影片去重、最多 100 条）。
 * 页面直接进、不整页锁屏；只把「敏感词分类下的影片」从列表里摘掉，
 * 标题行右侧给「解锁 N」，输对 PIN 才把那些记录放出来。
 *
 * 解锁态与点播首页的受限分类**完全独立**：在首页解锁过分类，不代表历史也放行。
 * 没设 PIN 时和「收藏」一样直接显示全部。
 *
 * 删除同样是「管理」开关：开着点卡片 = 移除，关着点卡片 = 打开详情。
 */
@Entry
@Component
struct History {
  @State items: VodMark[] = [];
  @State hiddenCount: number = 0;
  @State pin: string = '';
  @State histUnlocked: boolean = false;
  @State pinOpen: boolean = false;
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

  private isHidden(m: VodMark): boolean {
    if (PinStore.isRestricted(m.typeName ?? '')) {
      return true;
    }
    // 老记录没有 typeName：退回片名兜底，别让敏感片漏出来
    return m.typeName === undefined && PinStore.isRestricted(m.name ?? '');
  }

  private refresh(): void {
    const ctx = getContext(this) as common.Context;
    this.pin = PinStore.get(ctx);
    this.histUnlocked = this.pin.length > 0 && PinStore.isHistoryUnlocked();
    const all: VodMark[] = MarkStore.listHistory(ctx);
    if (this.pin.length === 0 || this.histUnlocked) {
      this.items = all;
      this.hiddenCount = 0;
      this.warmPics(all);
      return;
    }
    const vis: VodMark[] = [];
    let n: number = 0;
    for (const m of all) {
      if (this.isHidden(m)) {
        n++;
      } else {
        vis.push(m);
      }
    }
    this.items = vis;
    this.hiddenCount = n;
    this.warmPics(vis);
  }

  /**
   * 列表页补图。历史里只存了站点的 vod_pic，很多老图床域名早就失效了，
   * 直连和本地化都拿不到 —— 详情页能出图靠的是按片名从豆瓣刮削，这里照做一遍。
   * 只补「本地还没有图」的片：RatingStore / PosterStore 内部都有去重和失败上限。
   */
  private warmPics(marks: VodMark[]): void {
    const items: VodItem[] = [];
    for (const m of marks) {
      ImageCache.warm(m.pic);
      const probe: VodItem = { vod_id: m.vodId, vod_name: m.name, vod_pic: m.pic };
      if (PosterStore.localOf(probe).length === 0) {
        items.push(probe);
      }
    }
    if (items.length > 0) {
      RatingStore.warm(items);
    }
  }

  private showLockBtn(): boolean {
    return this.pin.length > 0 && (this.hiddenCount > 0 || this.histUnlocked);
  }

  private toggleLock(): void {
    if (this.histUnlocked) {
      PinStore.lockHistory();
      this.refresh();
      return;
    }
    this.pinOpen = true;
  }

  /** 数字键盘输对 PIN 才放开隐藏记录 */
  private onPinDone(ok: boolean): void {
    this.pinOpen = false;
    if (!ok) {
      return;
    }
    PinStore.unlockHistory();
    this.refresh();
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
    // 读一下信号触发重绘；外链统一走本地化通道（豆瓣/QQ 图床直连在电视上画不出来）
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
      MarkStore.removeHistory(ctx, m.siteKey, m.vodId);
      this.refresh();
      return;
    }
    this.open(m);
  }

  /** 清空清全部（含被隐藏的）：家长锁不该成为清不掉记录的理由 */
  private clear(): void {
    const ctx = getContext(this) as common.Context;
    MarkStore.clearHistory(ctx);
    this.manage = false;
    this.refresh();
  }

  /** 「刚刚 / 3 小时前 / 昨天 / 5 天前」 */
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

  private subOf(m: VodMark): string {
    const seen: string = this.ago(m.time);
    // 历史记录的 remarks 是「集名 · 线路名」（例如「TC超清版 · bfzym3u8」），
    // 线路名对用户没意义，海报下面一行又窄，只留前半段。
    let head: string = m.remarks;
    const cut: number = head.indexOf(' · ');
    if (cut > 0) {
      head = head.substring(0, cut);
    }
    if (head.length > 0) {
      return head + (seen.length > 0 ? ' · ' + seen : '');
    }
    return seen;
  }

  /**
   * 文案与配色在 Builder 内部读状态：@Builder 参数按值传递，外面算好传进来后
   * 状态变化不会刷新（解锁按钮会永远显示旧文案）。
   */
  private pillLabel(id: string): string {
    if (id === 'lock') {
      return this.histUnlocked ? '重新上锁' : '解锁 ' + this.hiddenCount.toString();
    }
    if (id === 'manage') {
      return this.manage ? '完成' : '管理';
    }
    return '清空';
  }

  private pillAccent(id: string): boolean {
    return id === 'manage' && this.manage;
  }

  private pillWarn(id: string): boolean {
    return id === 'lock';
  }

  @Builder
  topPill(id: string) {
    Row() {
      Text(this.pillLabel(id))
        .fontSize(13.5)
        .fontWeight(this.pillAccent(id) ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.pillAccent(id) ? '#150A04'
          : (this.pillWarn(id) ? '#FFB37A' : (this.hot(id) ? '#FFD9BC' : '#C9C9D4')))
    }
    .height(40)
    .padding({ left: 18, right: 18 })
    .borderRadius(20)
    .backgroundColor(this.pillAccent(id) ? '#FF8A3D'
      : (this.pillWarn(id) ? '#22FF8A3D' : (this.hot(id) ? '#1C1D25' : '#12FFFFFF')))
    .border({
      width: 1,
      color: this.pillAccent(id) ? Color.Transparent
        : (this.pillWarn(id) ? '#73FF8A3D' : (this.hot(id) ? '#FFD9BC' : '#22FFFFFF'))
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
      } else if (id === 'lock') {
        this.toggleLock();
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
      Text(this.subOf(m))
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
          // ---------- 顶栏 ----------
          Row() {
            Row({ space: 12 }) {
              Text('记录')
                .fontSize(34)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Text(this.items.length.toString() + ' 条')
                .fontSize(12.5)
                .fontColor('#8E8E9A')
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .borderRadius(7)
                .backgroundColor('#12FFFFFF')
              Text(this.manage ? '管理态：点任意海报即可删除这条记录'
                : (this.pin.length === 0 ? '看过什么都在这里（可在设置里开启 PIN 锁）'
                  : '长片断点续播：点海报回到上次那一集'))
                .fontSize(12.5)
                .fontColor(this.manage ? '#FFB37A' : '#7E7E8A')
            }
            // 与标题垂直居中
            .alignItems(VerticalAlign.Center)

            Blank()

            Row({ space: 10 }) {
              if (this.showLockBtn()) {
                this.topPill('lock')
              }
              this.topPill('manage')
              if (this.items.length > 0) {
                this.topPill('clear')
              }
            }
          }
          .width('100%')
          .height(56)
          .padding({ left: 44, right: 36 })
          .margin({ top: 26 })

          // ---------- 空态 / 栅格 ----------
          if (this.items.length === 0) {
            Column({ space: 14 }) {
              SymbolGlyph($r('sys.symbol.clock'))
                .fontSize(46)
                .fontColor(['#3A3B45'])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              if (this.hiddenCount > 0) {
                Text('没有可显示的播放记录')
                  .fontSize(20)
                  .fontColor('#DDDDE6')
                Text('有 ' + this.hiddenCount.toString() + ' 条被家长锁隐藏，点右上「解锁」查看')
                  .fontSize(13.5)
                  .fontColor('#7E7E8A')
              } else {
                Text('还没有播放记录')
                  .fontSize(20)
                  .fontColor('#DDDDE6')
                Text('在详情页点播放，看过的片子会按时间出现在这里')
                  .fontSize(13.5)
                  .fontColor('#7E7E8A')
              }
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Grid() {
              ForEach(this.items, (m: VodMark, idx: number) => {
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

      // ---------- PIN 数字键盘 ----------
      if (this.pinOpen) {
        PinPad({
          pin: this.pin,
          title: '解锁隐藏记录',
          onFinish: (ok: boolean) => {
            this.onPinDone(ok);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}
