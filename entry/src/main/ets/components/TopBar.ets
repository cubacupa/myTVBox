import { router } from '@kit.ArkUI';

/**
 * 顶部导航条：点播 / 直播 / 收藏 / 历史 / 设置。
 * 用 replaceUrl 切换，避免页面栈越叠越深。
 *
 * active 索引：点播 0 / 直播 1 / 收藏 2 / 设置 3 / 历史 4。
 * 历史用 4 而不是把设置顺延，是为了不动其它四个页面已经写死的 active；
 * 渲染顺序靠下面 tabItem 的排列控制，历史上照样显示在「收藏」右边。
 *
 * showActions / siteName / filterCount + 三个回调：首页专用。
 * 首页把「筛选 / 站点 / 搜索」放在这里，和下面「分类横排」彻底分开，
 * 分类再多也只在自己那一行横向滚动，不会挤到按钮。
 */
@Component
export struct TopBar {
  @Prop active: number = 0;
  @Prop showActions: boolean = false;
  @Prop siteName: string = '';
  @Prop filterCount: number = 0;
  /** 首页专用第 4 个按钮：把当前站点收进 Default。空串 = 不渲染 */
  @Prop collectText: string = '';
  @State focusIdx: number = -1;
  @State actionFocus: number = -1;
  onFilter: () => void = () => {};
  onSites: () => void = () => {};
  onSearch: () => void = () => {};
  onCollect: () => void = () => {};

  private go(i: number): void {
    if (i === this.active) {
      return;
    }
    let url = 'pages/Index';
    if (i === 1) {
      url = 'pages/Live';
    } else if (i === 2) {
      url = 'pages/My';
    } else if (i === 3) {
      url = 'pages/Settings';
    } else if (i === 4) {
      url = 'pages/History';
    }
    router.replaceUrl({ url: url }).catch(() => {});
  }

  @Builder
  tabItem(label: string, i: number) {
    Text(label)
      .fontSize(18)
      .fontColor(i === this.active ? '#FF6B00' : '#bbbbbb')
      .fontWeight(i === this.active ? FontWeight.Bold : FontWeight.Normal)
      .padding({ left: 18, right: 18, top: 9, bottom: 9 })
      .borderRadius(8)
      .backgroundColor(this.focusIdx === i ? '#353535' : Color.Transparent)
      .focusable(true)
      .onFocus(() => { this.focusIdx = i; })
      .onBlur(() => { this.focusIdx = -1; })
      .onClick(() => this.go(i))
  }

  @Builder
  actionItem(idx: number, onTap: () => void) {
    // 注意：这里不接收 label 参数。@Builder 的入参是值传递，父组件状态变了
    // 也不会重建节点（切站后站点名一直停在旧的）。统一在内部读 this.* 才有响应式。
    Text(this.actionLabel(idx))
      .fontSize(14)
      .fontColor(idx === 0 && this.filterCount > 0 ? '#FF6B00' : '#ffffff')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .height(36)
      .padding({ left: 16, right: 16 })
      .backgroundColor(idx === 0 && this.filterCount > 0 ? '#4a3315'
        : (this.actionFocus === idx ? '#3d3d3d' : '#2a2a2a'))
      .borderRadius(18)
      .border({ width: 2, color: this.actionFocus === idx ? '#FF6B00' : Color.Transparent })
      .margin({ left: idx === 0 ? 0 : 10 })
      .focusable(true)
      .onFocus(() => { this.actionFocus = idx; })
      .onBlur(() => { this.actionFocus = -1; })
      .onClick(onTap)
  }

  private actionLabel(idx: number): string {
    if (idx === 0) {
      return this.filterCount > 0 ? '筛选 ' + this.filterCount : '筛选';
    }
    if (idx === 1) {
      return this.siteName + ' ▾';
    }
    if (idx === 3) {
      return this.collectText;
    }
    return '搜索';
  }

  build() {
    Row() {
      // 品牌字标：白字 myTVB + 橙色 O（环内是橙色播放三角）+ 白 x + 橙色方块。
      // 资源为透明 PNG：黑底与圆环内黑底都已抠成透明，只留白字和橙色，边缘做去黑边软边。
      // 按 31vp 高等比缩放；宽高写死，避免 Image 按原始像素撑开 68vp 高的顶栏
      Image($r('app.media.logo_my_tv_box'))
        .width(154)
        .height(31)
        .objectFit(ImageFit.Contain)
        .draggable(false)
      Row() {
        this.tabItem('点播', 0)
        this.tabItem('直播', 1)
        this.tabItem('收藏', 2)
        this.tabItem('历史', 4)
        this.tabItem('设置', 3)
      }.margin({ left: 28 })
      Blank()
      if (this.showActions) {
        Row() {
          this.actionItem(0, this.onFilter)
          this.actionItem(1, this.onSites)
          this.actionItem(2, this.onSearch)
          if (this.collectText.length > 0) {
            this.actionItem(3, this.onCollect)
          }
        }
        .constraintSize({ maxWidth: 640 })
      }
    }
    .width('100%')
    .height(68)
    .padding({ left: 28, right: 28 })
    .backgroundColor('#1b1b1b')
  }
}
