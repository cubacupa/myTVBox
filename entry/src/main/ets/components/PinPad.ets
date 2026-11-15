/**
 * 家长锁数字键盘。
 *
 * 为什么不用「对话框 + TextInput」：电视上要两步（先出板、再点输入框唤软键盘），
 * 软键盘还会盖掉整屏。这里直接给一块 3×4 数字键盘，方向键 / 灵犀遥控都点得到，
 * 输满 4 位立刻校验——对了直接解锁，不用再点一次「确认」。
 */
const KEYS: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', 'clear', '0', 'cancel'];

@Component
export struct PinPad {
  /** 正确的 4 位 PIN */
  @Prop pin: string;
  /** 标题：两个入口文案不同（家长锁 / 解锁隐藏记录） */
  @Prop title: string;
  /** true = 输对了；false = 取消关闭 */
  onFinish: (ok: boolean) => void = (ok: boolean) => {};
  @State input: string = '';
  @State err: string = '';
  @State focusId: string = '';

  aboutToAppear(): void {
    // 打开就把焦点落在中间的 5 上：方向键上下游走最顺
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('pk-5');
      } catch (e) {
        // 拿不到焦点不影响使用，用户自己按方向键也能到位
      }
    }, 80);
  }

  /** 点一下键：满 4 位即校验，不再有单独的「解锁」按钮 */
  private press(k: string): void {
    if (k === 'cancel') {
      this.onFinish(false);
      return;
    }
    if (k === 'clear') {
      this.input = '';
      this.err = '';
      return;
    }
    if (this.input.length >= 4) {
      return;
    }
    this.input = this.input + k;
    this.err = '';
    if (this.input.length < 4) {
      return;
    }
    if (this.input === this.pin) {
      this.onFinish(true);
    } else {
      this.err = 'PIN 不对';
      this.input = '';
    }
  }

  private labelOf(k: string): string {
    if (k === 'clear') {
      return '清空';
    }
    if (k === 'cancel') {
      return '取消';
    }
    return k;
  }

  private active(k: string): boolean {
    return this.focusId === 'pk-' + k;
  }

  @Builder
  padKey(k: string) {
    Row() {
      Text(this.labelOf(k))
        .fontSize(k === 'clear' || k === 'cancel' ? 14 : 21)
        .fontWeight(k === 'clear' || k === 'cancel' ? FontWeight.Normal : FontWeight.Medium)
        .fontColor(this.active(k) ? '#150A04' : (k === 'cancel' ? '#8E8E9A' : '#E4E4EC'))
    }
    .width('100%')
    .height(54)
    .justifyContent(FlexAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.active(k) ? '#FF8A3D' : '#12FFFFFF')
    .id('pk-' + k)
    .focusable(true)
    .onFocus(() => {
      this.focusId = 'pk-' + k;
    })
    .onBlur(() => {
      if (this.focusId === 'pk-' + k) {
        this.focusId = '';
      }
    })
    .onHover((isHover: boolean) => {
      if (isHover) {
        this.focusId = 'pk-' + k;
      } else if (this.focusId === 'pk-' + k) {
        this.focusId = '';
      }
    })
    .onClick(() => {
      this.press(k);
    })
  }

  build() {
    Column() {
      Column() {
        Text(this.title)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')

        // 四个点位：输一位亮一个
        Row({ space: 14 }) {
          ForEach([0, 1, 2, 3], (i: number) => {
            Row()
              .width(13)
              .height(13)
              .borderRadius(7)
              .backgroundColor(i < this.input.length ? '#FF8A3D' : '#26FFFFFF')
          }, (i: number) => i.toString())
        }
        .margin({ top: 14 })

        if (this.err.length > 0) {
          Text(this.err)
            .fontSize(12.5)
            .fontColor('#FF8B7A')
            .margin({ top: 10 })
        }

        Grid() {
          ForEach(KEYS, (k: string) => {
            GridItem() {
              this.padKey(k)
            }
          }, (k: string) => k)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .width('100%')
        .height(246)
        .margin({ top: 16 })
      }
      .width(340)
      .padding(22)
      .backgroundColor('#14151C')
      .border({ width: 1, color: '#1AFFFFFF' })
      .borderRadius(22)
      .shadow({ radius: 60, color: '#B3000000', offsetX: 0, offsetY: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#B3000000')
    .justifyContent(FlexAlign.Center)
  }
}
