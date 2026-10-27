# AutoTapper — iOS 系统级自动点击插件

适配 **iOS 16.2**,支持 **Dopamine(rootless 越狱)** 与 **TrollStore** 两种安装方式。

一个注入到应用内的悬浮控制面板:可拖动、选点、调节间隔、一键启停。
点击通过 IOKit 合成数字化仪(触摸)HID 事件实现,无需目标 App 配合。

---

## 功能

- 悬浮面板(可拖动到屏幕任意位置)
- **选坐标**:点进选点模式,点屏幕任意处记录为点击点
- **间隔**:0.1 / 0.3 / 0.5 / 1.0 / 2.0 秒循环切换
- **开始 / 停止**:定时合成 touch down + touch up

---

## 一、构建环境

需要 [Theos](https://theos.dev/docs/installation) + iOS SDK。在 macOS 或 Linux 上:

```bash
# 安装 theos(按官网说明)
export THEOS=~/theos

# arm64e 需要支持 iOS 16 的 SDK,放入 $THEOS/sdks/
# 例如 iPhoneOS16.2.sdk
```

克隆本工程后:

```bash
cd AutoTapper
make clean
make package FINALPACKAGE=1
```

产物在 `packages/com.example.autotapper_1.0.0_iphoneos-arm64.deb`。

> Makefile 默认 `THEOS_PACKAGE_SCHEME = rootless`(Dopamine 必须)。
> 若用的是旧版 rootful 越狱,把该行改成 `rootful` 再编译。

---

## 二、安装方式 A:Dopamine(rootless 越狱)

1. 把生成的 `.deb` 传到设备。
2. 用 **Sileo / Zebra** 打开安装,或命令行:
   ```bash
   # 在设备上(rootless 路径)
   su -c 'dpkg -i /var/jb/...com.example.autotapper...deb'
   ```
3. 安装脚本会自动 `sbreload` / 重启 SpringBoard。
4. 打开任意 App,约 1.5 秒后左上角出现悬浮面板。

Dopamine 自带 ElleKit(Substrate 兼容层),`AutoTapper.plist`
会让 dylib 注入所有链接 UIKit 的前台 App。

---

## 三、安装方式 B:TrollStore

TrollStore 本身安装的是 **IPA**,不直接吃 `.deb` tweak。两种做法:

### B-1. 用注入工具把 dylib 塞进某个 IPA(推荐)

1. 从上面编译产物里取出 dylib:
   `.theos/obj/rootless/AutoTapper.dylib`(或解包 `.deb` 里的
   `/var/jb/Library/MobileSubstrate/DynamicLibraries/AutoTapper.dylib`)。
2. 用 **TrollFools**(TrollStore 生态的注入器)选中目标 App,
   注入这个 dylib —— TrollFools 会自动处理签名与依赖。
3. 因为 TrollStore 环境没有 Substrate,dylib 里的 `%hook` 由
   TrollFools 内置的 ElleKit/libhooker 承接,可正常工作。

### B-2. 做成独立 TrollStore App

若想要一个独立图标的 App,把 `Tweak.xm` 里的面板逻辑
搬进一个普通 UIKit App 工程,`%ctor` 改为 `application:didFinishLaunching`,
用 TrollStore 安装该 IPA。此时只能在该 App 内点击(沙盒内)。
要系统级点击仍建议走 B-1 注入目标 App。

---

## 四、原理说明

- `IOHIDEventCreateDigitizerFingerEvent` 合成手指触摸事件;
- 归一化坐标后用 `UIApplication` 私有 `_enqueueHIDEvent:` 注入事件队列;
- 一次点击 = touch down → 30ms → touch up;
- `NSTimer` 按设定间隔重复。

因使用 IOKit/私有 API,仅在越狱或 TrollStore 授予相应权限的环境下有效,
普通 App Store 环境不可用。

---

## 五、常见问题

- **点不动**:部分 App 用了手势识别而非原始触摸,尝试把间隔调大、
  或确认选点坐标在可点区域。
- **面板不出现**:确认 dylib 注入成功;Dopamine 下看 Sileo 是否装上;
  TrollStore 下确认 TrollFools 注入的是当前打开的 App。
- **arm64e 崩溃**:确认用支持 iOS 16 的 SDK 编译,且 `ARCHS` 含 `arm64e`。
