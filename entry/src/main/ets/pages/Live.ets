import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ConfigStore } from '../utils/ConfigStore';
import { AppState } from '../utils/AppState';
import { LiveGroup, LiveChannel } from '../utils/LiveApi';
import { LiveSrcProbe } from '../utils/LiveSrcProbe';
import { LiveMarkStore, LiveFav } from '../utils/LiveMarkStore';
import { LiveCfg } from '../model/TvBoxModels';
import { TopBar } from '../components/TopBar';

/**
 * 直播页：解析配置里的 lives（txt 频道表 / m3u 播放列表），左侧分组、右侧频道。
 *
 * 两个跟"能不能用"直接相关的小功能：
 *   - 收藏：右上角常驻「★ 收藏 (N)」按钮（和「清除已看标记」并排），只读本机收藏文件，
 *     跟直播源载入成功与否无关；点开是独立收藏视图，但左侧分组栏始终在，
 *     点任意分组即可回到直播频道；格子里点右上角星标可取消（点星不会播放）
 *   - 已点过：点过的频道整格变暗，避免对着一堆死频道反复点
 *
 * 还有一件：配置里的 lives 常有好几个是空壳（302 / 502 / 只有注释），
 * 进页面先探活，能出频道的才上屏；只剩一个能用时连切换栏都不显示。
 */
@Entry
@Component
struct Live {
  /** 配置里的全部直播源（含空壳，仅用于「有没有源」判断与隐藏计数） */
  @State lives: LiveCfg[] = [];
  /** 探活通过的直播源：切换栏只认这份 */
  @State okLives: LiveCfg[] = [];
  /** 已确认是空壳、被藏起来的源个数 */
  @State hiddenCount: number = 0;
  /** 首屏逐个试源时的进度提示 */
  @State probeTip: string = '';
  @State liveIdx: number = 0;
  @State groups: LiveGroup[] = [];
  /** 实际渲染用的分组：只含直播源自己的分组，收藏由左上角按钮独立展示 */
  @State uiGroups: LiveGroup[] = [];
  @State groupIdx: number = 0;
  /** 是否正在看「收藏」视图：跟直播源载入状态完全独立 */
  @State showFav: boolean = false;
  @State loading: boolean = false;
  @State err: string = '';
  /** 收藏 / 取消收藏后的即时反馈 */
  @State tip: string = '';
  /** 收藏 / 已点过的地址快照，用于渲染与判断（Store 里也有一份，避免每次读文件） */
  @State favUrls: string[] = [];
  @State seenUrls: string[] = [];
  /** 刚点过星标的时间戳：GridItem 的 onClick 会跟着触发，用它挡掉"收藏顺手把片子打开" */
  private lastStarTs: number = 0;
  private ctx: common.Context | null = null;

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    const ctx = getContext(this) as common.Context;
    this.ctx = ctx;
    this.refreshMarks();
    await ConfigStore.init(ctx);
    // 直播源可以跟点播源不同地址（设置页可单独载入），这里统一读 AppState.lives
    this.lives = AppState.lives;
    if (this.lives.length === 0) {
      // 没有直播源时收藏照样能看：收藏只认本机文件，直接落到收藏视图
      this.rebuildGroups();
      if (this.favUrls.length > 0) {
        this.showFav = true;
      }
      return;
    }
    await this.openFirstGood();
  }

  /**
   * 先按顺序试到第一份能出频道的源并上屏，剩下的在后台慢慢探。
   *
   * 以前是直接拿 lives[0] 去加载：配置里第一个恰好是死链（302 空响应）时，
   * 用户进来先看到「这个直播源里没有解析到频道」，得自己一个个点过去试；
   * 而点过去的那两个其实永远是空的。
   */
  private async openFirstGood(): Promise<void> {
    this.loading = true;
    this.err = '';
    this.groups = [];
    this.uiGroups = [];
    this.okLives = [];
    this.hiddenCount = 0;
    for (let i = 0; i < this.lives.length; i++) {
      this.probeTip = '正在加载直播源 ' + (i + 1) + '/' + this.lives.length + '：' + this.lives[i].name;
      const gs: LiveGroup[] | null = await LiveSrcProbe.load(this.lives[i]);
      if (gs !== null) {
        this.okLives = [this.lives[i]];
        this.liveIdx = 0;
        this.groups = gs;
        this.loading = false;
        this.rebuildGroups();
        // 其余源后台探活：探通了才补进切换栏，空的不出现
        this.probeRest(i + 1).catch(() => {});
        return;
      }
      this.hiddenCount = this.hiddenCount + 1;
    }
    this.loading = false;
    this.err = '这 ' + this.lives.length + ' 个直播源都没解析出频道'
      + (LiveSrcProbe.lastReason().length > 0 ? '：' + LiveSrcProbe.lastReason() : '');
  }

  /** 后台依次探剩下的源；只有真能出频道的才追加到切换栏 */
  private async probeRest(from: number): Promise<void> {
    for (let i = from; i < this.lives.length; i++) {
      const gs: LiveGroup[] | null = await LiveSrcProbe.load(this.lives[i]);
      if (gs !== null) {
        const next: LiveCfg[] = this.okLives.slice();
        next.push(this.lives[i]);
        this.okLives = next;
      } else {
        this.hiddenCount = this.hiddenCount + 1;
      }
    }
  }

  private async loadLive(idx: number): Promise<void> {
    if (idx < 0 || idx >= this.okLives.length) {
      return;
    }
    this.liveIdx = idx;
    // 点了某个直播源就回到该源的分组，别还停在收藏视图里
    this.showFav = false;
    this.loading = true;
    this.err = '';
    this.groups = [];
    this.uiGroups = [];
    this.groupIdx = 0;
    const gs: LiveGroup[] | null = await LiveSrcProbe.load(this.okLives[idx]);
    if (gs === null) {
      // 探活过的源一般走不到这里；真走到说明地址临时抽了，直接把原因摊开
      const why: string = LiveSrcProbe.badReason(this.okLives[idx].url);
      this.err = '这个直播源没有解析到频道' + (why.length > 0 ? '：' + why : '');
    } else {
      this.groups = gs;
      this.rebuildGroups();
    }
    this.loading = false;
  }

  private refreshMarks(): void {
    if (this.ctx === null) {
      return;
    }
    const f: string[] = [];
    for (const it of LiveMarkStore.favs(this.ctx)) {
      f.push(it.url);
    }
    this.favUrls = f;
    this.seenUrls = LiveMarkStore.seenList(this.ctx).slice();
  }

  /** 只放直播源自身的分组（收藏不再混进来），尽量保持当前选中的分组不变 */
  private rebuildGroups(): void {
    const keepName: string = (this.uiGroups.length > 0 && this.groupIdx < this.uiGroups.length)
      ? this.uiGroups[this.groupIdx].name : '';
    const out: LiveGroup[] = [];
    for (const g of this.groups) {
      out.push(g);
    }
    this.uiGroups = out;
    let next: number = 0;
    if (keepName.length > 0) {
      for (let i = 0; i < out.length; i++) {
        if (out[i].name === keepName) {
          next = i;
          break;
        }
      }
    }
    this.groupIdx = next;
  }

  /** 收藏频道：只读本机收藏文件，不看 lives、不看探活结果 */
  private favChannels(): LiveChannel[] {
    const out: LiveChannel[] = [];
    if (this.ctx === null) {
      return out;
    }
    for (const f of LiveMarkStore.favs(this.ctx)) {
      const ch: LiveChannel = {
        id: f.name, name: f.name, url: f.url, logo: '',
        lines: [{ name: '', url: f.url }]
      };
      out.push(ch);
    }
    return out;
  }

  private curChannels(): LiveChannel[] {
    if (this.showFav) {
      return this.favChannels();
    }
    if (this.uiGroups.length === 0 || this.groupIdx >= this.uiGroups.length) {
      return [];
    }
    return this.uiGroups[this.groupIdx].channels;
  }

  /** 一个频道的全部线路地址（合并后可能有好几条） */
  private lineUrls(ch: LiveChannel): string[] {
    const out: string[] = [];
    for (const l of ch.lines) {
      out.push(l.url);
    }
    if (out.length === 0 && ch.url.length > 0) {
      out.push(ch.url);
    }
    return out;
  }

  private isFav(ch: LiveChannel): boolean {
    if (this.favUrls.indexOf(ch.url) >= 0) {
      return true;
    }
    for (const u of this.lineUrls(ch)) {
      if (this.favUrls.indexOf(u) >= 0) {
        return true;
      }
    }
    return false;
  }

  private isSeen(ch: LiveChannel): boolean {
    for (const u of this.lineUrls(ch)) {
      if (this.seenUrls.indexOf(u) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 格子区顶部那行小字：收藏反馈优先，其次说明「藏掉了几个空源」 */
  private infoText(): string {
    if (this.tip.length > 0) {
      return this.tip;
    }
    if (this.showFav) {
      return this.favUrls.length > 0
        ? '收藏频道存在本机，与直播源无关 · 点左侧分组回到直播频道 · 点格子右上角 ★ 取消收藏'
        : '还没有收藏频道 · 点左侧分组看直播，在格子右上角点 ☆ 收藏';
    }
    const head: string = this.hiddenCount > 0
      ? '已隐藏 ' + this.hiddenCount + ' 个空的直播源 · ' : '';
    return head + '已点过但放不出来的频道会变暗 · 点格子右上角 ☆ 收藏';
  }

  private curGroupName(): string {
    const gs: LiveGroup[] = this.uiGroups;
    if (this.groupIdx < gs.length) {
      return gs[this.groupIdx].name;
    }
    return '';
  }

  private toggleFav(ch: LiveChannel): void {
    if (this.ctx === null) {
      return;
    }
    this.lastStarTs = Date.now();
    const f: LiveFav = { name: ch.name, url: ch.url, group: this.showFav ? '★ 收藏' : this.curGroupName() };
    const on: boolean = LiveMarkStore.toggleFav(this.ctx, f, this.lineUrls(ch));
    this.refreshMarks();
    this.rebuildGroups();
    this.tip = (on ? '已收藏「' : '已取消收藏「') + ch.name + '」';
  }

  private play(ch: LiveChannel): void {
    // 星标刚被点过就跳过：同一次点击冒泡上来的 onClick 不该触发播放
    if (Date.now() - this.lastStarTs < 600) {
      return;
    }
    const urls: string[] = this.lineUrls(ch);
    if (urls.length === 0) {
      return;
    }
    const key: string = ch.id.length > 0 ? ch.id : ch.name;
    // 上次真能放出来的线路优先，没有就从第一条开始。
    // 源站的第一条经常已经串台（放出来是购物台）或者直接失效，所以不能盲信顺序。
    let start: number = 0;
    if (this.ctx !== null) {
      const good: string = LiveMarkStore.lastGood(this.ctx, key);
      if (good.length > 0) {
        for (let i = 0; i < urls.length; i++) {
          if (urls[i] === good) {
            start = i;
            break;
          }
        }
      }
      // 点过就记下所有线路（不管能不能放出来）——正是为了下次避开死频道
      for (const u of urls) {
        LiveMarkStore.markSeen(this.ctx, u);
      }
      this.refreshMarks();
    }
    router.pushUrl({
      url: 'pages/Player',
      params: {
        url: urls[start],
        title: ch.name,
        flag: 'live',
        progId: '',
        isLive: true,
        // 同一频道的其余线路一起带过去，播放页可以「换线路」，失败还会自动试下一条
        lines: urls,
        lineIdx: start,
        liveKey: key
      }
    });
  }

  private clearSeen(): void {
    if (this.ctx === null) {
      return;
    }
    LiveMarkStore.clearSeen(this.ctx);
    this.refreshMarks();
  }

  build() {
    Column() {
      TopBar({ active: 1 })
      // 顶部工具行常驻：右侧「★ 收藏」只读本机收藏文件，
      // 直播源加载中 / 解析失败 / 压根没有源，都不影响它显示和点开。
      Row() {
        // 直播源切换：只列探活通过的源。只剩一个能用时整条切换栏不渲染，
        // 免得一个孤零零的按钮占着位置还让用户以为「是不是还有别的源」
        if (this.okLives.length > 1) {
          List({ space: 10 }) {
            ForEach(this.okLives, (l: LiveCfg, idx: number) => {
              ListItem() {
                Text(l.name)
                  .fontSize(15)
                  .fontColor(idx === this.liveIdx ? '#ffffff' : '#cccccc')
                  .backgroundColor(idx === this.liveIdx ? '#FF6B00' : '#2a2a2a')
                  .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                  .borderRadius(6)
                  .focusable(true)
                  .onClick(() => { this.loadLive(idx); })
              }
            }, (l: LiveCfg, idx: number) => l.name + String(idx))
          }
          .listDirection(Axis.Horizontal)
          .height(58)
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        } else {
          Blank()
        }

        // 收藏按钮和「清除已看标记」并排放在右侧。看收藏时左侧分组栏照常保留，
        // 点任意分组就回到该直播源的频道列表，不用非得再点一次收藏按钮。
        Text('★ 收藏' + (this.favUrls.length > 0 ? ' (' + this.favUrls.length + ')' : ''))
          .fontSize(14)
          .fontColor(this.showFav ? '#ffffff' : '#FFB300')
          .backgroundColor(this.showFav ? '#FF6B00' : '#2f2a22')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(6)
          .focusable(true)
          .onClick(() => {
            this.showFav = !this.showFav;
            this.tip = '';
          })

        if (this.seenUrls.length > 0) {
          Text('清除已看标记')
            .fontSize(13)
            .fontColor('#9aa9b8')
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .backgroundColor('#2f2f2f')
            .borderRadius(6)
            .margin({ left: 10 })
            .focusable(true)
            .onClick(() => { this.clearSeen(); })
        }
      }
      .width('100%')
      .padding({ left: 28, right: 28, top: 4 })

      if (this.lives.length === 0 && this.favUrls.length === 0 && !this.showFav) {
        Column() {
          Text('没有直播源').fontSize(22).fontColor('#dddddd')
          Text('设置页 → 直播源：单独填一个 m3u / txt 直链，或载入一份带 lives 的配置')
            .fontSize(15).fontColor('#888888')
            .margin({ top: 12 })
          Button('去设置').margin({ top: 26 })
            .onClick(() => { router.replaceUrl({ url: 'pages/Settings' }); })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        if (!this.showFav && this.loading) {
          Column() {
            LoadingProgress().width(48).height(48)
            Text(this.probeTip.length > 0 ? this.probeTip : '正在加载直播源…')
              .fontSize(14).fontColor('#999999').margin({ top: 10 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (!this.showFav && this.err) {
          Column() {
            Text(this.err).fontSize(16).fontColor('#ff7777')
            Button('重试').margin({ top: 18 }).onClick(() => {
              // 清掉失败缓存再试：可能是网络临时抽了，别让一次失败锁死这次运行
              LiveSrcProbe.reset();
              if (this.okLives.length > 0) {
                this.loadLive(this.liveIdx);
              } else {
                this.openFirstGood();
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Row() {
            // 左侧分组常驻：看收藏时也能点任意分组回到直播频道，
            // 只是此刻没有「当前分组」，所以不高亮任何一项
            List({ space: 8 }) {
              ForEach(this.uiGroups, (g: LiveGroup, idx: number) => {
                ListItem() {
                  Text(g.name + ' (' + g.channels.length + ')')
                    .fontSize(14)
                    .fontColor(!this.showFav && idx === this.groupIdx ? '#FF6B00' : '#cccccc')
                    .width('100%')
                    .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                    .backgroundColor(!this.showFav && idx === this.groupIdx ? '#2f2a22' : '#202020')
                    .borderRadius(6)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .focusable(true)
                    .onClick(() => {
                      this.groupIdx = idx;
                      this.showFav = false;
                      this.tip = '';
                    })
                }
              }, (g: LiveGroup, idx: number) => g.name + String(idx))
            }
            .width(210)
            .height('100%')
            .padding({ left: 24, right: 10 })
            .scrollBar(BarState.Off)

            Column() {
              Text(this.infoText())
                .fontSize(12).fontColor(this.tip.length > 0 ? '#FF9F45' : '#777777')
                .width('100%').margin({ bottom: 8 })

              Grid() {
                ForEach(this.curChannels(), (ch: LiveChannel, idx: number) => {
                  GridItem() {
                    Stack({ alignContent: Alignment.TopEnd }) {
                      // 已点过 → 整格压暗；未点过保持正常亮度
                      Column() {
                        Text(ch.name)
                          .fontSize(15)
                          .fontColor(this.isSeen(ch) ? '#6d675f' : '#dddddd')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .width('100%')
                          .textAlign(TextAlign.Center)
                        // 源站同一频道常给好几条地址，合并后在这里标出线路数，
                        // 点进去会用「上次能放的」那条，放不出来还能在播放页换
                        if (ch.lines.length > 1) {
                          Text(ch.lines.length + ' 条线路')
                            .fontSize(11)
                            .fontColor(this.isSeen(ch) ? '#585349' : '#8a8a8a')
                            .width('100%')
                            .textAlign(TextAlign.Center)
                            .margin({ top: 2 })
                        }
                      }
                      .width('100%')
                      .padding({ top: 13, bottom: 13, left: 30, right: 30 })
                      .backgroundColor(this.isSeen(ch) ? '#1b1b1b' : '#262626')
                      .borderRadius(6)

                      Text(this.isFav(ch) ? '★' : '☆')
                        .fontSize(15)
                        .fontColor(this.isFav(ch) ? '#FFB300' : '#7a7a7a')
                        .padding({ left: 8, right: 8, top: 5, bottom: 5 })
                        .onClick(() => { this.toggleFav(ch); })
                    }
                    .width('100%')
                    .focusable(true)
                    .onClick(() => { this.play(ch); })
                  }
                }, (ch: LiveChannel, idx: number) => ch.name + String(idx) + ch.url)
              }
              .columnsTemplate('1fr 1fr 1fr 1fr')
              .columnsGap(12)
              .rowsGap(12)
              .layoutWeight(1)
              .width('100%')
            }
            .layoutWeight(1)
            .height('100%')
            .padding({ right: 28, top: 6, bottom: 16 })
          }
          .width('100%')
          .layoutWeight(1)
          .alignItems(VerticalAlign.Top)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#161616')
  }
}
