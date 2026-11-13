# TapRecorder — iOS 16 Dopamine 录制点击工具

一个 **rootless** 越狱插件（Dopamine / ElleKit，iOS 15–16.x，已针对 iOS 16.3 编写），可以**录制屏幕上的点击、滑动、多指操作，并按原始节奏回放**，全局生效（任何 App 内都能用）。

## 功能

- 悬浮控制面板（可拖动，可收起成小圆点）
- **● 录制**：记录所有手指的按下 / 移动 / 抬起，含多点触控、压力、触点半径，时间精确到 HID 事件时间戳
- **▶ 播放**：按原节奏回放；可设置 **次数**（1 / 3 / 5 / 10 / 50 / ∞）和 **速度**（0.5x – 4x）
- **📂 选择**：在已保存的录制间切换、删除
- 点击面板本身的操作**不会被录进去**
- 停止播放时自动抬起所有手指，不会出现“卡住的触摸”
- 录制文件为 JSON，保存在 `/var/mobile/Library/TapRecorder/`

## 安装

1. 到仓库的 **Actions → Build TapRecorder** 下载最新构建产物 `TapRecorder-rootless`，解压得到 `.deb`
   （或者自行构建，见下文）
2. 用 Filza / Sileo / Zebra 安装 `.deb`，或者：
   ```sh
   scp com.taprecorder.tweak_*.deb mobile@<设备IP>:/var/mobile/
   ssh mobile@<设备IP> "sudo dpkg -i /var/mobile/com.taprecorder.tweak_*.deb && killall SpringBoard"
   ```
3. 注销（respring）后，屏幕右侧会出现 **TR** 小圆点

## 使用

1. 点 **TR** 展开面板 → **● 录制**
2. 切换到目标 App 进行操作（面板一直悬浮）
3. 点 **■ 停止录制** → 自动以时间命名保存并选中
4. 设置次数、速度 → **▶ 播放**；播放过程中点 **■ 停止播放** 随时中止

显示 / 隐藏面板（需要安装 `notifyutil`，或任何能发 Darwin 通知的工具）：
```sh
notifyutil -p com.taprecorder.toggle
```

## 自行构建

需要 [Theos](https://theos.dev)：
```sh
cd TapRecorder
make package FINALPACKAGE=1   # 产物在 TapRecorder/packages/
```
Linux 下的完整环境搭建步骤见 `.github/workflows/build.yml`。

## 原理

| 环节 | 实现 |
| --- | --- |
| 注入 | 插件注入 SpringBoard（`TapRecorder.plist` 过滤） |
| 录制 | `IOHIDEventSystemClient`（monitor 类型）注册回调，拿到触摸屏的原始 Digitizer 事件；坐标为 0–1 归一化值，与屏幕方向无关 |
| 回放 | 用 `IOHIDEventCreateDigitizerEvent` + `IOHIDEventCreateDigitizerFingerEvent` 合成事件，设置录制时取得的真实触摸屏 senderID，经 `IOHIDEventSystemClientDispatchEvent` 送入 backboardd，由系统正常分发给前台 App |
| 计时 | 独立线程 + `mach_wait_until`，按录制时间戳精确调度 |

所有私有 IOKit 函数都通过 `dlsym` 运行时加载，编译时不需要私有头文件。

## 录制文件格式

```json
{
  "version": 1,
  "name": "2026-11-13_10-30-00",
  "senderID": "0x0000000100000XXX",
  "duration": 3.42,
  "frames": [
    { "t": 0.0, "touches": [ { "i": 2, "x": 0.51, "y": 0.73, "m": 3, "r": true, "t": true, "p": 0, "ma": 0.03, "mi": 0.03 } ] }
  ]
}
```
`t` 为相对秒数；`x`/`y` 为竖屏方向的归一化坐标；`m` 为 HID event mask；`r`/`t` 为 range/touch。可以手动编辑或用脚本生成后放进目录里直接回放。

## 注意

- 仅支持 rootless（Dopamine）。roothide 需要用 roothide 版 Theos 另外编译。
- 部分游戏 / 银行类 App 可能会检测合成触摸。
- 仅供个人自动化、测试与学习使用。
