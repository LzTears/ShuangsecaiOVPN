export type VpnState = 'DISCONNECTED' | 'CONNECTING' | 'CONNECTED' | 'DISCONNECTING' | 'FAILED';

export interface Profile {
  id: string;
  name: string;
  protocol: string;
  requiresAuth: boolean;
  requiresKeyPassword: boolean;
  allowPasswordSave: boolean;
  lockedUsername: string;
  createdAt: number;
}

export interface ProfileIndex {
  profiles: Profile[];
  defaultId: string;
}

export interface Credentials {
  username: string;
  password: string;
  keyPassword: string;
}

export interface VpnSnapshot {
  state: VpnState;
  profileId: string;
  profileName: string;
  sessionId: string;
  startedAt: number;
  durationSeconds: number;
  downloadBytes: number;
  uploadBytes: number;
  downloadPackets: number;
  uploadPackets: number;
  downloadRate: number;
  uploadRate: number;
  updatedAt: number;
  verified: boolean;
  error: string;
}

export interface NativeSnapshot {
  state: VpnState;
  running: boolean;
  bytesIn: number;
  bytesOut: number;
  packetsIn: number;
  packetsOut: number;
  error: string;
}

export interface CoreEvaluation {
  error: boolean;
  externalPki: boolean;
  requiresAuth: boolean;
  requiresKeyPassword: boolean;
  allowPasswordSave: boolean;
  staticChallenge: boolean;
  lockedUsername: string;
  protocol: string;
}

export interface NetworkAddress {
  address: string;
  prefix: number;
  ipv6: boolean;
}

export interface CoreMessage {
  type: string;
  requestId: number;
  fd: number;
  state: VpnState;
  error: string;
  addresses: NetworkAddress[];
  routes: NetworkAddress[];
  dns: string[];
  domains: string[];
  mtu: number;
}

export interface ControlCommand {
  id: string;
  action: string;
  profileId: string;
  createdAt: number;
}

export interface ControlReply {
  id: string;
  error: string;
  snapshot: VpnSnapshot;
}

export function emptySnapshot(): VpnSnapshot {
  return {
    state: 'DISCONNECTED', profileId: '', profileName: '', sessionId: '', startedAt: 0,
    durationSeconds: 0, downloadBytes: 0, uploadBytes: 0, downloadPackets: 0, uploadPackets: 0,
    downloadRate: 0, uploadRate: 0, updatedAt: 0, verified: false, error: ''
  };
}

export function isBusy(state: VpnState): boolean {
  return state === 'CONNECTING' || state === 'DISCONNECTING';
}

export function stateLabel(state: VpnState): string {
  switch (state) {
    case 'CONNECTED': return '已连接';
    case 'CONNECTING': return '连接中';
    case 'DISCONNECTING': return '断开中';
    case 'FAILED': return '连接失败';
    default: return '未连接';
  }
}

export function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value < 0) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let n = value;
  let unit = 0;
  while (n >= 1024 && unit < units.length - 1) { n /= 1024; unit++; }
  return `${unit === 0 ? Math.floor(n) : n.toFixed(1)} ${units[unit]}`;
}

export function formatDuration(seconds: number): string {
  const value = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  return `${Math.floor(value / 3600).toString().padStart(2, '0')}:${Math.floor(value / 60 % 60).toString().padStart(2, '0')}:${(value % 60).toString().padStart(2, '0')}`;
}

export function coreError(code: string): string {
  switch (code) {
    case 'AUTH_FAILED': return '服务器认证失败，请检查用户名、密码或证书。';
    case 'CONNECTION_TIMEOUT': return '连接超时，请检查网络和服务器地址。';
    case 'RESOLVE_ERROR': return '无法解析服务器地址，请检查网络和 DNS。';
    case 'CERT_VERIFY_FAIL': case 'TLS_ERROR': return '服务器证书或 TLS 握手失败，未关闭证书验证。';
    case 'PROFILE_UNSUPPORTED': return '配置校验失败，或需要暂不支持的外部 PKI / 挑战认证。';
    case 'CREDENTIALS_INVALID': return '认证信息不完整，请在应用内重新输入。';
    case 'EXCLUDE_ROUTE_UNSUPPORTED': return '当前适配暂不支持排除路由，请检查 route / redirect-gateway 配置。';
    case 'ROUTE_METRIC_UNSUPPORTED': return '当前系统适配无法表达配置要求的路由优先级。';
    case 'MTU_UNSUPPORTED': return '服务端协商的 MTU 超出系统允许的 576–1500 范围。';
    case 'DNS_OPTIONS_UNSUPPORTED': return '当前系统适配不支持此配置要求的分域、加密或自定义端口 DNS。';
    case 'BLOCK_FAMILY_UNSUPPORTED': return '此配置要求的 IP 协议族阻断尚未完成系统适配。';
    case 'SYSTEM_VPN_ERROR': return '系统 VPN 接口调用失败，请检查系统授权和当前 VPN 状态。';
    case 'CORE_ERROR': return 'OpenVPN 核心运行异常，连接已结束。';
    case '': return '';
    default: return 'VPN 连接未能保持，请检查服务器、网络和配置后重试。';
  }
}
