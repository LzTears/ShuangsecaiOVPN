import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

export class PrivateFiles {
  readonly root: string;

  constructor(context: common.Context) {
    this.root = `${context.filesDir}/ovpn`;
    this.ensureDirectory(this.root);
    this.ensureDirectory(`${this.root}/profiles`);
    this.ensureDirectory(`${this.root}/commands`);
    this.ensureDirectory(`${this.root}/replies`);
  }

  private ensureDirectory(path: string): void {
    try {
      if (fs.accessSync(path)) return;
      fs.mkdirSync(path, true);
    }
    catch (error) {
      if ((error as BusinessError).code !== 13900015) throw new Error('无法创建应用存储目录。');
    }
  }

  read(name: string): string {
    try { return fs.readTextSync(`${this.root}/${name}`); }
    catch (_) { throw new Error('读取本机数据失败，请检查存储空间后重新打开应用。'); }
  }

  exists(name: string): boolean {
    try { return fs.accessSync(`${this.root}/${name}`); }
    catch (error) {
      if ((error as BusinessError).code === 13900002) return false;
      throw new Error('无法访问应用存储，请重新打开应用后重试。');
    }
  }

  write(name: string, content: string): void {
    const path = `${this.root}/${name}`;
    const temp = `${path}.${util.generateRandomUUID(true)}.tmp`;
    try {
      const file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const data = new util.TextEncoder().encodeInto(content);
        let offset = 0;
        while (offset < data.length) {
          const part = data.slice(offset);
          const count = fs.writeSync(file.fd, part.buffer);
          if (count <= 0) throw new Error('本机存储空间不足，保存未完成。');
          offset += count;
        }
        fs.fsyncSync(file.fd);
      } finally {
        try { fs.closeSync(file); }
        catch (_) { throw new Error('关闭本机数据文件失败。'); }
      }
      fs.renameSync(temp, path);
    } catch (_) {
      try { if (fs.accessSync(temp)) fs.unlinkSync(temp); }
      catch (_) { console.warn('Temporary storage file cleanup failed.'); }
      throw new Error('保存本机数据失败，请检查存储空间后重试。');
    }
  }

  remove(name: string): void {
    try { if (this.exists(name)) fs.unlinkSync(`${this.root}/${name}`); }
    catch (error) {
      if ((error as BusinessError).code !== 13900002) throw new Error('删除本机数据失败，请重试。');
    }
  }

  list(directory: string): string[] {
    try { return fs.listFileSync(`${this.root}/${directory}`); }
    catch (_) { throw new Error('读取应用数据目录失败，请重新打开应用。'); }
  }

  claimCommand(name: string): boolean {
    try {
      fs.renameSync(`${this.root}/commands/${name}.json`, `${this.root}/commands/${name}.processing`);
      return true;
    } catch (error) {
      if ((error as BusinessError).code === 13900002) return false;
      throw new Error('无法读取 VPN 控制请求。');
    }
  }
}
