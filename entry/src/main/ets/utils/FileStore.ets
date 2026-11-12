import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

/**
 * 应用私有目录下的简单文本文件读写。
 * 配置 JSON 动辄几十上百 KB，超过 Preferences 的容量限制，所以走文件。
 */
export class FileStore {
  static path(ctx: common.Context, name: string): string {
    return ctx.filesDir + '/' + name;
  }

  static readText(ctx: common.Context, name: string): string {
    const p = FileStore.path(ctx, name);
    try {
      return fs.readTextSync(p);
    } catch (e) {
      return '';
    }
  }

  static writeText(ctx: common.Context, name: string, text: string): boolean {
    const p = FileStore.path(ctx, name);
    try {
      const f = fs.openSync(p, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, text);
      fs.closeSync(f);
      return true;
    } catch (e) {
      return false;
    }
  }

  static remove(ctx: common.Context, name: string): void {
    const p = FileStore.path(ctx, name);
    try {
      fs.unlinkSync(p);
    } catch (e) {
      // 文件不存在，忽略
    }
  }

  static exists(ctx: common.Context, name: string): boolean {
    const p = FileStore.path(ctx, name);
    try {
      return fs.accessSync(p);
    } catch (e) {
      return false;
    }
  }
}
