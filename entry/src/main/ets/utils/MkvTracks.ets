import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/**
 * MKV / WebM 头部的轨道清单。
 *
 * 为什么自己解析：AVPlayer 的 getTrackDescription() 能给出有几条字幕轨，
 * 但 language 和 track_name 对 MKV 全是空的（实测 6 条 S_TEXT/UTF8 全返回
 * name="subtitle"、lang=""），菜单里只能显示「字幕 1..6」，用户没法选。
 * MKV 的 Tracks 元素里其实写得很清楚：
 *   TrackNumber 4 / Name "Simplified" / Language "und"
 *   TrackNumber 5 / Name "Hong Kong"  / Language "chi"
 * 所以读文件头一小段自己把名字和语言挖出来。
 *
 * 只解析 EBML 头，不碰帧数据：遇到第一个 Cluster 就停。
 */
export interface MkvTrack {
  /** MKV 里的 TrackNumber（1 起） */
  num: number;
  /** 1=视频 2=音频 17=字幕 */
  type: number;
  lang: string;
  langIetf: string;
  name: string;
  codec: string;
}

const ID_SEGMENT: number = 0x18538067;
const ID_TRACKS: number = 0x1654AE6B;
const ID_TRACK_ENTRY: number = 0xAE;
const ID_CLUSTER: number = 0x1F43B675;
const ID_TRACK_NUMBER: number = 0xD7;
const ID_TRACK_TYPE: number = 0x83;
const ID_LANGUAGE: number = 0x22B59C;
const ID_LANGUAGE_IETF: number = 0x22B59D;
const ID_NAME: number = 0x536E;
const ID_CODEC: number = 0x86;

/** 读文件头多少字节：Tracks 一定在第一个 Cluster 之前，实测 4K 片也在 1MB 内 */
const HEAD_BYTES: number = 8 * 1024 * 1024;

export class MkvTracks {
  /**
   * 读取本地文件里的轨道表。不是 MKV、读不到、没有 Tracks 都返回空数组，
   * 调用方据此退回「按序号显示」，不能因此让播放流程失败。
   */
  static read(path: string): MkvTrack[] {
    let buf: ArrayBuffer | null = null;
    let fd: number = -1;
    try {
      const size: number = fs.statSync(path).size;
      const want: number = size < HEAD_BYTES ? size : HEAD_BYTES;
      if (want < 64) {
        return [];
      }
      const f: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fd = f.fd;
      buf = new ArrayBuffer(want);
      const n: number = fs.readSync(f.fd, buf, { offset: 0, length: want });
      if (n <= 0) {
        return [];
      }
    } catch (e) {
      return [];
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // 已关闭
        }
      }
    }
    if (buf === null) {
      return [];
    }
    const b: Uint8Array = new Uint8Array(buf);
    if (b.length < 4 || b[0] !== 0x1A || b[1] !== 0x45 || b[2] !== 0xDF || b[3] !== 0xA3) {
      return [];   // 不是 EBML
    }
    const out: MkvTrack[] = [];
    MkvTracks.walk(b, 0, b.length, out, false);
    return out;
  }

  /**
   * 读 EBML 变长整数。返回 [值, 字节数]，字节数 0 表示越界/非法。
   * isId 为 true 时保留长度标记位（元素 ID 的定义就是这样），否则去掉。
   */
  private static vint(b: Uint8Array, p: number, isId: boolean): number[] {
    if (p >= b.length) {
      return [0, 0];
    }
    const first: number = b[p];
    if (first === 0) {
      return [0, 0];
    }
    let len: number = 1;
    let mask: number = 0x80;
    while ((first & mask) === 0) {
      mask >>= 1;
      len++;
      if (len > 8) {
        return [0, 0];
      }
    }
    if (p + len > b.length) {
      return [0, 0];
    }
    let val: number = isId ? first : (first & (mask - 1));
    for (let i = 1; i < len; i++) {
      val = val * 256 + b[p + i];
    }
    return [val, len];
  }

  /** 遍历同一层元素。进入 Segment / Tracks 递归，遇到 Cluster 收工 */
  private static walk(b: Uint8Array, start: number, end: number, out: MkvTrack[],
    inTracks: boolean): void {
    let p: number = start;
    while (p < end) {
      const idr: number[] = MkvTracks.vint(b, p, true);
      if (idr[1] === 0) {
        return;
      }
      const szr: number[] = MkvTracks.vint(b, p + idr[1], false);
      if (szr[1] === 0) {
        return;
      }
      const id: number = idr[0];
      const size: number = szr[0];
      const body: number = p + idr[1] + szr[1];
      // 全 1 的 size 表示「未知长度」（流式写出的文件常见），此时按容器读到末尾
      const unknown: boolean = size === Math.pow(2, 7 * szr[1]) - 1;
      const stop: number = unknown ? end : (body + size < end ? body + size : end);
      if (inTracks && id === ID_TRACK_ENTRY) {
        const t: MkvTrack = MkvTracks.readEntry(b, body, stop);
        if (t.num > 0) {
          out.push(t);
        }
      } else if (id === ID_SEGMENT || id === ID_TRACKS) {
        MkvTracks.walk(b, body, stop, out, id === ID_TRACKS);
      } else if (id === ID_CLUSTER) {
        return;   // 后面全是帧数据，不需要了
      }
      if (unknown) {
        return;
      }
      p = body + size;
    }
  }

  private static readEntry(b: Uint8Array, start: number, end: number): MkvTrack {
    const t: MkvTrack = { num: 0, type: 0, lang: '', langIetf: '', name: '', codec: '' };
    let p: number = start;
    while (p < end) {
      const idr: number[] = MkvTracks.vint(b, p, true);
      if (idr[1] === 0) {
        break;
      }
      const szr: number[] = MkvTracks.vint(b, p + idr[1], false);
      if (szr[1] === 0) {
        break;
      }
      const body: number = p + idr[1] + szr[1];
      const stop: number = body + szr[0] < end ? body + szr[0] : end;
      const id: number = idr[0];
      if (id === ID_TRACK_NUMBER) {
        t.num = MkvTracks.toInt(b, body, stop);
      } else if (id === ID_TRACK_TYPE) {
        t.type = MkvTracks.toInt(b, body, stop);
      } else if (id === ID_LANGUAGE) {
        t.lang = MkvTracks.toStr(b, body, stop);
      } else if (id === ID_LANGUAGE_IETF) {
        t.langIetf = MkvTracks.toStr(b, body, stop);
      } else if (id === ID_NAME) {
        t.name = MkvTracks.toStr(b, body, stop);
      } else if (id === ID_CODEC) {
        t.codec = MkvTracks.toStr(b, body, stop);
      }
      p = stop;
    }
    return t;
  }

  private static toInt(b: Uint8Array, start: number, end: number): number {
    let v: number = 0;
    for (let i = start; i < end; i++) {
      v = v * 256 + b[i];
    }
    return v;
  }

  private static toStr(b: Uint8Array, start: number, end: number): string {
    if (end <= start) {
      return '';
    }
    const bytes: Uint8Array = b.subarray(start, end);
    try {
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return dec.decodeToString(bytes).replace('\u0000', '').trim();
    } catch (e) {
      let s: string = '';
      for (let i = start; i < end; i++) {
        s += String.fromCharCode(b[i]);
      }
      return s.trim();
    }
  }
}
