# Claude-Cloud

This is a repo for claude code cloud.

## Claude iOS 客户端（支持 iOS 12.5.8）

一个用 Swift + UIKit 编写的原生 Claude 聊天客户端，部署目标为 **iOS 12.0**，可运行在 iPhone 5s / 6 / 6 Plus、iPad Air、iPad mini 2/3、iPod touch 6 等停留在 iOS 12.5.x 的设备上。

### 功能

- 通过 Anthropic Messages API 流式（SSE）显示回答，可随时停止
- 多会话管理，记录保存在本机，左滑删除
- 模型切换：Claude Opus 5.5（默认）、Sonnet 5.5、Haiku 5.5、Fable 5.1，或自定义模型 ID
- 思考强度（effort）可调，可显示思考摘要
- 自定义系统提示词
- 可配置 API 地址（便于使用自建反向代理）
- 简易 Markdown 渲染（代码块、标题、列表、粗体、行内代码等）
- API Key 保存在钥匙串中
- 安全策略拒绝时自动切换到 Anthropic 推荐的备用模型（服务端 `fallbacks`），并在界面中提示

### 为什么能在 iOS 12 上运行

- 只使用 UIKit 和 iOS 12 已有的 API：不用 SwiftUI、Combine、async/await、SF Symbols，也不用 SceneDelegate
- 流式响应用 `URLSessionDataDelegate` 自行解析 SSE（`URLSession.bytes` 需要 iOS 15）
- 仅 arm64；所有能升级到 iOS 12 的设备都是 64 位

### 构建

项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成 Xcode 工程：

```bash
brew install xcodegen
xcodegen generate
open ClaudeClient.xcodeproj
```

需要使用 **Xcode 15 或 16**（这两个版本仍支持把部署目标设为 iOS 12）。在 Xcode 中选择你的开发者团队后，即可直接安装到设备。

也可以不用 Mac：每次推送后，GitHub Actions（`.github/workflows/build-ios.yml`）会构建一个 ad-hoc 签名（伪签名）的 `ClaudeClient.ipa`，在 Actions 运行页面的 Artifacts 中下载。

### 安装到 iOS 12 设备

该 IPA 只带 ad-hoc 签名，没有 Apple 证书，所以：

- **已越狱 + 已装 AppSync Unified**：可以直接安装（例如用 Filza 打开 ipa 安装）
- **未越狱**：必须先用自己的证书或 Apple ID 重新签名，例如：
  - **Sideloadly**（Windows / macOS，免费 Apple ID 即可，7 天有效）
  - **AltStore**（要求 iOS 12.2 及以上，12.5.8 满足）
  - 手机上的签名工具（如轻松签）：先导入证书，用“签名”功能签名后，再安装签好的 ipa

直接安装未经重新签名的包时，系统会提示 `0xe800801c (No code signature found)` 或签名验证失败。

### 使用

1. 打开 App，在“设置”中填写 Anthropic API Key（从 console.anthropic.com 获取）
2. 点右上角新建对话，开始聊天

如果设备所在网络无法直接访问 `api.anthropic.com`，或旧系统的根证书无法验证服务器证书，可在“API 地址”中填写一个兼容 Anthropic API 的 HTTPS 反向代理地址。
