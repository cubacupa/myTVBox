import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { MarkStore, VodMark } from '../utils/MarkStore';
import { TopBar } from '../components/TopBar';

/**
 * 收藏：只有收藏列表（顶栏「收藏」这一项）。
 *
 * 播放进度**不在**这里展示，也不需要展示：续播点单独存在 PlayProgress 里，
 * 键是「站点_影片_线路_集数」，值是毫秒。详情页点播放会自动从上次的位置接上。
 * 播放记录是顶栏右边那个独立的「历史」页（pages/History.ets，受 PIN 保护），
 * 读的是 MarkStore 里 tvbox_history.json，两边各读各的，互不干扰。
 */
@Entry
@Component
struct My {
  @State favs: VodMark[] = [];

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    const ctx = getContext(this) as common.Context;
    this.favs = MarkStore.listFav(ctx);
  }

  private open(m: VodMark): void {
    router.pushUrl({
      url: 'pages/Detail',
      params: { key: m.siteKey, vodId: m.vodId }
    });
  }

  private del(m: VodMark): void {
    const ctx = getContext(this) as common.Context;
    MarkStore.removeFav(ctx, m.siteKey, m.vodId);
    this.refresh();
  }

  private clear(): void {
    const ctx = getContext(this) as common.Context;
    MarkStore.clearFav(ctx);
    this.refresh();
  }

  private fmtTime(ms: number): string {
    if (!ms) {
      return '';
    }
    const d = new Date(ms);
    const pad = (n: number): string => {
      return n < 10 ? '0' + n : '' + n;
    };
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }

  build() {
    Column() {
      TopBar({ active: 2 })

      Row() {
        Text('收藏').fontSize(18).fontColor('#ffffff')
        Text(' ' + this.favs.length).fontSize(15).fontColor('#FF6B00').margin({ left: 6 })
        Blank()
        if (this.favs.length > 0) {
          Button('清空')
            .fontSize(14)
            .height(38)
            .backgroundColor('#3a3a3a')
            .fontColor('#ffffff')
            .onClick(() => { this.clear(); })
        }
      }
      .width('100%')
      .padding({ left: 28, right: 28, top: 8, bottom: 8 })

      if (this.favs.length === 0) {
        Column() {
          Text('还没有收藏的影片')
            .fontSize(20).fontColor('#dddddd')
          Text('在详情页点「☆ 收藏」就会出现在这里')
            .fontSize(14).fontColor('#888888').margin({ top: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.favs, (m: VodMark) => {
            ListItem() {
              Row() {
                Stack() {
                  // 占位框：没图 / 图挂了都能看见一个方框，不会留白
                  Column() {
                    Text(m.name && m.name.length > 0 ? m.name.substring(0, 1) : '影')
                      .fontSize(22)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#4d4d4d')
                  }
                  .width(62)
                  .height(86)
                  .justifyContent(FlexAlign.Center)
                  .alignItems(HorizontalAlign.Center)
                  .backgroundColor('#232323')
                  .borderRadius(6)
                  .border({ width: 1, color: '#3a3a3a' })

                  if (m.pic && m.pic.length > 0) {
                    Image(m.pic)
                      .width(62)
                      .height(86)
                      .objectFit(ImageFit.Cover)
                      .borderRadius(6)
                      .onError(() => {})
                  }
                }
                .width(62)
                .height(86)
                .borderRadius(6)

                Column() {
                  Text(m.name).fontSize(17).fontColor('#ffffff').maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (m.remarks && m.remarks.length > 0) {
                    Text(m.remarks).fontSize(13).fontColor('#FF6B00').margin({ top: 6 })
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Text(this.fmtTime(m.time)).fontSize(12).fontColor('#777777').margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 14 })

                Button('删除')
                  .fontSize(13)
                  .height(34)
                  .backgroundColor('#3a3a3a')
                  .fontColor('#ffffff')
                  .onClick(() => { this.del(m); })
              }
              .width('100%')
              .padding(12)
              .backgroundColor('#202020')
              .borderRadius(8)
              .focusable(true)
              .onClick(() => { this.open(m); })
            }
          }, (m: VodMark) => m.siteKey + '_' + m.vodId + '_' + String(m.time))
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 28, right: 28, bottom: 20 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#161616')
  }
}
