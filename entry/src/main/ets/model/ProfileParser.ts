export interface ExternalReference {
  line: number;
  directive: string;
  path: string;
  suffix: string;
}

export interface InspectedProfile {
  content: string;
  references: ExternalReference[];
}

const FILE_DIRECTIVES = ['ca', 'cert', 'key', 'tls-auth', 'tls-crypt', 'tls-crypt-v2', 'extra-certs'];
const REJECTED = ['dev-node', 'dev-type', 'secret', 'pkcs12', 'pkcs11-providers', 'plugin', 'up', 'down',
  'route-up', 'route-pre-down', 'ipchange', 'script-security', 'management', 'management-client', 'log',
  'log-append', 'status', 'writepid', 'daemon', 'cd', 'chroot', 'user', 'group', 'mktun', 'rmtun',
  'block-ipv4', 'block-ipv6', 'block-outside-dns', 'register-dns', 'http-proxy', 'socks-proxy', 'static-challenge',
  'dhcp-renew', 'ignore-unknown-option'];

export function splitOption(line: string): string[] {
  const tokens: string[] = [];
  let token = '';
  let quote = '';
  let escaped = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (escaped) { token += c; escaped = false; continue; }
    if (c === '\\') { escaped = true; continue; }
    if (quote.length > 0) {
      if (c === quote) quote = ''; else token += c;
    } else if (c === '"' || c === "'") quote = c;
    else if ((c === '#' || c === ';') && token.length === 0) break;
    else if (/\s/.test(c)) {
      if (token.length > 0) { tokens.push(token); token = ''; }
    } else token += c;
  }
  if (quote.length > 0 || escaped) throw new Error('配置中存在未闭合的引号或转义。');
  if (token.length > 0) tokens.push(token);
  return tokens;
}

export function inspectProfile(input: string): InspectedProfile {
  const text = input.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
  if (text.length === 0 || text.length > 1024 * 1024 || text.indexOf('\0') >= 0)
    throw new Error('请选择不超过 1 MiB 的 UTF-8 .ovpn 文本文件。');
  const lines = text.split('\n');
  const references: ExternalReference[] = [];
  let inlineTag = '';
  let hasRemote = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (inlineTag.length > 0) {
      if (line === `</${inlineTag}>`) inlineTag = '';
      continue;
    }
    if (line.startsWith('<') && !line.startsWith('</')) {
      const tag = line.substring(1, line.length - 1);
      if (tag === 'connection') continue;
      if (FILE_DIRECTIVES.indexOf(tag) < 0) throw new Error(`第 ${i + 1} 行：暂不支持此内嵌配置块。`);
      inlineTag = tag;
      continue;
    }
    if (line === '</connection>') continue;
    const args = splitOption(line);
    if (args.length === 0) continue;
    const directive = args[0].replace(/^--/, '');
    if (REJECTED.indexOf(directive) >= 0)
      throw new Error(`第 ${i + 1} 行：当前不支持 ${directive}，未忽略该指令。`);
    if (directive === 'setenv' && args[1] === 'opt')
      throw new Error(`第 ${i + 1} 行：请明确处理 setenv opt 指令，不能自动忽略其内容。`);
    if (directive === 'dev' && args[1] !== 'tun') throw new Error('仅支持 dev tun，暂不支持 TAP。');
    if (directive === 'remote') hasRemote = true;
    if (directive === 'auth-user-pass' && args.length > 1)
      throw new Error('请将 auth-user-pass 改为不带文件路径，在应用内输入用户名和密码。');
    if (directive === 'compress' && args[1] !== 'stub' && args[1] !== 'stub-v2')
      throw new Error('当前构建不启用数据压缩，仅支持 stub / stub-v2。');
    if (directive === 'comp-lzo' && args[1] !== 'no') throw new Error('当前构建不支持 LZO 压缩。');
    if (directive === 'redirect-gateway' && args.indexOf('block-local') >= 0)
      throw new Error('当前适配暂不支持 redirect-gateway block-local。');
    if (FILE_DIRECTIVES.indexOf(directive) >= 0 && args[1] !== '[inline]') {
      if (args.length < 2) throw new Error(`第 ${i + 1} 行：${directive} 缺少文件。`);
      references.push({ line: i, directive, path: args[1], suffix: args.slice(2).join(' ') });
    }
  }
  if (inlineTag.length > 0) throw new Error(`配置中的 ${inlineTag} 块未闭合。`);
  if (!hasRemote) throw new Error('配置缺少 remote 服务器地址。');
  return { content: text, references };
}

export function embedReference(content: string, reference: ExternalReference, pem: string): string {
  if (pem.length === 0 || pem.length > 512 * 1024 || pem.indexOf('\0') >= 0
    || pem.indexOf(`</${reference.directive}>`) >= 0) throw new Error('关联文件无效或过大。');
  const lines = content.split('\n');
  lines[reference.line] = `<${reference.directive}>\n${pem.trim()}\n</${reference.directive}>`
    + (reference.directive === 'tls-auth' && reference.suffix.length > 0 ? `\nkey-direction ${reference.suffix}` : '');
  return lines.join('\n');
}
