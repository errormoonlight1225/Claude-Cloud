# SideStore 证书导出 (SideStoreCertExporter)

一个 iOS 小工具：用 **SideInstaller 导入 SideStore 证书的同一套方式**取出 SideStore 当前的签名证书（`.p12` + 密码），再导出成文件，供 LiveContainer、Feather、ESign 等签名工具使用。

## 工作原理

SideInstaller 用两种方式拿 SideStore 的证书，本应用都实现了：

### 1. SideStore 深链接回调（普通安装）

```
sidestore://certificate?callback_template=<URL 编码后的模板>
模板 = sscertexport://certificate?data=$(BASE64_CERT)&password=$(PASSWORD)
```

- SideStore 弹窗「Export Certificate」，确认后把 `$(BASE64_CERT)` 替换为证书 p12 的 Base64（再做 URL 编码），把 `$(PASSWORD)` 替换为密码（即证书序列号），然后打开该链接。
- iOS 把 `sscertexport://certificate?...` 交回本应用，本应用解析后即可导出。
- 密码放在最后，所以密码里带 `&` 也能完整读到。

### 2. 在 LiveContainer 中直接读取

在 LiveContainer 里运行时，iOS 只认 LiveContainer 自己 Info.plist 里的 URL scheme，所以 SideStore 的回调链接回不到这里。不过客体应用和 LiveContainer 跑在同一进程里，可以直接读：

- 内置 SideStore 的钥匙串项：service `com.kdt.livecontainer`，account `signingCertificate` / `signingCertificatePassword`。LiveContainer 会重定向客体应用的 `SecItemCopyMatching`，所以这里用 `dlsym` 取原始函数绕开重定向。
- LiveContainer 执行「Import Certificate from SideStore」后存的副本：`lcSharedDefaults` 中的 `LCCertificateData` / `LCCertificatePassword`。

## 功能

- 显示证书名称、序列号、到期时间（能用密码打开时）
- 分享或存储到「文件」：`SideStore-<序列号>.p12` + `SideStore-<序列号>-password.txt`
- 保存到本应用文件夹（「文件」App →「我的 iPhone」→「证书导出」）
- 复制密码、复制 Base64
- **修改密码**：用自定义密码重新打包 `.p12`（见下）

### 修改密码

iOS 能读 `.p12`，但没有写 `.p12` 的公开接口（`SecItemExport` 只在 macOS 上有），所以 `P12Builder.swift` 按 RFC 7292 自己打包：

1. 用原密码通过 `SecPKCS12Import` 打开，取出证书和 RSA 私钥；
2. 证书放进加密 safe，私钥做成 `pkcs8ShroudedKeyBag`，都用 pbeWithSHAAnd3-KeyTripleDES-CBC（2048 次迭代）加密；
3. 加 HMAC-SHA1 MAC；
4. 再用新密码 `SecPKCS12Import` 打开一次做校验，打不开就不导出。

3DES + SHA-1 是 iOS、macOS、OpenSSL 3（不需要 `-legacy`）和常见签名工具都能直接读的格式。原证书不会被改动，新证书会作为另一项出现在列表里。

## 构建

需要 macOS + Xcode 16 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
open SideStoreCertExporter.xcodeproj
```

也可以用 GitHub Actions：`.github/workflows/build.yml` 会构建未签名的 `SideStoreCertExporter.ipa` 并上传为 artifact。用 SideStore 或其他签名工具安装即可。

要求 iOS 16+。

## 安全提示

`.p12` 里有你 Apple ID 开发证书的**私钥**，拿到它的人能以你的身份签名应用。只导入到你信任的应用，不要公开分享。

## 致谢

导入方式参考了 [SideInstaller by FrizzleM](https://github.com/FrizzleM/SideInstaller)（`DeepLink.swift`、`LiveContainerCertificate.swift`）以及 [SideStore](https://github.com/SideStore/SideStore) 的 `ExportCertificateDialog`。本项目代码为独立实现。
