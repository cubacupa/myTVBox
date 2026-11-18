import { webview } from '@kit.ArkWeb';
import { sniffer, SNIFF_SCRIPT } from '../utils/WebSniffer';

/**
 * 隐藏的无头 WebView。ArkWeb 没有真正的 headless 模式，页面上必须有一个
 * Web 组件在，controller 才有东西可操作，所以做成 2×2、全透明、不吃点击的
 * 一角小方块：看不见、点不到、也不进焦点，只在解析播放页时干活。
 *
 * 用法：页面根容器的最后一个子节点摆一个 SniffWeb()，
 * 之后 SiteApi / PlayUrlResolver 里的 XPath 与嗅探就自动可用。
 */
@Component
export struct SniffWeb {
  private ctl: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    sniffer.mount(this.ctl);
  }

  aboutToDisappear(): void {
    sniffer.unmountIf(this.ctl);
  }

  build() {
    Web({ src: 'about:blank', controller: this.ctl })
      // 必须用桌面 UA：番剧站大多按 UA 分流，移动端 UA 会拿到手机版模板，
      // 而规则里的 XPath 是作者在桌面浏览器上按 PC 版 DOM 写的，换成手机版就全对不上。
      .userAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .mediaPlayGestureAccess(false)
      .mixedMode(MixedMode.All)
      .javaScriptOnDocumentStart([{ script: SNIFF_SCRIPT, scriptRules: ['*'] }])
      .onControllerAttached(() => {
        sniffer.markAttached(this.ctl);
      })
      .width(2)
      .height(2)
      .opacity(0.01)
      .position({ x: 0, y: 0 })
      .focusable(false)
      .hitTestBehavior(HitTestMode.None)
  }
}
