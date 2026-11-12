import { LiveApi, LiveGroup } from './LiveApi';
import { LiveCfg } from '../model/TvBoxModels';

/**
 * 直播源探活：判断一份 lives 到底能不能解析出频道。
 *
 * 同一份配置里的多个 lives 经常只有一两个真能用：其余的可能 302 空响应、
 * 上游域名解析失败，或者干脆解析出 0 个频道。列表里照样挂着按钮，
 * 点过去一片空白，用户只会以为「直播坏了」。所以进直播页先探一遍，空的直接不上屏。
 *
 * 失败结果只记在内存里（本次运行有效）：源站要是恢复了，重启 App 就能重新出现，
 * 不用维护 TTL；成功的故意不缓存，避免频道表过期后一直放旧数据。
 */
export class LiveSrcProbe {
  /** url → 失败原因；同一个地址这次运行内不再重试 */
  private static bad: Map<string, string> = new Map();
  /** 最近一次失败原因（取第一行，给页面提示用） */
  private static last: string = '';

  /** 用户主动点「重试」时清掉，让失败的源再测一次 */
  static reset(): void {
    LiveSrcProbe.bad.clear();
    LiveSrcProbe.last = '';
  }

  static isBad(url: string): boolean {
    return LiveSrcProbe.bad.has(url);
  }

  static badReason(url: string): string {
    const w = LiveSrcProbe.bad.get(url);
    return w === undefined ? '' : w;
  }

  static lastReason(): string {
    return LiveSrcProbe.last;
  }

  /** 已探过且不可用的源有几个（用于页面提示「已隐藏 N 个空源」） */
  static badCount(): number {
    return LiveSrcProbe.bad.size;
  }

  /**
   * 加载一份直播源。能解析出频道就返回分组，否则返回 null（并记入失败表）。
   * 不抛异常：调用方按 null 处理，避免一个死源把整页拖进错误态。
   */
  static async load(live: LiveCfg): Promise<LiveGroup[] | null> {
    const url: string = (live === null || live === undefined) ? '' : (live.url ?? '').trim();
    if (url.length === 0) {
      LiveSrcProbe.last = '直播源没有地址';
      return null;
    }
    if (LiveSrcProbe.bad.has(url)) {
      return null;
    }
    try {
      const gs: LiveGroup[] = await LiveApi.load(live);
      if (gs.length === 0) {
        LiveSrcProbe.bad.set(url, '没解析到频道');
        LiveSrcProbe.last = '没解析到频道';
        return null;
      }
      return gs;
    } catch (e) {
      const msg: string = LiveSrcProbe.firstLine((e as Error).message);
      LiveSrcProbe.bad.set(url, msg);
      LiveSrcProbe.last = msg;
      return null;
    }
  }

  /** HttpUtil 的错误带多行（实际请求 / 服务器返回），提示行只留第一行 */
  private static firstLine(msg: string): string {
    const s: string = (msg ?? '').trim();
    const i: number = s.indexOf('\n');
    const one: string = i > 0 ? s.substring(0, i) : s;
    return one.length > 60 ? one.substring(0, 60) + '…' : one;
  }
}
