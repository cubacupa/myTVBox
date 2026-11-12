import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { MarkStore, VodMark } from '../utils/MarkStore';
import { PinStore } from '../utils/PinStore';
import { TopBar } from '../components/TopBar';

/**
 * 播放历史：顶栏「收藏」右边那一项，读 MarkStore 的 tvbox_history.json
 * （详情页点播放时 addHistory，按影片去重、最多 100 条，remarks 是「集名 · 线路名」）。
 *
 * 页面直接进、不整页锁屏；只把「敏感词分类下的影片」从列表里摘掉，
 * 标题行右侧给「🔒 解锁 N」，输对 PIN 才把那些记录放出来。
 * 判断依据是新记录里存的 typeName（详情页 d.type_name）；升级前的老记录没这个字段，
 * 退回按片名里的敏感词兜底，详情页打开过一次会自动补上分类名。
 *
 * 解锁态是 PinStore 里的历史解锁位，**与点播首页受限分类完全独立**：
 * 在首页解锁过分类，不代表历史记录也放行，反之亦然。改 / 清 PIN、重启 App 都会重新上锁。
 * 没设 PIN 时和「收藏」一样直接显示全部，不做过滤。
 */
@Entry
@Component
struct History {
  /** 当前可见记录（隐藏项根本不进这个数组，UI 树里也不会出现） */
  @State items: VodMark[] = [];
  @State hiddenCount: number = 0;
  @State pin: string = '';
  @State histUnlocked: boolean = false;
  @State pinOpen: boolean = false;
  @State pinInput: string = '';
  @State pinErr: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  /** 从详情页回来时历史可能已被回写（集名、分类名、时间都会变） */
  onPageShow(): void {
    this.refresh();
  }

  /** 一条记录是否属于敏感词分类 */
  private isHidden(m: VodMark): boolean {
    if (PinStore.isRestricted(m.typeName ?? '')) {
      return true;
    }
    // 升级前的老记录没有 typeName 字段：用片名兜底，避免敏感片漏出来
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
  }

  /** 有隐藏项、或已经解锁过（要留一个「重新上锁」的入口）才显示这个按钮 */
  private showLockBtn(): boolean {
    return this.pin.length > 0 && (this.hiddenCount > 0 || this.histUnlocked);
  }

  private toggleLock(): void {
    if (this.histUnlocked) {
      PinStore.lockHistory();
      this.refresh();
      return;
    }
    this.pinInput = '';
    this.pinErr = '';
    this.pinOpen = true;
  }

  private confirmPin(): void {
    const ctx = getContext(this) as common.Context;
    const res: string = PinStore.verify(ctx, this.pinInput);
    if (res.length > 0) {
      this.pinErr = res;
      return;
    }
    PinStore.unlockHistory();
    this.pinOpen = false;
    this.pinInput = '';
    this.pinErr = '';
    this.refresh();
  }

  private open(m: VodMark): void {
    router.pushUrl({
      url: 'pages/Detail',
      params: { key: m.siteKey, vodId: m.vodId }
    });
  }

  private del(m: VodMark): void {
    const ctx = getContext(this) as common.Context;
    MarkStore.removeHistory(ctx, m.siteKey, m.vodId);
    this.refresh();
  }

  /** 清空是清全部（含被隐藏的），家长锁不该成为清不掉记录的理由 */
  private clear(): void {
    const ctx = getContext(this) as common.Context;
    MarkStore.clearHistory(ctx);
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
    Stack() {
      Column() {
        TopBar({ active: 4 })

        Row() {
          Text('历史').fontSize(18).fontColor('#ffffff')
          Text(' ' + this.items.length).fontSize(15).fontColor('#FF6B00').margin({ left: 6 })
          if (this.pin.length === 0) {
            Text('设置页可开启 PIN 锁').fontSize(12).fontColor('#777777').margin({ left: 16 })
          }
          Blank()
          if (this.showLockBtn()) {
            Button(this.histUnlocked ? '🔓 重新上锁' : '🔒 解锁 ' + this.hiddenCount)
              .fontSize(14)
              .height(38)
              .backgroundColor(this.histUnlocked ? '#3a3a3a' : '#4a3315')
              .fontColor(this.histUnlocked ? '#aaaaaa' : '#FF6B00')
              .margin({ right: 12 })
              .onClick(() => { this.toggleLock(); })
          }
          if (this.items.length > 0) {
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

        if (this.items.length === 0) {
          Column() {
            if (this.hiddenCount > 0) {
              Text('没有可显示的播放记录')
                .fontSize(20).fontColor('#dddddd')
              Text('有 ' + this.hiddenCount + ' 条被家长锁隐藏，点右上「🔒 解锁」查看')
                .fontSize(14).fontColor('#888888').margin({ top: 10 })
            } else {
              Text('还没有播放记录')
                .fontSize(20).fontColor('#dddddd')
              Text('在详情页点播放，看过的片子会出现在这里')
                .fontSize(14).fontColor('#888888').margin({ top: 10 })
            }
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ForEach(this.items, (m: VodMark) => {
              ListItem() {
                Row() {
                  Stack() {
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
                      Text('看到 ' + m.remarks).fontSize(13).fontColor('#FF6B00').margin({ top: 6 })
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

      // 解锁浮层：列表此时已经显示，但隐藏项仍不在 items 里，不会泄露
      if (this.pinOpen) {
        Column() {
          Column() {
            Text('解锁隐藏记录')
              .fontSize(20).fontColor('#ffffff').fontWeight(FontWeight.Bold)
            Text('输入 4 位 PIN').fontSize(13).fontColor('#9aa9b8').margin({ top: 8 })
            TextInput({ text: this.pinInput, placeholder: '4 位数字' })
              .width('100%').height(48).fontSize(18)
              .fontColor('#ffffff').placeholderColor('#777777')
              .backgroundColor('#2a2a2a').borderRadius(8)
              // 数字键盘 + 圆点掩码，与设置页 / 首页解锁框一致
              .type(InputType.NUMBER_PASSWORD)
              .showPasswordIcon(false)
              .enableAutoFill(false)
              .inputFilter('[0-9]')
              .maxLength(4)
              .margin({ top: 16 })
              .defaultFocus(true)
              .onChange((v: string) => { this.pinInput = v; })
            if (this.pinErr.length > 0) {
              Text(this.pinErr).fontSize(13).fontColor('#ff9999').width('100%').margin({ top: 8 })
            }
            Row() {
              Button('取消')
                .fontSize(14).height(40).backgroundColor('#3a3a3a').fontColor('#ffffff')
                .onClick(() => { this.pinOpen = false; })
              Button('解锁')
                .fontSize(14).height(40).backgroundColor('#FF6B00').fontColor('#ffffff')
                .margin({ left: 12 })
                .onClick(() => { this.confirmPin(); })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: 16 })
          }
          .width(400)
          .backgroundColor('#222222')
          .borderRadius(14)
          .padding(24)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000aa')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
