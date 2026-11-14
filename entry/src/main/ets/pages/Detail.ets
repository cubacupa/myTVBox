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
  /** 旧版首页传的是 siteKey，两个都认，免得换页面进来站点丢了 */
  siteKey?: string;
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
  /** 豆瓣元信息：类型标签 / 片长 / 地区。拿不到就用采集站的分类名兜底 */
  @State mGenre: string[] = [];
  @State mDuration: string[] = [];
  @State mCountry: string[] = [];
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
  /** 评分后台补齐信号：读它可让角标重绘 */
  @StorageProp('ratingTick') ratingTick: number = 0;
  /** 遥控器焦点标记（现代版自绘焦点，不用系统默认描边） */
  @State focusId: string = '';
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
    this.siteKey = p.key !== undefined && p.key.length > 0 ? p.key
      : (p.siteKey === undefined ? '' : p.siteKey);
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
      // 豆瓣类型 / 片长：本地缓存有就立刻出来，没有就补一次（详情页只有一部片，等得起）
      if (this.doubanId.length > 0) {
        const cached = RatingStore.metaCached(this.doubanId);
        if (cached !== null) {
          this.mGenre = cached.genres;
          this.mDuration = cached.durations;
          this.mCountry = cached.countries;
        } else {
          RatingStore.ensureMeta(this.doubanId).then((m) => {
            if (m !== null) {
              this.mGenre = m.genres;
              this.mDuration = m.durations;
              this.mCountry = m.countries;
            }
          }).catch(() => {});
        }
      }
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
      setTimeout(() => { this.getUIContext().getFocusController().requestFocus('detail-play'); }, 300);
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

  // ---------------- 现代版视觉（数据与交互沿用上面的方法） ----------------

  /** 顶部标签：优先豆瓣类型（悬疑 / 犯罪 / 剧情），没有才退回采集站的分类名 */
  private tags(): string[] {
    if (this.mGenre.length > 0) {
      return this.mGenre;
    }
    if (this.typeName.length > 0) {
      return [this.typeName];
    }
    return [];
  }

  /** 片长：豆瓣原样给「120分钟」；多集剧加个 /集，免得误以为是整部时长 */
  private durText(): string {
    if (this.mDuration.length === 0) {
      return '';
    }
    const d: string = this.mDuration[0];
    return this.eps().length > 1 ? d + '/集' : d;
  }

  /**
   * 元信息行：年份 · 地区 · 片长 · 更新状态 · 资源站。
   * 分类名不放在这里 —— 它已经在上面那排标签里了，重复一遍纯属占地方。
   */
  private metaLine(): string {
    const parts: string[] = [];
    if (this.year.length > 0) {
      parts.push(this.year);
    }
    if (this.mCountry.length > 0) {
      parts.push(this.mCountry[0]);
    }
    if (this.durText().length > 0) {
      parts.push(this.durText());
    }
    if (this.remarks.length > 0) {
      parts.push(this.remarks);
    }
    if (this.lines.length > 0) {
      parts.push(this.siteLabel());
    }
    return parts.join(' · ');
  }

  /** 豆瓣评分：站点自带或后台刮削来的缓存；没有就返回空串，那一整段不画 */
  private scoreText(): string {
    if (this.ratingTick < 0) {
      return '';
    }
    return RatingStore.label(this.asItem());
  }

  /** 资源站名（当前站点） */
  private siteLabel(): string {
    const site = AppState.findSite(this.siteKey);
    if (site !== null && site.name.length > 0) {
      return site.name;
    }
    const cur = AppState.currentSite;
    return cur !== null ? cur.name : '—';
  }

  /** 详情页可用的海报：优先豆瓣刮削图（本地），否则站点图 */
  private heroPicUrl(): string {
    return this.poster.length > 0 ? this.poster : this.pic;
  }

  private playLabel(): string {
    if (this.lastEp.length > 0) {
      return '继续观看 · ' + this.lastEp;
    }
    return '播放';
  }

  private firstEp(): VodEpisode | null {
    const list: VodEpisode[] = this.eps();
    return list.length > 0 ? list[0] : null;
  }

  @Builder
  chip(text: string, accent: boolean, wide: boolean) {
    Row() {
      Text(text)
        .fontSize(13)
        .fontWeight(accent ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(accent ? '#FFB37A' : '#C9C9D4')
        .maxLines(1)
    }
    .height(30)
    .padding({ left: wide ? 16 : 13, right: wide ? 16 : 13 })
    .borderRadius(9)
    .backgroundColor(accent ? '#22FF8A3D' : '#14FFFFFF')
    .border({ width: 1, color: accent ? '#73FF8A3D' : '#28FFFFFF' })
    .margin({ right: 10 })
  }

  @Builder
  epCell(ep: VodEpisode, idx: number) {
    Column() {
      Text(ep.name)
        .fontSize(13)
        .fontWeight(this.lastEp === ep.name ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.lastEp === ep.name ? '#FFB37A'
          : (this.watchedEps.indexOf(ep.name) >= 0 ? '#7A7A86' : '#C9C9D4'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .height(60)
    .justifyContent(FlexAlign.Center)
    .borderRadius(14)
    .backgroundColor(this.lastEp === ep.name ? '#22FF8A3D' : '#10FFFFFF')
    .border({
      width: this.lastEp === ep.name ? 1.5 : 1,
      color: this.lastEp === ep.name ? '#8CFF8A3D' : '#1AFFFFFF'
    })
    .focusable(true)
    .onFocus(() => { this.focusId = 'ep-' + idx; })
    .onBlur(() => { this.focusId = ''; })
    .border({
      width: this.focusId === ('ep-' + idx) ? 2 : (this.lastEp === ep.name ? 1.5 : 1),
      color: this.focusId === ('ep-' + idx) ? '#FFD9BC'
        : (this.lastEp === ep.name ? '#8CFF8A3D' : '#1AFFFFFF')
    })
    .onClick(() => { this.play(ep); })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 背景：海报模糊铺底 + 压暗 ----
      if (this.heroPicUrl().length > 0) {
        Image(this.heroPicUrl())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(70)
          .opacity(0.44)
      }
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 155,
          colors: [['#B308090B', 0.0], ['#D908090B', 0.5], ['#08090B', 0.88]]
        })

      if (this.loading) {
        Column() {
          LoadingProgress().width(48).height(48)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.err.length > 0 && this.lines.length === 0) {
        Column({ space: 20 }) {
          Text(this.err)
            .fontSize(16)
            .fontColor('#FF8B7A')
          Row() {
            Text('返回')
              .fontSize(16)
              .fontColor('#EDEDF2')
          }
          .height(52)
          .padding({ left: 30, right: 30 })
          .borderRadius(26)
          .backgroundColor('#16FFFFFF')
          .focusable(true)
          .onClick(() => { router.back(); })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Column() {
          // ---- 顶栏：只留返回。片名下面 58 号大字已经有一份，这里再写一遍是废信息 ----
          Row({ space: 18 }) {
            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(17)
                .fontColor(['#EDEDF2'])
                .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              Text('返回')
                .fontSize(15)
                .fontColor('#EDEDF2')
            }
            .height(48)
            .padding({ left: 22, right: 26 })
            .borderRadius(24)
            .backgroundColor('#16FFFFFF')
            .border({ width: 1, color: this.focusId === 'back' ? '#FFD9BC' : '#24FFFFFF' })
            .focusable(true)
            .onFocus(() => { this.focusId = 'back'; })
            .onBlur(() => { this.focusId = ''; })
            .onClick(() => { router.back(); })

            Blank()
          }
          .width('100%')
          .height(48)
          .margin({ top: 28 })

          // ---- 主体：海报 + 信息 ----
          Row() {
            // 竖版海报
            Stack({ alignContent: Alignment.TopStart }) {
              Row()
                .width(268)
                .height(392)
                .borderRadius(20)
                .backgroundColor('#1A1B22')
              if (this.heroPicUrl().length > 0) {
                Image(this.heroPicUrl())
                  .width(268)
                  .height(392)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(20)
              }
              Column()
                .width(268)
                .height(130)
                .margin({ top: 262 })
                .linearGradient({
                  angle: 180,
                  colors: [['#00000000', 0.0], ['#99000000', 1.0]]
                })
            }
            .width(268)
            .height(392)
            .clip(true)
            .borderRadius(20)
            .border({ width: 1, color: '#21FFFFFF' })
            .shadow({ radius: 56, color: '#99000000', offsetX: 0, offsetY: 24 })

            // 信息列
            Column() {
              // 标签：优先豆瓣类型（悬疑 / 犯罪 / 剧情），比采集站的「欧美动漫」有信息量
              Row() {
                ForEach(this.tags(), (t: string) => {
                  this.chip(t, false, false)
                }, (t: string, i: number) => t + String(i))
              }
              .margin({ bottom: 12 })

              // 片名
              Text(this.name)
                .fontSize(50)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              // 评分 + 元信息：年份 · 地区 · 片长 · 更新状态 · 资源站
              Row({ space: 10 }) {
                if (this.scoreText().length > 0) {
                  Text('★')
                    .fontSize(14)
                    .fontColor('#FFC24B')
                  Text(this.scoreText())
                    .fontSize(17)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#FFD08A')
                  Text('·')
                    .fontSize(14)
                    .fontColor('#55555F')
                }
                Text(this.metaLine())
                  .fontSize(15)
                  .fontColor('#A5A5B0')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .margin({ top: 12, bottom: 18 })

              // 简介
              Text(this.content.length > 0 ? this.content : '暂无简介')
                .fontSize(15)
                .lineHeight(24)
                .fontColor('#9C9CA8')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              // 按钮 + 线路
              Row({ space: 14 }) {
                // 播放 / 继续观看
                Row({ space: 10 }) {
                  SymbolGlyph($r('sys.symbol.play_fill'))
                    .fontSize(17)
                    .fontColor(['#150A04'])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                  Text(this.playLabel())
                    .fontSize(18)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#150A04')
                }
                .height(60)
                .padding({ left: 32, right: 36 })
                .borderRadius(18)
                .linearGradient({
                  angle: 90,
                  colors: [['#FFA847', 0.0], ['#FF6138', 1.0]]
                })
                .shadow({ radius: 28, color: '#5CFF7833', offsetX: 0, offsetY: 12 })
                .id('detail-play')
                .focusable(true)
                .defaultFocus(true)
                .onFocus(() => { this.focusId = 'play'; })
                .onBlur(() => { this.focusId = ''; })
                .scale({ x: this.focusId === 'play' ? 1.04 : 1, y: this.focusId === 'play' ? 1.04 : 1 })
                .animation({ duration: 140 })
                .onClick(() => {
                  const ep: VodEpisode | null = this.firstEp();
                  if (ep !== null) {
                    this.play(ep);
                  }
                })

                // 收藏
                Row({ space: 9 }) {
                  SymbolGlyph(this.fav ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark'))
                    .fontSize(17)
                    .fontColor([this.fav ? '#FFB37A' : '#EDEDF2'])
                    .renderingStrategy(SymbolRenderingStrategy.SINGLE)
                  Text(this.fav ? '已收藏' : '收藏')
                    .fontSize(18)
                    .fontColor(this.fav ? '#FFB37A' : '#EDEDF2')
                }
                .height(60)
                .padding({ left: 28, right: 32 })
                .borderRadius(18)
                .backgroundColor('#16FFFFFF')
                .border({ width: 1, color: this.focusId === 'fav' ? '#FFD9BC' : '#2EFFFFFF' })
                .focusable(true)
                .onFocus(() => { this.focusId = 'fav'; })
                .onBlur(() => { this.focusId = ''; })
                .onClick(() => { this.toggleFav(); })

                // 线路切换
                if (this.lines.length > 1) {
                  Row({ space: 8 }) {
                    Text('线路')
                      .fontSize(13)
                      .fontColor('#7E7E8A')
                      .margin({ right: 4 })
                    ForEach(this.lines, (l: PlayLine, i: number) => {
                      Row() {
                        Text(l.name)
                          .fontSize(13)
                          .fontWeight(i === this.lineIdx ? FontWeight.Medium : FontWeight.Normal)
                          .fontColor(i === this.lineIdx ? '#FFB37A' : '#B0B0BC')
                          .maxLines(1)
                      }
                      .height(38)
                      .padding({ left: 15, right: 15 })
                      .borderRadius(10)
                      .backgroundColor(i === this.lineIdx ? '#22FF8A3D' : '#10FFFFFF')
                      .border({
                        width: 1,
                        color: this.focusId === ('ln-' + i) ? '#FFD9BC'
                          : (i === this.lineIdx ? '#8CFF8A3D' : '#1AFFFFFF')
                      })
                      .focusable(true)
                      .onFocus(() => { this.focusId = 'ln-' + i; })
                      .onBlur(() => { this.focusId = ''; })
                      .onClick(() => { this.lineIdx = i; })
                    }, (l: PlayLine, i: number) => l.name + String(i))
                  }
                }
              }
              .margin({ top: 20 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 48 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: 16 })

          // ---- 选集 ----
          Column() {
            Row() {
              Text('选集')
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Text(this.eps().length > 0
                ? '　共 ' + this.eps().length.toString() + ' 集' +
                  (this.lastEp.length > 0 ? ' · 上次看到 ' + this.lastEp : '')
                : '')
                .fontSize(13)
                .fontColor('#8E8E9A')
              Blank()
            }
            .width('100%')
            .margin({ bottom: 14 })

            if (this.eps().length === 0) {
              Text('这个片源没有返回播放地址')
                .fontSize(14)
                .fontColor('#8E8E9A')
            } else {
              Grid() {
                ForEach(this.eps(), (ep: VodEpisode, idx: number) => {
                  GridItem() {
                    this.epCell(ep, idx)
                  }
                }, (ep: VodEpisode, idx: number) => ep.name + String(idx)
                  + (this.lastEp === ep.name ? 'L' : (this.watchedEps.indexOf(ep.name) >= 0 ? 'W' : '')))
              }
              .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
              .columnsGap(12)
              .rowsGap(12)
              // 148 = 两行 60 + 行距 12 × 2 + 一点余量：整块落在 720 内，不再被屏幕底边切
              .height(148)
              .width('100%')
              .scrollBar(BarState.Off)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 22 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 88, right: 88 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#08090B')
  }
}

