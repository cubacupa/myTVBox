import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ConfigStore } from '../utils/ConfigStore';
import { AppState } from '../utils/AppState';
import { LiveGroup, LiveChannel } from '../utils/LiveApi';
import { LiveSrcProbe } from '../utils/LiveSrcProbe';
import { LiveMarkStore, LiveFav } from '../utils/LiveMarkStore';
import { LiveCfg } from '../model/TvBoxModels';
import { SideNav } from '../components/SideNav';

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
  /** 遥控器焦点标记（自绘焦点态） */
  @State focusId: string = '';
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
    setTimeout(() => { this.getUIContext().getFocusController().requestFocus('live-ch-0'); }, 400);
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

  /** 频道台标文字：中文取首字，英文数字连取两位（CCTV-1 → CC） */
  private logoText(ch: LiveChannel): string {
    const n: string = ch.name.trim();
    if (n.length === 0) {
      return '·';
    }
    const first: string = n.substring(0, 1);
    if (/[A-Za-z0-9]/.test(first)) {
      return n.length >= 2 ? n.substring(0, 2).toUpperCase() : first.toUpperCase();
    }
    return first;
  }

  /** 台标底色：按频道名散列取一个稳定色，同名永远同色 */
  private logoColor(ch: LiveChannel): string {
    const palette: string[] = [
      '#D8443C', '#2F6FD0', '#D9861F', '#12A38F',
      '#7A4CD9', '#3B9A4E', '#C4417A', '#4A6FA5'
    ];
    let h: number = 0;
    for (let i = 0; i < ch.name.length; i++) {
      h = (h * 31 + ch.name.charCodeAt(i)) % 9973;
    }
    return palette[h % palette.length];
  }

  private subTitle(): string {
    const n: number = this.curChannels().length;
    if (this.showFav) {
      return '收藏频道 ' + n.toString() + ' 个 · 存在本机，与直播源无关';
    }
    const g: string = this.curGroupName();
    const head: string = g.length > 0 ? g + ' · ' : '';
    return head + n.toString() + ' 个频道'
      + (this.hiddenCount > 0 ? ' · 已隐藏 ' + this.hiddenCount.toString() + ' 个空源' : '');
  }

  @Builder
  topChip(label: string, on: boolean, urlKey: string, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(13.5)
        .fontWeight(on ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(on ? '#150A04' : '#B9B9C6')
        .maxLines(1)
    }
    .height(42)
    .padding({ left: 18, right: 18 })
    .borderRadius(21)
    .backgroundColor(on ? '#FF8A3D' : '#10FFFFFF')
    .border({ width: 1, color: this.focusId === urlKey ? '#FFD9BC' : (on ? '#FF8A3D' : '#1AFFFFFF') })
    .focusable(true)
    .onFocus(() => { this.focusId = urlKey; })
    .onBlur(() => { this.focusId = ''; })
    .onClick(onTap)
  }

  @Builder
  groupRow(g: LiveGroup, idx: number) {
    Row() {
      // 当前分组用一根橙色竖条标记，不再给整行套一圈边框：
      // 一列行都描边时，被染色的那一圈看着就像多出来的「当前选框」
      Row()
        .width(3)
        .height(22)
        .borderRadius(2)
        .backgroundColor(!this.showFav && idx === this.groupIdx ? '#FF8A3D' : Color.Transparent)
        .margin({ right: 11 })

      Column({ space: 3 }) {
        Text(g.name)
          .fontSize(14.5)
          .fontWeight(!this.showFav && idx === this.groupIdx ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(!this.showFav && idx === this.groupIdx ? '#FFB37A' : '#C9C9D4')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(g.channels.length.toString() + ' 个频道')
          .fontSize(11.5)
          .fontColor(!this.showFav && idx === this.groupIdx ? '#A97C5E' : '#6E6E7A')
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 14, top: 12, bottom: 12 })
    .borderRadius(12)
    // 和频道卡同一套焦点语言：只提亮底色、不画框，当前分组另靠竖条 + 文字颜色
    .backgroundColor(!this.showFav && idx === this.groupIdx
      ? (this.focusId === ('g-' + idx) ? '#2BFF8A3D' : '#1FFF8A3D')
      : (this.focusId === ('g-' + idx) ? '#1AFFFFFF' : '#0AFFFFFF'))
    .focusable(true)
    .onFocus(() => { this.focusId = 'g-' + idx; })
    .onBlur(() => { this.focusId = ''; })
    .onClick(() => {
      this.groupIdx = idx;
      this.showFav = false;
      this.tip = '';
    })
  }

  @Builder
  channelCard(ch: LiveChannel, idx: number) {
    Row({ space: 11 }) {
      // 台标：多数 txt 源没有 logo，用首字色块代替，比空白或破图强
      Stack() {
        Row()
          .width(42)
          .height(42)
          .borderRadius(12)
          .backgroundColor(this.logoColor(ch))
        Text(this.logoText(ch))
          .fontSize(this.logoText(ch).length > 1 ? 15 : 19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .width(42)
      .height(42)

      Column({ space: 4 }) {
        Text(ch.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isSeen(ch) ? '#8A867E' : '#EDEDF2')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(ch.lines.length > 1 ? ch.lines.length.toString() + ' 条线路' : '单线路')
          .fontSize(11.5)
          .fontColor(this.isSeen(ch) ? '#5C5A55' : '#7E7E8A')
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.isFav(ch) ? '★' : '☆')
        .fontSize(15)
        .fontColor(this.isFav(ch) ? '#FFB300' : '#5F5F6B')
        .padding({ left: 4, right: 8, top: 6, bottom: 6 })
        .onClick(() => { this.toggleFav(ch); })
    }
    .width('100%')
    .height(82)
    .padding({ left: 14, right: 8 })
    .borderRadius(16)
    // 焦点只做「底色提亮 + 微微浮起」：原来那圈白边和橙色辉光像在宣告
    // 「这张是当前播放」，其实只是光标停在这儿
    .backgroundColor(this.focusId === ('c-' + idx) ? '#26FFFFFF' : '#0DFFFFFF')
    .scale({ x: this.focusId === ('c-' + idx) ? 1.015 : 1, y: this.focusId === ('c-' + idx) ? 1.015 : 1 })
    .animation({ duration: 140 })
    .id('live-ch-' + idx)
    .focusable(true)
    .defaultFocus(idx === 0)
    .onFocus(() => { this.focusId = 'c-' + idx; })
    .onBlur(() => { this.focusId = ''; })
    .onClick(() => { this.play(ch); })
  }

  build() {
    Row() {
      SideNav({ active: 2, siteName: AppState.configName })
      Stack({ alignContent: Alignment.TopStart }) {
        // 背景：冷蓝氛围光 + 深色底
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 150,
            colors: [['#0C1226', 0.0], ['#08090B', 0.62], ['#08090B', 1.0]]
          })
        Column()
          .width(1100)
          .height(700)
          .borderRadius(550)
          .linearGradient({
            angle: 120,
            colors: [['#332A46FF', 0.0], ['#0A1A2AFF', 0.6], ['#00000000', 1.0]]
          })
          .blur(60)
          .margin({ left: 1100, top: -260 })

        Column() {
          // ---- 标题行 ----
          Row() {
            Row({ space: 12 }) {
              Text('直播')
                .fontSize(34)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              // 与点播/设置同一套：标题右侧接一行小字，不再另起一行
              Text(this.subTitle())
                .fontSize(12.5)
                .fontColor('#7E7E8A')
            }
            .alignItems(VerticalAlign.Center)

            Blank()

            // 直播源切换（只有多个可用源时才出现）
            if (this.okLives.length > 1) {
              Row({ space: 8 }) {
                ForEach(this.okLives, (l: LiveCfg, idx: number) => {
                  this.topChip(l.name, idx === this.liveIdx, 'src-' + idx, () => { this.loadLive(idx); })
                }, (l: LiveCfg, idx: number) => l.name + String(idx))
              }
              .margin({ right: 12 })
            }

            // 「收藏」和「清除已看」原来直接相邻，两个胶囊边贴边，看着像粘在一起
            Row({ space: 10 }) {
              this.topChip(this.favUrls.length > 0 ? '★ 收藏 ' + this.favUrls.length.toString() : '☆ 收藏',
                this.showFav, 'favbtn', () => {
                  this.showFav = !this.showFav;
                  this.tip = '';
                })

              if (this.seenUrls.length > 0 && !this.showFav) {
                this.topChip('清除已看', false, 'clear', () => { this.clearSeen(); })
              }
            }
          }
          .width('100%')
          .height(56)
          .alignItems(VerticalAlign.Center)
          .margin({ top: 26 })

          // ---- 主体 ----
          if (this.lives.length === 0 && this.favUrls.length === 0 && !this.showFav) {
            Column({ space: 14 }) {
              Text('没有直播源')
                .fontSize(24)
                .fontColor('#EDEDF2')
              Text('去设置里单独填一个 m3u / txt 直链，或载入一份带直播源的配置')
                .fontSize(14)
                .fontColor('#8E8E9A')
              Text('打开设置')
                .fontSize(16)
                .fontColor('#150A04')
                .height(50)
                .padding({ left: 30, right: 30 })
                .borderRadius(25)
                .backgroundColor('#FF8A3D')
                .textAlign(TextAlign.Center)
                .margin({ top: 10 })
                .focusable(true)
                .onClick(() => { router.replaceUrl({ url: 'pages/Settings' }).catch(() => {}); })
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (!this.showFav && this.loading) {
            Column({ space: 12 }) {
              LoadingProgress().width(46).height(46).color('#FF8A3D')
              Text(this.probeTip.length > 0 ? this.probeTip : '正在加载直播源…')
                .fontSize(13.5)
                .fontColor('#8E8E9A')
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else if (!this.showFav && this.err.length > 0) {
            Column({ space: 18 }) {
              Text(this.err)
                .fontSize(15)
                .fontColor('#FF8B7A')
                .textAlign(TextAlign.Center)
                .width(900)
              Text('重试')
                .fontSize(16)
                .fontColor('#EDEDF2')
                .height(50)
                .padding({ left: 32, right: 32 })
                .borderRadius(25)
                .backgroundColor('#16FFFFFF')
                .textAlign(TextAlign.Center)
                .focusable(true)
                .onClick(() => {
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
              // 左侧分组
              Column() {
                Text('分组')
                  .fontSize(12)
                  .fontColor('#6E6E7A')
                  .width('100%')
                  .margin({ bottom: 10, left: 6 })
                List({ space: 8 }) {
                  ForEach(this.uiGroups, (g: LiveGroup, idx: number) => {
                    ListItem() {
                      this.groupRow(g, idx)
                    }
                  }, (g: LiveGroup, idx: number) => g.name + String(idx))
                }
                .width('100%')
                .layoutWeight(1)
                .scrollBar(BarState.Off)
              }
              .width(196)
              .height('100%')
              .alignItems(HorizontalAlign.Start)

              // 右侧频道
              Column() {
                if (this.tip.length > 0) {
                  Text(this.tip)
                    .fontSize(12.5)
                    .fontColor('#FFB37A')
                    .width('100%')
                    .margin({ bottom: 10, left: 4 })
                }
                if (this.curChannels().length === 0) {
                  Text(this.showFav ? '还没有收藏频道。在频道卡片右侧点 ☆ 就能收藏' : '这个分组里没有频道')
                    .fontSize(14)
                    .fontColor('#7E7E8A')
                    .margin({ top: 40 })
                } else {
                  Grid() {
                    ForEach(this.curChannels(), (ch: LiveChannel, idx: number) => {
                      GridItem() {
                        this.channelCard(ch, idx)
                      }
                    }, (ch: LiveChannel, idx: number) => ch.name + String(idx) + ch.url)
                  }
                  .columnsTemplate('1fr 1fr 1fr')
                  .columnsGap(14)
                  .rowsGap(14)
                  .width('100%')
                  .layoutWeight(1)
                  .scrollBar(BarState.Off)
                }
              }
              .layoutWeight(1)
              .height('100%')
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 28 })
            }
            .width('100%')
            .layoutWeight(1)
            .alignItems(VerticalAlign.Top)
            .margin({ top: 26 })
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 48, right: 52, bottom: 26 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}
