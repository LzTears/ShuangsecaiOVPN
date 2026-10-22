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
    if (fs.accessSync(path)) return;
    try { fs.mkdirSync(path, true); }
    catch (error) {
      if ((error as BusinessError).code !== 13900015) throw new Error('无法创建应用存储目录。');
    }
  }

  read(name: string): string {
    return fs.readTextSync(`${this.root}/${name}`);
  }

  exists(name: string): boolean {
    return fs.accessSync(`${this.root}/${name}`);
  }

  write(name: string, content: string): void {
    const path = `${this.root}/${name}`;
    const temp = `${path}.${util.generateRandomUUID(true)}.tmp`;
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
    } finally { fs.closeSync(file); }
    fs.renameSync(temp, path);
  }

  remove(name: string): void {
    if (this.exists(name)) fs.unlinkSync(`${this.root}/${name}`);
  }

  list(directory: string): string[] {
    return fs.listFileSync(`${this.root}/${directory}`);
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
