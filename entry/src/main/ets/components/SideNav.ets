import { router } from '@kit.ArkUI';

/**
 * 侧边导航（88px 极窄玻璃栏）。
 *
 * active：0 首页 / 1 点播 / 2 直播 / 3 收藏 / 4 记录 / 5 设置 / 6 关于
 *
 * 前五项是「去哪看片」，设置和关于是配置类的东西，用 Blank 压到栏底，
 * 七项平铺会把 720 的高度吃满，分成两组后一眼就能分出主次。
 *
 * 每个图标下面带一行小字标签：图标单独一个放大镜/方块组，第一次用猜不出是什么，
 * 电视上又没有顶栏可参照，所以名字必须写在界面上。
 */
@Component
export struct SideNav {
  @Prop active: number = 0;
  @State navFocus: number = -1;
  @State navHover: number = -1;
  /** 首页用于自己吞掉点击（当前页不重复跳转） */
  onHome: () => void = () => {};

  private go(i: number): void {
    if (i === this.active) {
      return;
    }
    let url: string = '';
    if (i === 0) {
      url = 'pages/Home';
    } else if (i === 1) {
      url = 'pages/Index';
    } else if (i === 2) {
      url = 'pages/Live';
    } else if (i === 3) {
      url = 'pages/My';
    } else if (i === 4) {
      url = 'pages/History';
    } else if (i === 5) {
      url = 'pages/Settings';
    } else {
      url = 'pages/About';
    }
    router.replaceUrl({ url: url }).catch(() => {});
  }

  private labelOf(i: number): string {
    if (i === 0) {
      return '首页';
    }
    if (i === 1) {
      return '点播';
    }
    if (i === 2) {
      return '直播';
    }
    if (i === 3) {
      return '收藏';
    }
    if (i === 4) {
      return '记录';
    }
    if (i === 5) {
      return '设置';
    }
    return '关于';
  }

  /** 用系统符号字体图标：矢量、随字号清晰，不用手工 Path */
  private symOf(i: number): Resource {
    if (i === 0) {
      return $r('sys.symbol.house_fill');
    }
    if (i === 1) {
      return $r('sys.symbol.play_square_stack_fill');
    }
    if (i === 2) {
      return $r('sys.symbol.dot_radiowaves_left_and_right');
    }
    if (i === 3) {
      return $r('sys.symbol.bookmark_fill');
    }
    if (i === 4) {
      return $r('sys.symbol.clock_fill');
    }
    if (i === 5) {
      return $r('sys.symbol.gearshape_fill');
    }
    return $r('sys.symbol.info_circle_fill');
  }

  private on(i: number): boolean {
    return this.navFocus === i || this.navHover === i;
  }

  @Builder
  item(i: number) {
    Column() {
      Stack() {
        SymbolGlyph(this.symOf(i))
          .fontSize(22)
          .fontColor([(this.on(i) || this.active === i) ? '#150A04' : '#9A9AA5'])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
          .width(22)
          .height(22)
      }
      .width(52)
      .height(52)
      .borderRadius(17)
      .backgroundColor(this.active === i ? '#FF8A3D'
        : (this.on(i) ? '#1FFFFFFF' : Color.Transparent))
      // 阴影只做「灯下有一点晕」的暗示：原来 radius 26 / offsetY 8 会撑到相邻两项的地盘上，
      // 在 88 宽的窄栏里看着就像被切掉一块，压到 14 后刚好落在方块自己周围
      .shadow({
        radius: this.active === i ? 14 : (this.on(i) ? 10 : 0),
        color: this.active === i ? '#4DFF8A3D' : '#1AFFFFFF',
        offsetX: 0,
        offsetY: this.active === i ? 4 : 3
      })

      Text(this.labelOf(i))
        .fontSize(10.5)
        .fontColor(this.active === i ? '#FFB37A' : (this.on(i) ? '#E4E4EC' : '#6E6E7A'))
        .margin({ top: 5 })
    }
    .width(88)
    // 上下各留 3：阴影有地方画，相邻项也不会被压住（这是「框子像被裁」的主因）
    .padding({ top: 3, bottom: 3 })
    // 显式声明不裁剪，避免父级把方块外的投影切掉
    .clip(false)
    .focusable(true)
    .onFocus(() => { this.navFocus = i; })
    .onBlur(() => { if (this.navFocus === i) { this.navFocus = -1; } })
    .onHover((isHover: boolean) => { this.navHover = isHover ? i : -1; })
    .onClick(() => {
      if (i === this.active && i === 0) {
        this.onHome();
        return;
      }
      this.go(i);
    })
  }

  build() {
    Column() {
      // 品牌标识：与桌面图标同一套橙黄渐变播放三角，透明底直接压在深色侧栏上。
      // 不再套橙色方块底和辉光，两层橙色叠在一起会糊成一片。
      Stack() {
        Image($r('app.media.nav_logo'))
          .width(36)
          .height(36)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
      .width(88)
      .height(74)

      // 项间距 10：投影半径缩到 14 之后，这个间距刚好让每一项的晕各自独立、互不压边
      Column({ space: 10 }) {
        this.item(0)
        this.item(1)
        this.item(2)
        this.item(3)
        this.item(4)
      }
      .margin({ top: 2 })

      Blank()

      // 设置 / 关于：配置类入口，压到栏底与上面「看片」的分开
      Column({ space: 10 }) {
        this.item(5)
        this.item(6)
      }
      .margin({ bottom: 16 })
    }
    .width(88)
    .height('100%')
    .backgroundColor('#08FFFFFF')
    .border({ width: { right: 1 }, color: '#12FFFFFF' })
  }
}
