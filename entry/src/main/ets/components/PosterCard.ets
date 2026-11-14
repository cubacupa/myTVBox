import { VodItem } from '../model/VodItem';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { RatingStore } from '../utils/RatingStore';
import { PosterStore } from '../utils/PosterStore';

/**
 * TV 海报卡片：可被遥控器焦点选中的影片卡片。
 * 获得焦点时放大 + 描边，遥控器 OK 键触发 onSelect（跳详情）。
 *
 * 图像分层叠放，从下到上：
 *   0 占位框（灰底 + 片名首字 + "暂无海报"）—— 永远在，兜住所有失败情况
 *   1 站点自带的 vod_pic —— 加载成功才淡入
 *   2 豆瓣刮削图（本地沙箱文件）—— 盖在站点图之上，因为它是补缺/替换用的
 *   3 角标：左上年份、右下评分 —— 必须最上层，用显式 zIndex(10) 钉死，
 *     否则刮削图一到位就把角标盖掉了（海报和评分经常是同一帧里先后到达的）。
 *
 * 刮削图只有 onComplete 之后才淡入，所以从占位 → 站点图 → 刮削图
 * 的替换过程不会有空白闪烁。
 *
 * 两套视觉：
 *   modern=false（默认，搜索页在用）旧深灰 + 亮橙描边
 *   modern=true（点播海报墙）暗底 + 琥珀，卡宽卡高由外部传，焦点用白色内描边 + 暖色外发光
 *   灵犀遥控器是鼠标，modern 版额外接 onHover，鼠标移上去就点亮。
 */
@Component
export struct PosterCard {
  @Prop @Watch('onItemChange') item: VodItem = { vod_id: '', vod_name: '', vod_pic: '' };
  @State isFocused: boolean = false;
  @State isHover: boolean = false;
  @State picUri: string = '';
  @State picOk: boolean = false;
  /** 刮削到的本地海报（file:// 路径），空表示还没刮到 */
  @State scrapedUri: string = '';
  @State scrapedOk: boolean = false;
  /** 评分缓存更新信号：后台补到新分数时 RatingStore 会 +1，卡片跟着重绘角标 */
  @StorageProp('ratingTick') ratingTick: number = 0;
  /** 海报刮削信号：PosterStore 存好一张图就 +1 */
  @StorageProp('posterTick') @Watch('onPosterTick') posterTick: number = 0;
  /** 新版视觉 + 外部指定尺寸 */
  @Prop modern: boolean = false;
  /** 卡片宽度；0 表示铺满父容器（旧行为） */
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
    this.picUri = p;
    this.picOk = false;
  }

  /** 查本地有没有刮削好的海报；变了才重置标记，避免每帧重建 Image */
  private syncPoster(): void {
    const p: string = PosterStore.localOf(this.item);
    if (p !== this.scrapedUri) {
      this.scrapedUri = p;
      this.scrapedOk = false;
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
    return this.isFocused || (this.modern && this.isHover);
  }

  private radius(): number {
    return this.modern ? 13 : 8;
  }

  build() {
    Column() {
      Stack() {
        // ---- 第 0 层：占位框，永久存在 ----
        Column() {
          Text(this.initial())
            .fontSize(this.modern ? 30 : 26)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.modern ? '#3A3B45' : '#4d4d4d')
          Text('暂无海报')
            .fontSize(10)
            .fontColor(this.modern ? '#43444F' : '#5a5a5a')
            .margin({ top: 5 })
        }
        .width('100%')
        .height(this.cardH)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.modern ? '#1A1B22' : '#232323')
        .borderRadius(this.radius())
        .border({ width: 1, color: this.modern ? '#14FFFFFF' : '#3a3a3a' })
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
            .borderRadius(this.radius())
            .zIndex(1)
            .onComplete(() => {
              this.picOk = true;
            })
            .onError(() => {
              this.picOk = false;
              this.picUri = '';
            })
        }

        // ---- 第 2 层：豆瓣刮削图，本地文件，盖住站点图 ----
        if (this.scrapedUri.length > 0) {
          Image(this.scrapedUri)
            .width('100%')
            .height(this.cardH)
            .objectFit(ImageFit.Cover)
            .borderRadius(this.radius())
            .zIndex(2)
            .onComplete(() => {
              this.scrapedOk = true;
            })
            .onError((err: ImageError) => {
              this.scrapedOk = false;
              hilog.error(0x0001, 'PosterCard', 'scrape img fail [%{public}s]: %{public}s',
                this.scrapedUri, err.message);
              this.scrapedUri = '';
            })
        }

        // ---- 第 3 层：底部压暗，让角标和文字有底 ----
        if (this.modern) {
          Column()
            .width('100%')
            .height(72)
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#A6000000', 1.0]]
            })
            .zIndex(5)
            .hitTestBehavior(HitTestMode.None)
        }

        // ---- 第 4 层：左上角年份 ----
        if (this.yearText().length > 0) {
          Column() {
            Text(this.yearText())
              .fontSize(this.modern ? 14 : 18)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.modern ? '#E4E4EC' : '#f2f2f2')
              .backgroundColor('#CC000000')
              .borderRadius(6)
              .padding({ left: this.modern ? 6 : 8, right: this.modern ? 6 : 8, top: 2, bottom: 3 })
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
            Text((this.modern ? '★ ' : '★ ') + this.scoreText())
              .fontSize(this.modern ? 15 : 22)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.modern ? '#FFD08A' : '#FFD24A')
              .backgroundColor('#B3000000')
              .borderRadius(6)
              .padding({
                left: this.modern ? 7 : 9, right: this.modern ? 7 : 9,
                top: 2, bottom: 3
              })
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
        .fontSize(this.modern ? 13.5 : 13)
        .fontColor(this.modern ? '#E4E4EC' : '#eeeeee')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.w())
        .margin({ top: this.modern ? 9 : 6 })
      if (this.item.vod_remarks) {
        Text(this.item.vod_remarks)
          .fontSize(this.modern ? 11 : 11)
          .fontColor(this.modern ? '#8E8E9A' : '#FF6B00')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(this.w())
          .margin({ top: this.modern ? 3 : 0 })
      }
    }
    .width(this.w())
    .borderRadius(this.modern ? 13 : 10)
    .border({
      width: this.isFocused ? (this.modern ? 2 : 3) : 0,
      color: this.isFocused ? (this.modern ? '#FFD9BC' : '#FF6B00') : Color.Transparent
    })
    .shadow(this.modern && this.lit()
      ? { radius: 26, color: '#59FF8A3D', offsetX: 0, offsetY: 0 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .scale({
      x: this.lit() ? (this.modern ? 1.05 : 1.08) : 1,
      y: this.lit() ? (this.modern ? 1.05 : 1.08) : 1
    })
    .animation({ duration: this.modern ? 130 : 150 })
    .focusable(true)
    .onFocus(() => { this.isFocused = true; })
    .onBlur(() => { this.isFocused = false; })
    .onHover((isHover: boolean) => { this.isHover = isHover; })
    .onClick(() => this.onSelect())
  }
}
