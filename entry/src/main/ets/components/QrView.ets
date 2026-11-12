import { QrCode, QrResult, ECL_M } from '../utils/QrCode';

/**
 * 二维码显示：自己算矩阵、自己画 Canvas，不依赖任何二维码库。
 *
 * 两个容易踩的点：
 *   1. 必须画成「白底黑块」并且留 4 格静区。深色底上画白块的「反色码」很多
 *      手机扫不出来，电视是深色主题，容易顺手就画反。
 *   2. 同一行连续的黑块合并成一次 fillRect，4K 屏上能把绘制调用从上千次降到两三百次。
 */
@Component
export struct QrView {
  @Prop content: string = '';
  @Prop box: number = 320;
  @State failMsg: string = '';
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  build() {
    Stack() {
      Canvas(this.ctx)
        .width(this.box)
        .height(this.box)
        .backgroundColor('#ffffff')
        .onReady(() => {
          this.draw();
        })
      if (this.failMsg.length > 0) {
        Text(this.failMsg)
          .fontSize(13)
          .fontColor('#cc3333')
          .padding(12)
          .textAlign(TextAlign.Center)
      }
    }
    .width(this.box)
    .height(this.box)
  }

  private draw(): void {
    if (this.content.length === 0) {
      this.failMsg = '内容为空';
      return;
    }
    const r: QrResult = QrCode.encode(this.content, ECL_M);
    if (!r.ok) {
      this.failMsg = r.err;
      return;
    }
    this.failMsg = '';

    const px = this.box;
    const c = this.ctx;
    c.fillStyle = '#ffffff';
    c.fillRect(0, 0, px, px);
    c.fillStyle = '#000000';

    const quiet = 4;
    const total = r.size + quiet * 2;
    const cell = px / total;
    for (let y = 0; y < r.size; y++) {
      let x = 0;
      while (x < r.size) {
        if (r.modules[y][x]) {
          let run = 1;
          while (x + run < r.size && r.modules[y][x + run]) {
            run++;
          }
          // 多画 0.6vp 盖住相邻格之间的缝，缩放时不会出现白线
          c.fillRect((x + quiet) * cell, (y + quiet) * cell, run * cell + 0.6, cell + 0.6);
          x += run;
        } else {
          x++;
        }
      }
    }
  }
}
