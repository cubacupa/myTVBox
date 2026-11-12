/**
 * 影片数据模型
 * vod_id / vod_name / vod_pic 等字段名沿用苹果CMS V10 返回结构，直接映射，省去转换。
 */

// 列表项（首页/分类/搜索结果里的一张卡片）
export interface VodItem {
  vod_id: string | number;
  vod_name: string;
  vod_pic: string;
  vod_remarks?: string;   // 例如 "更新至12集" / "HD"
  type_name?: string;     // 分类名，如 "电影" "电视剧"
  vod_year?: string;
  site_key?: string;      // 聚合搜索时标记来源站点
  // 苹果CMS 接口本来就会带这两个字段（ac=videolist 也有，共 85 个字段），
  // 之前没声明导致被丢弃。豆瓣 ID 覆盖率约 88%，评分覆盖率约 23%（新片未开分）。
  vod_douban_id?: string | number;
  vod_douban_score?: string | number;
}

// 详情（含简介与播放地址）
export interface VodDetail {
  vod_id: string | number;
  vod_name: string;
  vod_pic: string;
  vod_remarks?: string;
  type_name?: string;
  vod_year?: string;
  vod_content?: string;     // 简介
  vod_play_from?: string;   // 播放线路分组，如 "线路A$$$线路B"
  vod_play_url?: string;    // 分集地址，如 "第1集$xxx#第2集$yyy"
  episodes?: VodEpisode[];  // 解析后的集数列表（默认取第一条线路）
  // 详情接口同样会带豆瓣字段，补上用于海报/评分刮削
  vod_douban_id?: string | number;
  vod_douban_score?: string | number;
}

// 单集
export interface VodEpisode {
  name: string;   // "第1集" / 分辨率名
  url: string;    // 直链（m3u8 / mp4）
}

// 分类
export interface VodClass {
  type_id: string;
  type_name: string;
  /**
   * 父分类 id（苹果CMS 的 type_pid）。
   * 0 / 缺省 = 顶级分类；非 0 表示挂在某个顶级下面。
   * 站点给的是数字，声明成联合类型，比较前统一 toString 归一化。
   */
  type_pid?: string | number;
}
