# 🛡️ 双色彩OVPN

为 HarmonyOS 打造的原生 OpenVPN 客户端：导入配置、一键连接，在应用和桌面卡片中查看连接状态与流量。

项目状态：**0.1.0 开发验证版**。不提供 VPN 服务、服务器账号或订阅；需要自行准备服务器与 `.ovpn` 配置。

📱 基于 HarmonyOS API 26，使用 ArkTS、ArkUI 与 C++，支持 `arm64-v8a` 手机和 `x86_64` 模拟器。已完成真机连接、断开和重连验证，完整网络与稳定性验收仍在进行。

## ✨ 功能特色

- 🔌 **连接控制**：一键连接与断开，支持认证弹窗；切换配置时先停止旧会话。
- 📂 **配置管理**：通过系统文件选择器或“打开方式”导入 `.ovpn`，支持默认配置置顶、重命名和删除；关联证书与密钥由用户显式选择后内嵌保存。
- 📊 **流量统计**：应用前台约每秒更新累计上下行、速率与包数，查询保持最近一次采样的速率。
- 🧩 **桌面卡片**：支持 2×2 和横向 4×2，提供默认配置开关、累计流量、更新时间、手动刷新和打开应用；连接期间约每分钟自动同步流量，连接状态变化立即同步。
- 🔐 **本机加密**：使用 AES-256-GCM 保存配置，密钥与用户选择保存的凭据交给系统 Asset 服务；不提供云同步。
- 🎨 **深浅主题**：应用、弹窗和卡片跟随系统外观，配合橙色盾形电源图标与连接动效。
- ⚙️ **原生协议核心**：OpenVPN 3、Mbed TLS 与 Asio，通过 Node-API 桥接 HarmonyOS VPN，适配 socket 保护、TUN、IPv4/IPv6、路由、DNS 与 MTU。
- 🔄 **跨进程同步**：应用、VPN 扩展和卡片通过私有沙箱命令与应答协作，公共事件仅用于唤醒。

可复现检查与尚未完成的验收见 [验证状态](docs/VALIDATION.md)。核心已编译、界面可运行，并不表示实际隧道已建立。

## 📦 下载与签名

在 [GitHub Releases](https://github.com/LzTears/ShuangsecaiOVPN/releases) 下载未签名 `.hap` 和 `SHA256SUMS.txt`。安装前由下载者使用自己的证书与匹配设备的 Profile 完成签名，仓库不提供通用签名包。当前为开发验证版，要求 HarmonyOS API 26。

Release 同时提供对应的第三方源码及许可声明；应用源码可从对应标签下载。

## 🛠️ 构建

需要 DevEco Studio、HarmonyOS API 26 SDK / Native 工具链、Git、Node.js（支持 `node --test`）、PowerShell 和 DevEco CLI。第三方依赖固定版本，初始化脚本会下载并校验对应 commit：

```powershell
git clone https://github.com/LzTears/ShuangsecaiOVPN.git
cd ShuangsecaiOVPN
./scripts/bootstrap-deps.ps1
npm test
devecocli build
devecocli check lint
```

模型、断开控制、自动刷新和 SDK 异常路径测试使用 SDK 自带 TypeScript，不需要安装 npm 依赖。SDK 位置不同时设置 `OHOS_SDK_HOME`，或通过 `OVPN_TYPESCRIPT` 指向 TypeScript 模块。断开时先等待核心正常退出；5 秒后仍未完成则停止本应用的 VPN 扩展。

默认产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`。公开工程不包含签名配置，真机安装前请在 DevEco Studio 中配置自己的签名及设备 Profile；配置签名后同时生成 `entry-default-signed.hap`。不要提交本机签名配置。

```powershell
devecocli device list
devecocli run --device <设备名>
```

签名配置、私钥、密码、真实 `.ovpn` 和证书不得提交到版本库。

本地整理时保存的 `build-profile.local.json5` 仅作为原签名配置备份，已被 Git 忽略；构建工具仍读取 `build-profile.json5`。日志、设备截图、构建产物和第三方依赖检出目录同样不提交。

依赖初始化会应用 `patches/openvpn3-mbedtls-hostname-policy.patch`。该补丁修复 Mbed TLS `0x5D80` 错误，保留 CA、`remote-cert-tls` 和 `verify-x509-name` 校验。证书握手回归可在已启动的 x86_64 模拟器上运行：

```powershell
./scripts/test-native-tls.ps1 -Device 127.0.0.1:5555
```

测试使用临时生成的可丢弃证书，在内存中交换 TLS 数据，不接触用户的 VPN 配置。

## 🚀 使用

1. 在应用配置页选择已有 `.ovpn`。配置若引用关联文件，按提示分别选择。
2. 选择配置，在连接页点击开关。按需输入服务器认证信息；是否保存密码由用户决定。
3. 完成系统 VPN 授权。首次成功连接后，才允许卡片直接请求连接默认配置；未保存必需密码时，卡片提示在应用内连接。
4. 长按桌面应用图标，选择“卡片”，左右滑动选择 2×2 或横向 4×2 后添加。VPN 连接期间，卡片约每分钟自动同步累计流量，也可点击刷新取得快照；失败时保留旧时间并显示待核实。卡片不显示秒级速度。

## 🧭 支持范围与验证边界

此前模拟器在系统 VPN 启动/授权阶段记录 `connectAbility failed 2097152`；目标真机已完成系统授权并成功建立 VPN 会话。

真机已验证实际隧道数据收发。尚未完整验证：逐项路由与 DNS、与服务端对账的统计精度、已授权后的卡片静默启动、熄屏和切网。

目前明确拒绝 TAP、静态密钥模式、PKCS#12 / 外部 PKI、交互式 MFA、脚本/插件/管理接口、代理、实际数据压缩；底层适配不能表达排除路由、正数路由优先级、分域/加密 DNS、IP 协议族阻断或超出系统范围的 MTU 时，会失败并说明原因。这些限制需要根据实际 `.ovpn` 再决定后续支持，不能声称兼容所有配置。

统计采用核心 `tun_stats` 的隧道内 IP 字节与包数，不包含 TLS/传输头开销。速率使用单调时间；重连累计与采样异常已有模型测试，真实计数口径仍需服务端实测。

## 🗂️ 源码位置

- `entry/src/main/ets/pages/Index.ets`：应用界面与用户操作。
- `entry/src/main/ets/vpn/OvpnAbility.ets`：连接生命周期与权威状态。
- `entry/src/main/cpp/ovpn_bridge.cpp`：OpenVPN 3 与系统接口桥接。
- `entry/src/main/ets/storage/`：配置导入、本机加密及存储。
- `entry/src/main/ets/service/`：跨进程控制与卡片同步。
- `entry/src/main/ets/form/`：桌面卡片。

依赖来源、固定 commit 与许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 `deps.lock.json`。

## 📄 开源许可

项目原创代码采用 [Apache License 2.0](LICENSE)，既有版权声明予以保留。OpenVPN 3、相关补丁及其他第三方组件分别遵循其自身许可证，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。分发二进制时应一并提供对应版本的第三方源码、补丁与许可声明。

`tests/fixtures/` 中的密钥和证书是明确公开的可丢弃测试数据，禁止用于真实连接。提交 Issue 或 Pull Request 前请删除真实服务器配置、账号、证书、设备标识及敏感日志；代码修改请运行上述测试和构建检查。
