# Kiln — iOS 端证书申请 / 导出 + 本机签名安装器

Kiln 是一个纯 iOS 原生（SwiftUI）的侧载工具：在手机上直接申请开发证书、导出 `.p12` + `.mobileprovision`，并在本机重签名 IPA 后由系统直接安装。

和 SideStore / AltStore 这类工具的区别：

| | SideStore / AltStore | Kiln |
|---|---|---|
| 账号 | Apple ID 账号密码（私有协议） | App Store Connect API 密钥（Apple 官方 API） |
| 依赖 | 配对文件 + VPN/WireGuard，或电脑上的 AltServer | 无需电脑、配对文件或 VPN |
| 第三方服务器 | 需要 anisette 服务器 | 不需要，只连 Apple |
| 安装方式 | 通过 lockdown/installation_proxy | 系统原生 `itms-services` OTA 安装 |
| 签名有效期 | 免费账号 7 天 | 付费账号证书 1 年（描述文件按 Apple 规则） |
| 私钥 | 工具内部管理 | 在本机生成，存钥匙串，可随时导出 |

> **需要付费的 Apple Developer Program 账号。** 免费 Apple ID 无法使用 App Store Connect API。

## 功能

- **证书**
  - 用 API 密钥申请 *Apple Development* / *Apple Distribution* 证书：RSA-2048 私钥和 CSR 都在本机生成，只把 CSR 发给 Apple
  - 导入已有 `.p12`（+ 配套 `.mobileprovision`）
  - 导出 `.p12`（3DES/SHA-1 传统格式，iOS、macOS 钥匙串、各类签名工具都能读）+ `.cer` + 描述文件，同时保存到「文件 → Kiln → Exports」
  - 删除时可选择在 Apple 吊销
- **设备**：列出 / 注册账号下的设备 UDID
- **签名**（内置 [zsign](https://github.com/zhlynn/zsign) + OpenSSL，全部在本机完成）
  - 自动注册 App ID、生成包含全部已注册设备的描述文件（开发证书 → Development，发布证书 → Ad Hoc）
  - 修改 Bundle ID / 名称 / 版本 / 最低系统版本
  - 移除扩展、Watch App、设备型号限制；开启「文件」共享
  - 保留扩展时自动为每个扩展申请描述文件
- **安装**：在本机回环地址 (`127.0.0.1`) 起一个 HTTPS 服务，打开 `itms-services://` 链接，由系统安装器下载安装

## 本机安装服务需要一个 TLS 证书

iOS 只接受 **HTTPS + 受信任证书** 的安装清单，所以需要一个公共 CA 签发、域名解析到 `127.0.0.1` 的证书：

- 自己的域名：添加一条 `A` 记录（如 `install.example.com → 127.0.0.1`），用 Let's Encrypt DNS 验证申请证书；或
- 公开的回环域名证书，例如 `*.localhost.direct`（其私钥是公开的，只用于本机回环，**不要**用于其它用途）。

在「设置 → 本机安装服务」导入 `.p12` 或「证书链 PEM + 私钥」，填写域名和端口即可。服务只绑定回环网卡，局域网中的其它设备访问不到。证书过期后需要重新导入。

没有配置 TLS 证书时，仍然可以「导出 IPA」后用其它方式安装。

## 使用步骤

1. App Store Connect →「用户和访问」→「集成」→「App Store Connect API」创建团队密钥（Admin 或 Developer），下载 `AuthKey_XXXX.p8`
2. Kiln →「设置 → 开发者账号」填入 Issuer ID、Key ID，选择 `.p8`，点「验证并保存」
3. 「设备」页注册本机 UDID（iOS 不允许 App 读取 UDID，需要手动获取）
4. 「证书」页申请证书
5. 「应用」页导入 IPA → 选择证书 → 签名 → 安装到本机

## 构建

Kiln 本身也需要先安装到手机上（例如用 Xcode 或任意现有的签名工具装一次，之后 Kiln 可以给自己续签）。

```bash
brew install xcodegen
xcodegen generate
open Kiln.xcodeproj
```

GitHub Actions（`.github/workflows/build.yml`）会在每次推送时：

- 在 Linux 上编译并运行核心测试（CSR → 证书 → p12 → 描述文件 → 重签名）
- 在 macOS 上编译 iOS App，产物为未签名的 `Kiln-unsigned.ipa`

本地运行核心测试（需要 C++17 编译器和 OpenSSL 3 开发包）：

```bash
make -C Tests/core test
```

## 目录结构

```
Kiln/
  App/        入口、Tab 结构
  Bridge/     Objective-C++ 桥接（Swift ↔ C++）
  Core/       kiln_core：密钥/CSR/p12/证书解析/zip/签名（纯 C++ + OpenSSL，可在 Linux 测试）
  Models/     数据模型
  Services/   App Store Connect API、描述文件解析、IPA 解析、本机 HTTPS 安装服务
  Storage/    状态持久化、钥匙串
  Views/      SwiftUI 界面
Vendor/zsign/ zsign 源码（MIT），对日志输出和 system() 做了少量 iOS 适配，标记为 [Kiln patch]
Tests/core/   核心测试
```

## 安全说明

- 证书私钥、API 密钥、TLS 私钥都只保存在本机钥匙串（`ThisDeviceOnly`），不会进入 iCloud 备份
- 签名时私钥以文件保护模式临时写入沙盒，签名完成立即删除
- 除 `api.appstoreconnect.apple.com` 外不访问任何网络服务

## 许可

- zsign — MIT License
- OpenSSL — Apache License 2.0（通过 [krzyzanowskim/OpenSSL-Package](https://github.com/krzyzanowskim/OpenSSL-Package)）
- zlib / minizip — zlib License
