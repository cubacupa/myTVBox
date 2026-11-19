import { bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { SideNav } from '../components/SideNav';
import { AppState } from '../utils/AppState';

/**
 * 关于页：版本信息 + 数据来源 + 免责声明。
 *
 * 这些内容本来一直散在聊天记录里（谁提供片源、数据存哪、能不能商用），
 * 放到界面上反而更省事：家里人问「这东西犯不犯法」的时候，打开这一页就有答案。
 */

const C_BG: string = '#08090B';
const C_CARD: string = '#0F1015';
const C_LINE: string = '#1A1B22';
const C_ACCENT: string = '#FF8A3D';
const C_TEXT: string = '#E4E4EC';
const C_SUB: string = '#8E8E9A';
const C_DIM: string = '#6E6E7A';

/** 免责声明：一条一行，界面上不写原理，只写结论 */
const DISCLAIM: string[] = [
  '本应用是本地播放器与配置工具，不提供、不上传、不缓存任何影视或直播内容。',
  '全部片源、直播源都来自你自己填入的第三方接口，版权归原权利人，与本应用无关。',
  '第三方源是否可用、是否合规由你自行判断，使用风险自负，请勿用于商业用途或二次分发。',
  '收藏、观看记录、源地址只保存在本机，不联网上报；豆瓣评分与剧照取自豆瓣公开接口。'
];

@Entry
@Component
export struct About {
  @State ver: string = '';
  @State model: string = '';
  @State osName: string = '';
  @State api: string = '';
  /** 包名从安装信息里读，不写死：改了 bundleName 这页能自己跟上 */
  @State pkg: string = '';

  aboutToAppear(): void {
    try {
      const bi = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.ver = bi.versionName;
      this.pkg = bi.name;
    } catch (e) {
      this.ver = '';
    }
    try {
      this.model = deviceInfo.marketName.length > 0 ? deviceInfo.marketName : deviceInfo.productModel;
    } catch (e) {
      this.model = '';
    }
    try {
      this.osName = deviceInfo.osFullName;
      this.api = 'API ' + deviceInfo.sdkApiVersion.toString();
    } catch (e) {
      this.osName = '';
    }
  }

  // ---------- UI ----------

  @Builder
  pageHeader() {
    Row({ space: 12 }) {
      Text('关于')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Text(this.ver.length > 0 ? 'v' + this.ver : '')
        .fontSize(12.5)
        .fontColor('#FFB37A')
        .padding({ left: 9, right: 9, top: 3, bottom: 3 })
        .borderRadius(7)
        .backgroundColor('#1FFF8A3D')
      Text('版本信息与免责声明')
        .fontSize(12.5)
        .fontColor('#7E7E8A')
    }
    .height(56)
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 44, right: 36 })
    .margin({ top: 20 })
  }

  /** 品牌块 + 一句话介绍 */
  @Builder
  hero() {
    Row({ space: 20 }) {
      Image($r('app.media.foreground'))
        .width(96)
        .height(96)
        .objectFit(ImageFit.Contain)

      Column({ space: 8 }) {
        Text('影视盒')
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text('电视端的点播 + 直播聚合壳：自己配源，自己看片')
          .fontSize(13.5)
          .fontColor(C_SUB)
        Text('作者：cubacupa（库巴）')
          .fontSize(11.5)
          .fontColor(C_DIM)
        Row({ space: 8 }) {
          Text(this.ver.length > 0 ? 'v' + this.ver : '')
            .fontSize(11.5)
            .fontColor('#FFB37A')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(8)
            .backgroundColor('#1FFF8A3D')
          Text('HarmonyOS · ArkTS')
            .fontSize(11.5)
            .fontColor(C_SUB)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(8)
            .backgroundColor('#12FFFFFF')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 26, right: 26, top: 22, bottom: 22 })
    .borderRadius(22)
    .backgroundColor(C_CARD)
    .border({ width: 1, color: C_LINE })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  infoRow(k: string, v: string) {
    Row() {
      Text(k)
        .fontSize(13)
        .fontColor(C_DIM)
        .width(88)
      Text(v.length > 0 ? v : '—')
        .fontSize(13)
        .fontColor(C_TEXT)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(32)
  }

  @Builder
  cardTitle(t: string) {
    Row({ space: 9 }) {
      Row()
        .width(3)
        .height(13)
        .borderRadius(2)
        .backgroundColor(C_ACCENT)
      Text(t)
        .fontSize(13.5)
        .fontColor('#C9C9D4')
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  /** 左：版本与环境 */
  @Builder
  envCard() {
    Column() {
      this.cardTitle('版本与环境')
      this.infoRow('版本', this.ver.length > 0 ? 'v' + this.ver : '')
      this.infoRow('包名', this.pkg.length > 0 ? this.pkg : 'com.moviebox.tv')
      this.infoRow('设备', this.model)
      this.infoRow('系统', this.osName)
      this.infoRow('运行库', this.api)
      this.infoRow('当前配置', AppState.configName.length > 0 ? AppState.configName : '未载入')
    }
    .layoutWeight(1)
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .margin({ right: 8 })
    .backgroundColor(C_CARD)
    .borderRadius(20)
    .border({ width: 1, color: C_LINE })
  }

  /** 右：数据来源与致谢 */
  @Builder
  creditCard() {
    Column() {
      this.cardTitle('数据来源')
      this.credit('豆瓣公开接口', '评分、类型、片长、剧照')
      this.credit('IPTV 公开列表', '内置直播频道表（iptv-org 整理）')
      this.credit('第三方采集站', '片名、线路、播放地址')
      this.credit('HarmonyOS ArkUI', '界面与媒体播放能力')
      Text('以上内容版权均归各自权利人所有，本应用只做展示。')
        .fontSize(12)
        .fontColor(C_DIM)
        .width('100%')
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .height('100%')
    // 与左边「版本与环境」等高：内容少，靠均分垂直间距撑满，不留一块空白
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .margin({ left: 8 })
    .backgroundColor(C_CARD)
    .borderRadius(20)
    .border({ width: 1, color: C_LINE })
  }

  @Builder
  credit(name: string, desc: string) {
    Row() {
      Text(name)
        .fontSize(13)
        .fontColor(C_TEXT)
        .width(140)
      Text(desc)
        .fontSize(12.5)
        .fontColor(C_DIM)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
  }

  /** 免责声明：整幅宽，条目式 */
  @Builder
  disclaimer() {
    Column({ space: 8 }) {
      this.cardTitle('免责声明')
      ForEach(DISCLAIM, (line: string, i: number) => {
        Row({ space: 9 }) {
          Text((i + 1).toString())
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFB37A')
            .textAlign(TextAlign.Center)
            .width(18)
            .height(18)
            .borderRadius(9)
            .backgroundColor('#1FFF8A3D')
          Text(line)
            .fontSize(12.5)
            .lineHeight(21)
            .fontColor(C_SUB)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (line: string, i: number) => 'D' + i)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .backgroundColor(C_CARD)
    .borderRadius(20)
    .border({ width: 1, color: C_LINE })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [['#1F1A1208', 0.0], ['#0C08090B', 0.45], ['#08090B', 1.0]]
        })

      Row() {
        SideNav({ active: 6 })
        Column() {
          this.pageHeader()

          Scroll() {
            Column({ space: 14 }) {
              this.hero()

              Row() {
                this.envCard()
                this.creditCard()
              }
              .width('100%')
              // 固定高度：两张卡内容一长一短，靠 height('100%') 拉齐底边
              .height(248)
              .alignItems(VerticalAlign.Top)

              this.disclaimer()
            }
            .width('100%')
            .padding({ left: 44, right: 36 })
            .margin({ top: 8 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .align(Alignment.TopStart)
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
