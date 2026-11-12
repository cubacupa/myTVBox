import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppState } from '../utils/AppState';
import { SiteApi } from '../utils/SiteApi';
import { MarkStore, VodMark } from '../utils/MarkStore';
import { PlayUrlResolver } from '../utils/PlayUrlResolver';
import { PlayLine } from '../model/TvBoxModels';
import { VodDetail, VodEpisode, VodItem } from '../model/VodItem';
import { RatingStore } from '../utils/RatingStore';
import { PosterStore } from '../utils/PosterStore';
import { PlayProgress } from '../utils/PlayProgress';

interface DetailParams {
  key: string;
  vodId: string;
}

/**
 * 详情页：海报 + 简介 + 多线路切换 + 选集 + 收藏。
 * 线路名（vod_play_from）同时也是播放时的 flag，用于匹配配置里的解析接口。
 */
@Entry
@Component
struct Detail {
  @State name: string = '';
  @State pic: string = '';
  @State remarks: string = '';
  @State typeName: string = '';
  @State year: string = '';
  @State content: string = '';
  @State lines: PlayLine[] = [];
  @State lineIdx: number = 0;
  @State loading: boolean = true;
  @State err: string = '';
  @State fav: boolean = false;
  /** 刮削到的本地海报；空则用站点图 */
  @State poster: string = '';
  /** 看过的集名（跨线路按集名合并）：按钮压暗 */
  @State watchedEps: string[] = [];
  /** 最近起播的那一集：橙字 + 橙框，也就是「上次看到」 */
  @State lastEp: string = '';
  @StorageProp('posterTick') @Watch('onPosterTick') posterTick: number = 0;
  private doubanId: string = '';
  private siteKey: string = '';
  private vodId: string = '';
  /** 本次进入详情页是否真的点过播放：从播放页返回时才回写历史，避免点开看看就把记录顶到最前 */
  private playedInThisVisit: boolean = false;

  onPosterTick(): void {
    this.syncPoster();
  }

  /** 详情字段拼成一个列表项，交给刮削器复用同一套逻辑 */
  private asItem(): VodItem {
    const it: VodItem = {
      vod_id: this.vodId,
      vod_name: this.name,
      vod_pic: this.pic,
      vod_douban_id: this.doubanId
    };
    return it;
  }

  /** 本地刮削图存在就用它，否则留空让站点图兜底 */
  private syncPoster(): void {
    this.poster = PosterStore.localOf(this.asItem());
  }

  aboutToAppear(): void {
    const p = router.getParams() as DetailParams;
    this.siteKey = p.key ?? '';
    this.vodId = p.vodId ?? '';
    this.refreshWatched();
    this.load();
  }

  /** 从播放页返回时要重读：刚看完的那一集变成「上次看到」，历史里的集名也跟着改 */
  onPageShow(): void {
    this.refreshWatched();
    if (this.playedInThisVisit) {
      this.playedInThisVisit = false;
      this.syncHistoryEp();
    }
  }

  /**
   * 从按集观看记录里挑出本片的集。
   * progId 形如 <siteKey>_<vodId>_<线路名>_<集名>，线路可能换过，
   * 所以按集名合并、取同名的最大时间戳，跨线路也算看过。
   */
  /** progId = <siteKey>_<vodId>_<线路名>_<集名>，取最后一段集名 */
  private epNameOf(progId: string, prefix: string): string {
    if (progId.indexOf(prefix) !== 0) {
      return '';
    }
    const rest: string = progId.substring(prefix.length);
    const sep: number = rest.lastIndexOf('_');
    return sep >= 0 ? rest.substring(sep + 1) : rest;
  }

  private async refreshWatched(): Promise<void> {
    if (this.siteKey.length === 0 || this.vodId.length === 0) {
      return;
    }
    const ctx = getContext(this) as common.Context;
    const all: Record<string, number> = await PlayProgress.watched(ctx);
    const oldIds: string[] = await PlayProgress.progressIds(ctx);
    const prefix: string = this.siteKey + '_' + this.vodId + '_';
    const byEp: Map<string, number> = new Map<string, number>();
    // 升级前的进度表：能证明「看过」，但没有时间，记 0
    for (const k of oldIds) {
      const nm: string = this.epNameOf(k, prefix);
      if (nm.length > 0 && !byEp.has(nm)) {
        byEp.set(nm, 0);
      }
    }
    // 新的按集记录：带时间戳，覆盖上面的 0
    for (const k of Object.keys(all)) {
      const nm: string = this.epNameOf(k, prefix);
      if (nm.length === 0) {
        continue;
      }
      const ts: number = all[k] ?? 0;
      if (ts > (byEp.get(nm) ?? 0)) {
        byEp.set(nm, ts);
      }
    }
    const eps: string[] = [];
    let latest: string = '';
    let latestTs: number = 0;
    byEp.forEach((ts: number, nm: string) => {
      eps.push(nm);
      if (ts > latestTs) {
        latestTs = ts;
        latest = nm;
      }
    });
    // 老数据连进度都没留下时，用播放历史兜出「上次看到」那一集。
    // 历史按影片去重，只有最近一条，remarks 格式是「集名 · 线路名」。
    if (latest.length === 0) {
      const his: VodMark[] = MarkStore.listHistory(ctx);
      for (const m of his) {
        if (m.siteKey === this.siteKey && m.vodId === this.vodId) {
          const dot: number = m.remarks.indexOf(' · ');
          const nm: string = dot >= 0 ? m.remarks.substring(0, dot) : m.remarks;
          if (nm.length > 0) {
            if (eps.indexOf(nm) < 0) {
              eps.push(nm);
            }
            latest = nm;
          }
          break;
        }
      }
    }
    this.watchedEps = eps;
    this.lastEp = latest;
  }

  /**
   * 把历史里「看到哪一集」改成实际最近起播的那一集。
   * 播放器用上/下集切集时只换 progId、不回写历史，所以从播放页返回时补写一次；
   * 顺便更新 time，让刚看过的片子回到历史最前。
   */
  private async syncHistoryEp(): Promise<void> {
    if (this.siteKey.length === 0 || this.vodId.length === 0) {
      return;
    }
    const ctx = getContext(this) as common.Context;
    const all: Record<string, number> = await PlayProgress.watched(ctx);
    const prefix: string = this.siteKey + '_' + this.vodId + '_';
    let latestKey: string = '';
    let latestTs: number = 0;
    for (const k of Object.keys(all)) {
      if (k.indexOf(prefix) !== 0) {
        continue;
      }
      const ts: number = all[k] ?? 0;
      if (ts > latestTs) {
        latestTs = ts;
        latestKey = k;
      }
    }
    if (latestKey.length === 0) {
      return;   // 老数据只有进度表、没有按集记录：保留点播时写的那条
    }
    const rest: string = latestKey.substring(prefix.length);
    const sep: number = rest.lastIndexOf('_');
    const epName: string = sep >= 0 ? rest.substring(sep + 1) : rest;
    const lineName: string = sep >= 0 ? rest.substring(0, sep) : '';
    if (epName.length === 0) {
      return;
    }
    MarkStore.addHistory(ctx, this.makeMark(epName + (lineName.length > 0 ? ' · ' + lineName : '')));
  }

  private async load(): Promise<void> {
    let site = AppState.findSite(this.siteKey);
    if (site === null) {
      site = AppState.currentSite;
    }
    if (site === null) {
      this.err = '没有可用的资源站';
      this.loading = false;
      return;
    }
    const ctx = getContext(this) as common.Context;
    this.fav = MarkStore.isFav(ctx, site.key, this.vodId);
    try {
      const d = await SiteApi.getDetail(site, this.vodId);
      if (d === null) {
        this.err = '没有取到影片详情';
        this.loading = false;
        return;
      }
      this.name = d.vod_name ?? '';
      this.pic = d.vod_pic ?? '';
      const did: string | number | undefined = d.vod_douban_id;
      if (typeof did === 'number') {
        this.doubanId = did > 0 ? Math.floor(did).toString() : '';
      } else if (typeof did === 'string') {
        this.doubanId = did.trim();
      } else {
        this.doubanId = '';
      }
      this.remarks = d.vod_remarks ?? '';
      this.typeName = d.type_name ?? '';
      // 升级前的历史记录没有分类名，点开一次就补上（不改时间、不重排），
      // 历史页才能精确判断它属不属于敏感词分类
      MarkStore.patchHistoryType(ctx, this.siteKey, this.vodId, this.typeName);
      this.year = d.vod_year ?? '';
      this.content = (d.vod_content ?? '').replace(/<[^>]+>/g, '');
      this.lines = SiteApi.parseLines(d);
      // 详情页也能补图：本地已有就立刻显示，没有就排进刮削队列
      this.syncPoster();
      RatingStore.warm([this.asItem()]);
      if (this.lines.length === 0) {
        this.err = '这个片源没有返回播放地址';
      } else {
        // 默认选中第一条「直链」线路：同名的非直链线路是网页播放页，
        // 需要多走一次网页嗅探，能直连就优先直连
        this.lineIdx = this.pickDefaultLine();
      }
    } catch (e) {
      this.err = '详情加载失败：' + (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private makeMark(remark: string): VodMark {
    const m: VodMark = {
      siteKey: this.siteKey,
      vodId: this.vodId,
      name: this.name,
      pic: this.pic,
      remarks: remark,
      time: Date.now(),
      typeName: this.typeName
    };
    return m;
  }

  private toggleFav(): void {
    const ctx = getContext(this) as common.Context;
    this.fav = MarkStore.toggleFav(ctx, this.makeMark(this.remarks));
  }

  private pickDefaultLine(): number {
    for (let i = 0; i < this.lines.length; i++) {
      const eps = this.lines[i].episodes;
      if (eps.length > 0 && PlayUrlResolver.isDirect(eps[0].url)) {
        return i;
      }
    }
    return 0;
  }

  private eps(): VodEpisode[] {
    if (this.lines.length === 0 || this.lineIdx >= this.lines.length) {
      return [];
    }
    return this.lines[this.lineIdx].episodes;
  }

  private play(ep: VodEpisode): void {
    if (this.lines.length === 0) {
      return;
    }
    const line = this.lines[this.lineIdx];
    const ctx = getContext(this) as common.Context;
    MarkStore.addHistory(ctx, this.makeMark(ep.name + ' · ' + line.name));
    this.playedInThisVisit = true;   // 从播放页返回时按实际起播的集再校正一次
    // 多集剧集：把整条线路的地址一起带过去，播放页控制条才能切上/下集
    const list: VodEpisode[] = this.eps();
    const urls: string[] = [];
    const names: string[] = [];
    let at: number = -1;
    for (let i = 0; i < list.length; i++) {
      urls.push(list[i].url);
      names.push(list[i].name);
      if (at < 0 && list[i].url === ep.url && list[i].name === ep.name) {
        at = i;
      }
    }
    router.pushUrl({
      url: 'pages/Player',
      params: {
        url: ep.url,
        title: this.name + ' · ' + ep.name,
        flag: line.name,
        progId: this.siteKey + '_' + this.vodId + '_' + line.name + '_' + ep.name,
        isLive: false,
        eps: urls,
        epNames: names,
        epIdx: at,
        progBase: this.siteKey + '_' + this.vodId + '_' + line.name + '_',
        nameBase: this.name
      }
    });
  }

  build() {
    Column() {
      Row() {
        Button('‹ 返回').fontSize(15).height(40)
          .onClick(() => { router.back(); })
        Text(this.name).fontSize(20).fontColor('#ffffff').margin({ left: 16 })
        Blank()
        Button(this.fav ? '★ 已收藏' : '☆ 收藏')
          .fontSize(15)
          .height(40)
          .backgroundColor(this.fav ? '#4a3315' : '#2a2a2a')
          .fontColor(this.fav ? '#FF6B00' : '#ffffff')
          .onClick(() => { this.toggleFav(); })
      }
      .width('100%')
      .height(64)
      .padding({ left: 24, right: 24 })

      if (this.loading) {
        Column() {
          LoadingProgress().width(48).height(48)
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.err && this.lines.length === 0) {
        Column() {
          Text(this.err).fontSize(16).fontColor('#ff7777')
          Button('返回').margin({ top: 20 }).onClick(() => { router.back(); })
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        Row() {
          Stack() {
            // 占位框：站点不给图 / 图 404 时显示，避免一片空白
            Column() {
              Text(this.name && this.name.length > 0 ? this.name.substring(0, 1) : '影')
                .fontSize(60)
                .fontWeight(FontWeight.Bold)
                .fontColor('#4a4a4a')
              Text('暂无海报')
                .fontSize(13)
                .fontColor('#5a5a5a')
                .margin({ top: 10 })
            }
            .width(250)
            .height(356)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .backgroundColor('#232323')
            .borderRadius(10)
            .border({ width: 1, color: '#3a3a3a' })

            if (this.pic && this.pic.length > 0) {
              Image(this.pic)
                .width(250)
                .height(356)
                .objectFit(ImageFit.Cover)
                .borderRadius(10)
                .zIndex(1)
                .onError(() => {})
            }

            // 豆瓣刮削图盖在站点图上面（同 PosterCard 的层级规则）
            if (this.poster.length > 0) {
              Image(this.poster)
                .width(250)
                .height(356)
                .objectFit(ImageFit.Cover)
                .borderRadius(10)
                .zIndex(2)
                .onError(() => { this.poster = ''; })
            }
          }
          .width(250)
          .height(356)
          .borderRadius(10)

          Column() {
            Text(this.name).fontSize(30).fontColor('#ffffff').fontWeight(FontWeight.Bold)
            Row() {
              if (this.typeName) {
                Text(this.typeName).fontSize(14).fontColor('#cccccc').margin({ right: 16 })
              }
              if (this.year) {
                Text(this.year).fontSize(14).fontColor('#cccccc').margin({ right: 16 })
              }
              if (this.remarks) {
                Text(this.remarks).fontSize(14).fontColor('#FF6B00')
              }
            }.margin({ top: 10 })

            Text(this.content)
              .fontSize(14)
              .fontColor('#aaaaaa')
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 12 })
              .width('100%')

            Row() {
              Text('线路').fontSize(14).fontColor('#888888').margin({ right: 12 })
              List({ space: 10 }) {
                ForEach(this.lines, (l: PlayLine, idx: number) => {
                  ListItem() {
                    Text(l.name)
                      .fontSize(14)
                      .fontColor(idx === this.lineIdx ? '#ffffff' : '#cccccc')
                      .backgroundColor(idx === this.lineIdx ? '#FF6B00' : '#2a2a2a')
                      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                      .borderRadius(6)
                      .focusable(true)
                      .onClick(() => { this.lineIdx = idx; })
                  }
                }, (l: PlayLine, idx: number) => l.name + String(idx))
              }
              .listDirection(Axis.Horizontal)
              .height(46)
              .layoutWeight(1)
              .scrollBar(BarState.Off)
            }
            .width('100%')
            .margin({ top: 16 })

            Text('选集').fontSize(14).fontColor('#888888').margin({ top: 10 })

            Grid() {
              ForEach(this.eps(), (ep: VodEpisode, idx: number) => {
                GridItem() {
                  Text(ep.name)
                    .fontSize(14)
                    // 上次看到 = 橙字橙框；其余看过的压暗；没看过保持原样
                    .fontColor(this.lastEp === ep.name ? '#FFB35C'
                      : (this.watchedEps.indexOf(ep.name) >= 0 ? '#6e6e6e' : '#dddddd'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .padding({ top: 10, bottom: 10 })
                    .textAlign(TextAlign.Center)
                    .backgroundColor(this.lastEp === ep.name ? '#3a2a13'
                      : (this.watchedEps.indexOf(ep.name) >= 0 ? '#1b1b1b' : '#262626'))
                    .border({
                      width: this.lastEp === ep.name ? 2 : 0,
                      color: '#FF6B00'
                    })
                    .borderRadius(6)
                    .focusable(true)
                    .onClick(() => { this.play(ep); })
                }
              }, (ep: VodEpisode, idx: number) => ep.name + String(idx)
                + (this.lastEp === ep.name ? 'L' : (this.watchedEps.indexOf(ep.name) >= 0 ? 'W' : '')))
            }
            .columnsTemplate('1fr 1fr 1fr 1fr 1fr')
            .columnsGap(10)
            .rowsGap(10)
            .layoutWeight(1)
            .width('100%')
            .margin({ top: 8 })
          }
          .layoutWeight(1)
          .height('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 26 })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 28, right: 28, bottom: 20 })
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#161616')
  }
}
