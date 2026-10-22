# 验证状态

当前版本为 0.1.0 开发验证版，目标工具链为 HarmonyOS API 26。

## 可复现检查

```powershell
./scripts/bootstrap-deps.ps1
npm test
devecocli build
devecocli check lint
```

`npm test` 覆盖配置解析、危险指令拒绝、关联文件注入、流量计数与速率、断开控制和临时凭据清理。

Native TLS 回归需要已启动的 x86_64 HarmonyOS 模拟器及 Git 自带 OpenSSL。先构建，再运行：

```powershell
./scripts/test-native-tls.ps1 -Device <模拟器序列号>
```

脚本临时生成测试证书，覆盖可信 CA、错误 CA、错误证书名称和错误证书用途；不需要真实 VPN 配置。

## 既有运行记录与边界

开发期间已记录两种 ABI 编译、真机连接/断开/重连及实际隧道数据收发。模型测试或构建通过不能替代真机网络验收。

尚未完整验证：逐项路由与 DNS、服务端统计对账、活动连接切换、授权后的卡片静默启停、多卡片并发控制、长时间熄屏、Wi-Fi/蜂窝切换、手机重启和大字体适配。

原始设备日志、截图和签名安装包仅保存在本地，不包含在公开仓库中。

## 本次开源整理检查（2026-10-22）

- `npm test`：20 项通过，0 项失败。
- `scripts/bootstrap-deps.ps1`：三项依赖与 Mbed TLS framework 的固定版本及 OpenVPN 补丁校验通过。
- 移除本机签名配置后执行 `devecocli build`：成功生成未签名开发包；仍有既有 SDK 异常处理、系统能力等警告。
- `devecocli check lint` 及显式指定 ArkTS 目录均返回 0 问题，但显示检查文件数为 0，因此不计为有效 lint 验证。
- 本次未重新部署设备或运行 Native TLS 回归；前述真机与 TLS 结果来自既有开发记录。
