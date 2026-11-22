/**
 * 把播放器抛出来的底层错误归成一个结论。
 * 原始报错与地址只写日志，不上屏：电视上那行长串既看不清也没法操作。
 */
export class PlayErrorText {
  static classify(msg: string, code: string): string {
    const s: string = (msg ?? '').toLowerCase();
    // 看门狗的文案里带「失效」，要先于 404 判断，否则会被说成地址过期
    if (s.includes('没有画面') || s.includes('12 秒')) {
      return '这条线路一直没出画面';
    }
    if (s.includes('表面') || s.includes('surface')) {
      return '画面初始化失败';
    }
    if (s.includes('证书') || s.includes('certificate') || s.includes('ssl') || s.includes('tls')) {
      return '片源证书校验失败';
    }
    if (code === '401' || code === '403' || s.includes('forbidden') || s.includes('拒绝') || s.includes('授权')) {
      return '片源拒绝访问';
    }
    if (code === '404' || code === '410' || s.includes('not found') || s.includes('地址失效')) {
      return '视频地址已失效';
    }
    if (s.includes('timeout') || s.includes('timed out') || s.includes('超时')) {
      return '连接片源超时';
    }
    if (s.includes('dns') || s.includes('host') || s.includes('name resolution') || s.includes('主机') || s.includes('无法解析')) {
      return '域名解析失败';
    }
    if (s.includes('格式') || s.includes('format') || s.includes('codec') || s.includes('不支持') || s.includes('container')) {
      return '这个片源的格式暂时播不了';
    }
    if (s.includes('network') || s.includes('connect') || s.includes('连接') || s.includes('io error') || s.includes('无法开始播放')) {
      return '连不上片源';
    }
    return '暂时无法播放';
  }
}
