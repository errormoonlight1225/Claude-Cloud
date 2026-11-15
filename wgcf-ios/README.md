# WGCF for iOS

[wgcf](https://github.com/ViRb3/wgcf) 的 iOS 图形界面客户端，使用 SwiftUI 编写，无第三方依赖。
它直接调用 Cloudflare WARP 的注册 API，完成 wgcf 命令行的全部功能，并生成可导入
[WireGuard](https://apps.apple.com/app/wireguard/id1441195209) 的配置文件。

> 非官方工具，与 Cloudflare 没有任何关联。使用前请阅读
> [Cloudflare 服务条款](https://www.cloudflare.com/application/terms/)。

## 功能

| wgcf 命令 | 应用中的位置 |
| --- | --- |
| `wgcf register` | 首次启动的注册页：设备名称、型号、可选的已有私钥、同意服务条款 |
| `wgcf status` | 「账户」页：账户类型、WARP+ 流量、配额、设备列表 |
| `wgcf update --license-key` | 「账户」页 → 绑定其他许可证 |
| `wgcf update --name / --activate / --deactivate / --remove` | 「账户」页设备行左滑或长按 |
| `wgcf generate` | 「配置」页：预览、分享到 WireGuard、二维码、复制 |
| `wgcf trace` | 「检测」页：显示 `warp=on/plus/off` 及完整 trace 信息 |

此外还支持：

- 导入 / 导出与命令行兼容的 `wgcf-account.toml`
- 配置选项：端点（域名 / IPv4 / IPv6）、PersistentKeepalive、MTU、DNS、AllowedIPs
- 在 Cloudflare 上注销当前设备
- 凭据（私钥、访问令牌）保存在系统钥匙串中，不随 iCloud 同步

## 使用方式

本应用只负责账户管理和生成配置，**不包含 VPN 隧道本身**。连接 WARP 的步骤：

1. 在本应用中注册，进入「配置」页
2. 点「分享 / 在 WireGuard 中打开」，在分享面板里选择 WireGuard
3. 在 WireGuard 应用中启用隧道
4. 回到本应用的「检测」页，确认显示「WARP 已启用」

## 构建

需要 Xcode 16 或更新版本，最低支持 iOS 17。

```sh
open wgcf-ios/WGCF.xcodeproj
```

在 Xcode 的 Signing & Capabilities 中选择自己的开发团队后即可运行到真机；模拟器无需签名。

命令行运行单元测试：

```sh
cd wgcf-ios
xcodebuild test -project WGCF.xcodeproj -scheme WGCF \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

没有 Mac 也可以：仓库里的 GitHub Actions 工作流（`.github/workflows/wgcf-ios.yml`）会在每次推送时
运行测试，并上传一个**未签名**的 `WGCF-unsigned.ipa`，可用 AltStore、Sideloadly 等工具自行签名安装。

## 目录结构

```
wgcf-ios/
├── WGCF.xcodeproj
├── WGCF/
│   ├── WGCFApp.swift
│   ├── Core/        # API 客户端、密钥、配置生成、钥匙串、状态管理
│   └── Views/       # 注册、账户、配置、检测四个界面
└── WGCFTests/       # 单元测试（密钥、配置、账户文件、API 流程）
```

## 已知限制

- wgcf 命令行会用 uTLS 模拟官方 Android 客户端的 TLS 指纹；iOS 上只能使用系统 TLS 栈，
  本应用仅把协议版本固定为 TLS 1.2。如果 Cloudflare 日后按指纹严格拦截，注册请求可能被拒绝。
- API 版本号与客户端标识跟随 wgcf 2.3.1（`v0a5641`），定义在 `WGCF/Core/WarpAPI.swift`，
  上游更新时需要同步修改。
