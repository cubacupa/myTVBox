import { VodEpisode } from './VodItem';

/**
 * TVBox / 影视仓 配置模型
 * 对应配置地址返回的 JSON：sites（资源站）/ parses（解析）/ lives（直播）/ urls（多仓）
 * 应用只做协议解析与展示，不内置任何内容源。
 */

// 资源站
export class SiteCfg {
  key: string = '';
  name: string = '';
  type: number = 1;
  api: string = '';
  ext: string = '';
  searchable: boolean = true;
  quickSearch: boolean = true;
  filterable: boolean = false;
  jar: string = '';
  playerType: number = 0;
}

// 解析接口（给需要二次跳转的平台用）
export class ParseCfg {
  name: string = '';
  type: number = 1;
  url: string = '';
  flags: string[] = [];
}

// 直播源
export class LiveCfg {
  name: string = '';
  type: number = 0;   // 0 = txt 频道列表，1 = m3u
  url: string = '';
  epg: string = '';
  logo: string = '';
  playerType: number = 0;
}

// 多仓里的一个仓库
export class RepoCfg {
  name: string = '';
  url: string = '';
}

// 扫描一个仓库后的结果（多仓里哪个仓库真能用）
export class RepoScanResult {
  name: string = '';
  url: string = '';
  ok: boolean = false;        // 拉到配置且有可用站点
  sites: number = 0;
  usable: number = 0;
  lives: number = 0;
  isRepo: boolean = false;    // 仓库里套仓库
  msg: string = '';
}

// 一整份配置
export class TvBoxConfig {
  sites: SiteCfg[] = [];
  parses: ParseCfg[] = [];
  lives: LiveCfg[] = [];
  flags: string[] = [];
  wallpaper: string = '';
  spider: string = '';
  repos: RepoCfg[] = [];
  isRepo: boolean = false;   // true 表示这是一个"多仓"接口，里面是仓库列表
  raw: string = '';
}

// 详情页的一条播放线路（对应 vod_play_from 里的一个分组）
export class PlayLine {
  name: string = '';
  episodes: VodEpisode[] = [];
}
