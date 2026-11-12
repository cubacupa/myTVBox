import { router } from '@kit.ArkUI';
import { AppState } from '../utils/AppState';
import { SiteApi } from '../utils/SiteApi';
import { VodItem } from '../model/VodItem';
import { PosterCard } from '../components/PosterCard';
import { RatingStore } from '../utils/RatingStore';

/**
 * 搜索页：当前站点搜索，或聚合当前配置里所有可用站点（最多 8 个，避免长时间等待）。
 */
@Entry
@Component
struct SearchPage {
  @State wd: string = '';
  @State items: VodItem[] = [];
  @State loading: boolean = false;
  @State msg: string = '';
  @State agg: boolean = false;
  @State siteName: string = '';

  aboutToAppear(): void {
    const site = AppState.currentSite;
    if (site !== null) {
      this.siteName = site.name;
    }
  }

  private async doSearch(): Promise<void> {
    const w = this.wd.trim();
    if (!w) {
      this.msg = '请输入关键词';
      return;
    }
    this.loading = true;
    this.msg = '';
    this.items = [];
    try {
      if (this.agg) {
        const sites = AppState.usableSites();
        const limit = sites.length > 8 ? 8 : sites.length;
        for (let i = 0; i < limit; i++) {
          try {
            const r = await SiteApi.search(sites[i], w, 1);
            for (const it of r.items) {
              it.site_key = sites[i].key;
            }
            this.items = this.items.concat(r.items);
          } catch (e) {
            // 单个站点失败不影响聚合
          }
        }
      } else {
        const site = AppState.currentSite;
        if (site === null) {
          this.msg = '没有可用的资源站';
          this.loading = false;
          return;
        }
        const r = await SiteApi.search(site, w, 1);
        for (const it of r.items) {
          it.site_key = site.key;
        }
        this.items = r.items;
      }
      if (this.items.length === 0) {
        this.msg = '没有搜到结果，换个关键词或站点试试';
      } else {
        // 搜索结果同样参与评分补齐与海报刮削
        RatingStore.warm(this.items);
      }
    } catch (e) {
      this.msg = '搜索失败：' + (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private goDetail(item: VodItem): void {
    const site = AppState.currentSite;
    let key = item.site_key ? item.site_key : '';
    if (!key && site !== null) {
      key = site.key;
    }
    router.pushUrl({
      url: 'pages/Detail',
      params: { key: key, vodId: String(item.vod_id) }
    });
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(15).height(40)
          .onClick(() => { router.back(); })
        TextInput({ text: this.wd, placeholder: '输入片名，OK 键搜索' })
          .layoutWeight(1)
          .height(48)
          .fontSize(16)
          .fontColor('#ffffff')
          .placeholderColor('#777777')
          .backgroundColor('#242424')
          .borderRadius(8)
          .margin({ left: 16 })
          .onChange((v: string) => { this.wd = v; })
          .onSubmit(() => { this.doSearch(); })
        Button('搜索')
          .height(48)
          .margin({ left: 12 })
          .backgroundColor('#FF6B00')
          .fontColor('#ffffff')
          .onClick(() => { this.doSearch(); })
        Text(this.agg ? '聚合：开' : '聚合：关')
          .fontSize(14)
          .fontColor(this.agg ? '#FF6B00' : '#999999')
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor('#2a2a2a')
          .borderRadius(8)
          .margin({ left: 12 })
          .focusable(true)
          .onClick(() => { this.agg = !this.agg; })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 16, bottom: 8 })

      Text('搜索范围：' + (this.agg ? '当前配置全部可用站点' : this.siteName))
        .fontSize(13).fontColor('#888888').width('100%').padding({ left: 28 })

      if (this.msg) {
        Text(this.msg).fontSize(15).fontColor('#ff9f9f').width('100%').padding({ left: 28, top: 10 })
      }
      if (this.loading) {
        Column() {
          LoadingProgress().width(44).height(44)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.items, (item: VodItem) => {
            GridItem() {
              PosterCard({ item: item, onSelect: () => this.goDetail(item) })
            }
          }, (item: VodItem) => String(item.site_key ? item.site_key : '') + '_' + String(item.vod_id))
        }
        .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr')
        .columnsGap(14)
        .rowsGap(18)
        .padding({ left: 28, right: 28, top: 12, bottom: 20 })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#161616')
  }
}
