import { VodItem } from '../model/VodItem';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RatingStore } from '../utils/RatingStore';
import { PosterStore } from '../utils/PosterStore';
import { ImageCache } from '../utils/ImageCache';

/** 豆瓣图床直连会被当盗链回 403，这类地址必须先在本地落一份 */
function needLocalPic(u: string): boolean {
  return u.indexOf('doubanio.com') >= 0;
}

/**
 * TV 海报卡片：可被遥控器焦点选中的影片卡片。
 * 获得焦点时放大 + 描边，遥控器 OK 键触发 onSelect（跳详情）。
 *
 * 图像分层叠放，从下到上：
 *   0 占位框（灰底 + 片名首字 + "暂无海报"）—— 永远在，兜住所有失败情况
 *   1 站点自带的 vod_pic —— 有地址就画，失败时退回占位框
 *   2 豆瓣刮削图（本地沙箱文件）—— 盖在站点图之上，因为它是补缺/替换用的
 *   3 底部压暗 + 角标：左上年份、右下评分 —— 用显式 zIndex(10) 钉死，
 *     否则刮削图一到位就把角标盖掉了（海报和评分经常是同一帧里先后到达的）。
 *
 * 只有一套视觉：暗底 + 琥珀、卡宽卡高由外部传，焦点用白色内描边 + 暖色外发光。
 * 灵犀遥控器是鼠标，额外接 onHover，鼠标移上去就点亮。
 */
@Component
export struct PosterCard {
  @Prop @Watch('onItemChange') item: VodItem = { vod_id: '', vod_name: '', vod_pic: '' };
  @State isFocused: boolean = false;
  @State isHover: boolean = false;
  @State picUri: string = '';
  /** 站点给的原始外链：直连失败时用它走本地化通道重试 */
  @State rawPic: string = '';
  /** 这张卡片是否已经试过本地化，防止 onError 反复触发时死循环 */
  @State localTried: boolean = false;
  /** 刮削到的本地海报（file:// 路径），空表示还没刮到 */
  @State scrapedUri: string = '';
  /** 评分缓存更新信号：后台补到新分数时 RatingStore 会 +1，卡片跟着重绘角标 */
  @StorageProp('ratingTick') ratingTick: number = 0;
  /** 海报刮削信号：PosterStore 存好一张图就 +1 */
  @StorageProp('posterTick') @Watch('onPosterTick') posterTick: number = 0;
  /** 卡片宽度；0 表示铺满父容器 */
  @Prop cardW: number = 0;
  /** 海报高度 */
  @Prop cardH: number = 200;
  onSelect: () => void = () => {};

  aboutToAppear(): void {
    this.syncItem();
    this.syncPoster();
  }

  onItemChange(): void {
    this.syncItem();
    this.syncPoster();
  }

  onPosterTick(): void {
    this.syncPoster();
  }

  /** 取出可用图片地址；相对 / 协议相对的地址补全成绝对 http(s)。 */
  private syncItem(): void {
    let p: string = this.item.vod_pic ? this.item.vod_pic.trim() : '';
    if (p.startsWith('//')) {
      p = 'https:' + p;
    }
    if (p.length > 0 && !p.startsWith('http://') && !p.startsWith('https://') && !p.startsWith('data:')) {
      p = '';
    }
    this.rawPic = p;
    this.picUri = p;
    this.localTried = false;
    // 豆瓣图床直连必 403（Image 组件带不了 Referer），先本地落盘再画
    if (p.length > 0 && needLocalPic(p)) {
      this.useLocal(p);
    }
  }

  /** 换成本地文件：已有缓存立刻用，没有就下完再换 */
  private useLocal(u: string): void {
    if (this.localTried) {
      return;
    }
    this.localTried = true;
    const hit: string = ImageCache.cached(u);
    if (hit.length > 0) {
      this.picUri = hit;
      return;
    }
    // 先清空：直连那张图必然失败，别让用户看一帧破图
    this.picUri = '';
    if (ImageCache.hasFailed(u)) {
      return;
    }
    ImageCache.local(u, '').then((f: string) => {
      if (f.length > 0) {
        this.picUri = f;
      }
    });
  }

  /** 查本地有没有刮削好的海报；变了才换地址，避免每帧重建 Image */
  private syncPoster(): void {
    const p: string = PosterStore.localOf(this.item);
    if (p !== this.scrapedUri) {
      this.scrapedUri = p;
    }
  }

  private initial(): string {
    const n: string = this.item.vod_name ? this.item.vod_name.trim() : '';
    return n.length > 0 ? n.substring(0, 1) : '影';
  }

  /**
   * 海报左上角年份。站点的 vod_year 写法很杂（2024 / 2024年 / 2024-05-01 / 2024/05），
   * 统一取头一个 4 位数字；没有年份或不是年份就返回空串，不占用海报。
   */
  private yearText(): string {
    const y: string = this.item.vod_year ? this.item.vod_year.trim() : '';
    for (let i = 0; i + 4 <= y.length; i++) {
      const s: string = y.substring(i, i + 4);
      if (/^\d{4}$/.test(s)) {
        return s;
      }
    }
    return '';
  }

  /** 豆瓣评分文字（"8.9"）；没分返回空串。读一下 ratingTick 让后台补分后能触发重绘 */
  private scoreText(): string {
    if (this.ratingTick < 0 || this.posterTick < 0) {
      return '';
    }
    return RatingStore.label(this.item);
  }

  /** 卡片目标宽度：0 走父容器的 100% */
  private w(): Length {
    return this.cardW > 0 ? this.cardW : '100%';
  }

  /** 焦点或鼠标悬停都算亮起 */
  private lit(): boolean {
    return this.isFocused || this.isHover;
  }

  build() {
    Column() {
      Stack() {
        // ---- 第 0 层：占位框，永久存在 ----
        Column() {
          Text(this.initial())
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('#3A3B45')
          Text('暂无海报')
            .fontSize(10)
            .fontColor('#43444F')
            .margin({ top: 5 })
        }
        .width('100%')
        .height(this.cardH)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#1A1B22')
        .borderRadius(13)
        .border({ width: 1, color: '#14FFFFFF' })
        .zIndex(0)

        // ---- 第 1 层：站点自带的图 ----
        // 不加 opacity 门槛：opacity(0) 的 Image 在部分设备上不参与渲染，onComplete 永远不回来，
        // 于是图片一辈子透明——本地图加载只要几十毫秒，直接画出来更稳，
        // 失败时清空地址退回占位框。
        if (this.picUri.length > 0) {
          Image(this.picUri)
            .width('100%')
            .height(this.cardH)
            .objectFit(ImageFit.Cover)
            .borderRadius(13)
            .zIndex(1)
            .onError(() => {
              this.picUri = '';
              // 别的站的外链也可能设了防盗链，先转本地再试一次（每个 item 只试一次）
              if (this.rawPic.length > 0) {
                this.useLocal(this.rawPic);
              }
            })
        }

        // ---- 第 2 层：豆瓣刮削图，本地文件，盖住站点图 ----
        if (this.scrapedUri.length > 0) {
          Image(this.scrapedUri)
            .width('100%')
            .height(this.cardH)
            .objectFit(ImageFit.Cover)
            .borderRadius(13)
            .zIndex(2)
            .onError((err: ImageError) => {
              hilog.error(0x0001, 'PosterCard', 'scrape img fail [%{public}s]: %{public}s',
                this.scrapedUri, err.message);
              this.scrapedUri = '';
            })
        }

        // ---- 第 3 层：底部压暗，让角标和文字有底 ----
        Column()
          .width('100%')
          .height(72)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.0], ['#A6000000', 1.0]]
          })
          .zIndex(5)
          .hitTestBehavior(HitTestMode.None)

        // ---- 第 4 层：左上角年份 ----
        if (this.yearText().length > 0) {
          Column() {
            Text(this.yearText())
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor('#E4E4EC')
              .backgroundColor('#CC000000')
              .borderRadius(6)
              .padding({ left: 6, right: 6, top: 2, bottom: 3 })
          }
          .width('100%')
          .height(this.cardH)
          .justifyContent(FlexAlign.Start)
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 8, top: 8 })
          .zIndex(10)
          .hitTestBehavior(HitTestMode.None)
        }

        // ---- 第 5 层：右下角评分，永远最上 ----
        if (this.scoreText().length > 0) {
          Column() {
            Text('★ ' + this.scoreText())
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFD08A')
              .backgroundColor('#B3000000')
              .borderRadius(6)
              .padding({ left: 7, right: 7, top: 2, bottom: 3 })
          }
          .width('100%')
          .height(this.cardH)
          .justifyContent(FlexAlign.End)
          .alignItems(HorizontalAlign.End)
          .padding({ right: 8, bottom: 8 })
          .zIndex(10)                          // 海报是后到的，不钉住就会被盖
          .hitTestBehavior(HitTestMode.None)   // 别挡住卡片的点击与焦点
        }
      }
      .width(this.w())
      .height(this.cardH)

      Text(this.item.vod_name)
        .fontSize(13.5)
        .fontColor('#E4E4EC')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.w())
        .margin({ top: 9 })
      if (this.item.vod_remarks) {
        Text(this.item.vod_remarks)
          .fontSize(11)
          .fontColor('#8E8E9A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(this.w())
          .margin({ top: 3 })
      }
    }
    .width(this.w())
    .borderRadius(13)
    .border({
      width: this.isFocused ? 2 : 0,
      color: this.isFocused ? '#FFD9BC' : Color.Transparent
    })
    .shadow(this.lit()
      ? { radius: 26, color: '#59FF8A3D', offsetX: 0, offsetY: 0 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .scale({
      x: this.lit() ? 1.05 : 1,
      y: this.lit() ? 1.05 : 1
    })
    .animation({ duration: 130 })
    .focusable(true)
    .onFocus(() => { this.isFocused = true; })
    .onBlur(() => { this.isFocused = false; })
    .onHover((isHover: boolean) => { this.isHover = isHover; })
    .onClick(() => this.onSelect())
  }
}
