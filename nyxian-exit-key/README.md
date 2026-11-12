# ExitKey：Nyxian 悬浮退出键

这是一个 Nyxian KEXT，会在 Nyxian 环境里加一个红色 ✕ 悬浮按钮。装上以后，想换一个软件运行时，不用再把整个 Nyxian 关掉重开。

| 操作 | 效果 |
|---|---|
| **单击** | 退出当前在前台的 App。效果和点窗口的关闭按钮一样，同时会结束它的进程 |
| **长按** | 弹出菜单：退出当前 App / 退出全部 App / 多任务 / 回到桌面（不退出） |
| **拖动** | 移动按钮，松手后自动吸附到左右边缘，位置会被记住 |

支持 Nyxian 0.11.6.x（ksurface 0.11.5），iOS 18 及以上。

## 安装

1. 打开 Nyxian，新建项目，类型选 **Kext**，语言选 **C**。
2. 删掉项目里的 `Main.c`，新建 `Main.m`，把本目录的 [`Main.m`](Main.m) 完整粘贴进去。
3. 编译并安装这个 Kext。
4. 在 Nyxian 设置里打开 **Load kexts at boot**，然后在 Kext 管理页面把 ExitKey 开关打开。
5. 重新启动 Nyxian 环境。之后右侧会出现红色 ✕ 按钮。

> 第 2 步粘贴之后，把文件里的 `#define KEXT_IDENTITY "com.exitkey.nyxian"`
> 换成 Nyxian 自动生成的 `Main.c` 里那一行，保证标识符和项目一致。

## GitHub Actions 自动编译

每次推送 `nyxian-exit-key/` 下的改动，[`build-exitkey.yml`](../.github/workflows/build-exitkey.yml)
都会在 macOS 上用 iOS SDK 编译一遍，然后检查 KEXT 描述段 `__ksurfacemod` 是否存在，
最后打包成 `ExitKey.zip`（`Payload/com.exitkey.nyxian.kext/`，ad-hoc 签名），可以在 Actions 页面下载。

它的主要用处是在你往 Nyxian 里粘贴之前，先确认代码能编译通过。
Nyxian 自己有签名和信任机制，外部编译的 `.kext` 不一定能直接导入，
所以推荐的安装方式仍然是上面"在 Nyxian 里编译"那几步。

## 出问题时

- **编译时报找不到 `Main.m` 的符号，或者 `.m` 没有被编译**：说明 Kext 项目只认 C 文件。请把报错发给我，我改成纯 C 写法（通过 objc runtime 调用）。
- **Kext 加载失败，提示版本不符**：Nyxian 更新以后 ksurface 版本变了。把文件末尾 `ksurface` 的 `max_version` 调高即可。
- **按钮没出现，或者点了没反应**：代码对 Nyxian 内部接口都先做了检查再调用。接口变了的话按钮只会失效，不会让环境崩溃。这时把 Nyxian 版本号告诉我。
- **启动卡住**：Nyxian 有"不加载 KEXT 重启"的恢复选项，用它启动以后把 ExitKey 关掉。
