# Nyxian rootless ROM —— 第一步分析：Nyxian 能提供什么 / 必须自己实现什么

- 依据：`emexlab/nyxian` 提交 `9236c22`（2026-11-09，`Config.xcconfig` 中 VERSION = 0.12.1）。
- 方法：只读源码，没有编译、没有真机运行。每一条结论后面给出文件位置；
  没读到或没法从源码确认的地方明确写"不确定"。
- 状态：**等你确认后才开始写代码。** 第 6 节列出需要你决定的事项。

---

## 0. 先说结论（有三处和任务描述里的前提不一样）

1. **ROM 不只是"用户空间"，它自带一份内核。**
   bootloader 对 `NXRomExecutable`（模板里叫 `main`，一个 dylib）做 `dlopen`，然后调用
   `NXSlotMain`（`Nyxian/UI/BootViewController.swift:1037-1049`）。
   `RomGen.py generate` 做的事情是把 `Nyxian/LindChain/ProcEnvironment`（即 ksurface）、
   `WindowServer`、bootstrapd 的 workspace 代码复制进 `rom/src`，再编译成 `main`
   （`RomGen.py:2635-2806`）。
   好处：挂载表、launch service、权限判断都可以在 ROM 自己的那份内核里改，
   不受 App 内置内核限制。
2. **许可证问题比任务描述里说的更严格，而且直接影响"交付物"。**
   仓库里带 SPDX 头的文件中，445 个是 EPSL 1.1，只有 26 个是 AGPL/GPL
   （LiveContainer 衍生文件、`Shims/environment.m`、TWRP 界面）。
   `Surface/` 全部、`RomGen.py`、`LiveProcess/`、`Daemons/`、`Frameworks/` 都是 EPSL。
   EPSL 第 2 条：向外部提供副本（源码或编译后，包括公开仓库、fork、作为其他产品的一部分）
   都需要 emexLabs 事先书面许可。
   所以**任何用 `RomGen.py generate` 做出来的 `rom.zip` 都包含 EPSL 代码的编译产物**——
   和你对 Switzach 的顾虑是同一个问题，不能靠"自己从头写"绕开，因为 `main` 必须是 ksurface。
   私下构建、自己用是允许的。详见第 5 节。
3. **`KSURFACE_EMIT_LAUNCHD` 基本是空的。**
   它只在 `Surface/proc/spawn.m:178-191` 出现一次（`kill(1, SIGKILL/SIGTERM)` 触发用户空间重启），
   `ksurface_config.h` 里根本没有定义这个宏。内核里没有 pid 1 的 launchd。

另外：我在这个环境（Linux 容器）里**无法编译 ROM**（模板 Makefile 需要 `xcrun -sdk iphoneos`，
`RomGen.py sign` 的 ad-hoc 签名需要 macOS 的 `codesign`），也没有真机。
所以"每个里程碑给一个可以刷的测试 rom.zip"只能是：我写代码和 CI，CI（macOS runner）出包，
**由你在真机上测**。我不能声称任何一个包"已验证可启动"。

---

## 1. Nyxian 已经提供、可以直接用的

| 需求 | Nyxian 现有机制 | 位置 |
|---|---|---|
| 虚拟根和挂载 | `$vroot = $croot/Documents/rootfs`；挂载表写死在 `ksurface_fs_init`，`$vroot` 本身是可读写挂载；ROM 自己那份 `fs.m` 可以加挂载（RomGen 本身就用 `patch_rom_application_mount` 改它） | `Surface/fs/fs.m:57-125`，`RomGen.py:2126` |
| ROM 数据目录 | manifest 的 `NXRomDataPartitionPath`（必须以 `$(BOOTROOT)/` 开头，不能和 `Library/Boot/Slot`、`Library/Preferences`、`Documents/Inbox`、`Documents/TWRP`、`tmp` 重叠）；Recovery 的 Wipe 只清这个目录 | `Nyxian/UI/ROMStoragePolicy.swift` |
| 进程模型 | pid/ppid/sid/pgid、子进程表、zombie + `wait4`、SIGCHLD、`kill` | `Surface/proc/spawn.m`，`Surface/sys/proc/` |
| 虚拟 root | 带 `platform` + `platform-root` 权限的二进制一启动就是 uid 0；`platform.user` / `platform.group` 可指定任意 uid/gid；`setuid` 系列在"有 `org.emexlabs.nyxian.sugid` 权限或 ruid==0"时放行；子进程复制父进程凭据 | `spawn.m:56-93`，`Surface/sys/cred/setuid.c:57-67`，`trust.m:426` |
| `chown` 不报错 | guest 侧 shim 把 `chown/lchown/fchown/fchownat` 一律改成 `501:501` 后调用原函数，所以 `chown root:wheel` 返回成功 | `Frameworks/LiveProcessLegacy/LowShim/LPLLSUcred.c:271-298` |
| 权限描述 | NXT2 entitlements；manifest 的 `NXRomPaths[].NXT2Entitlements` 给 ROM 内文件授权 | `Surface/trust/entitlement.c`，`RomGen.py` 的 MANIFEST 模板 |
| Mach 端口登记 | `PEBootstrapRegistry`：名字 → send right；`SYS_pectl` 的 `LaunchServiceGetEndpoint / SetEndpoint`，按权限位或 allow-list 判断，并防止别的进程冒名覆盖已有服务 | `PEBootstrapRegistry.m`，`Surface/sys/compat/pectl.m:36-170` |
| 基础服务管理 | `PELaunchServiceManager` 读 `$mnt/lsfs/*.plist`（映射为 `$vroot/System/Library/LaunchDaemons`），支持自动重启（退避，1 秒内连续崩溃超过 5 次就放弃） | `PELaunchService.m`，`PELaunchServiceManager.m` |
| 给二进制签名 | `SYS_sign`：有 `process.spawn` 权限的进程可以让内核用用户证书给 Mach-O 签名 | `Surface/sys/compat/sign.m` |
| 可打补丁的 libc/Mach 入口 | `Broadpatch` 给约 280 个函数（`open/stat/posix_spawn/…`，也包括 `bootstrap_look_up / look_up2 / register / check_in`）建了可替换的 interpose 槽位 | `Frameworks/Broadpatch/Broadpatch.m`，`Surface/libkern/patch.h` |
| ROM 签名 / 票据 | `RomGen.py genkey / prove / sign / verify / digest`；TSS 地址 `https://developer.emexlabs.org/api/v1/tss` | `RomGen.py`，`Nyxian/LindChain/Utils/NXROMTicket.m:59` |

---

## 2. Nyxian 有，但不够用的

### 2.1 服务管理（对应目标 2）
- plist 格式是 Nyxian 自己的：`PEServiceIdentifier / PEExecutablePath / PEShouldAutorestart /
  PEEnabled / PEIsMultiInstanceDaemon / PEEnvironment`，**不是** launchd 的
  `Label / ProgramArguments / KeepAlive / MachServices`。
- 没有任何 unload / stop / list / print 接口：`SYS_pectl` 的 LaunchService 分类只有
  Get/SetEndpoint 两个动作（`ksurface_abi.h`）；`launch-services.start / stop / toggle`
  三个权限在头文件里标着 `/* unimplemented */`（`entitlement.h`）。
- `loadEntryWithFileName:` 没用到参数，把目录路径当成 plist 路径传下去（`PELaunchServiceManager.m:124-135`），
  看起来不能用。
- 服务由 `kernel_proc_` 派生，退出状态只在内核内部回调里，guest 拿不到。
- `lsfs` 只有 platform 进程能写（`kFSMountAttrWritePlatform`）。

结论：现有机制只适合用来**启动我们自己的 launchd 这一个进程**，不能直接当 launchd 用。

### 2.2 Mach 服务（`bootstrap_check_in` / `xpc_connection_create_mach_service`）
- 仓库里**找不到** guest 侧对 `bootstrap_look_up / check_in` 的任何实现，只有 Broadpatch 里的空槽位。
  现有服务（bootstrapd）是用匿名 `NSXPCListener` + `xpc_endpoint_copy_listener_port_4sim`
  取出端口，再用 `SYS_pectl SetEndpoint` 登记（`Frameworks/LiveProcessLegacy/ServiceKit/LPLService.m`）。
- `xpc_connection_create_mach_service` 不在 Broadpatch 的槽位列表里。
- `GetEndpoint` 需要权限位或 allow-list；dpkg 装进来的普通二进制没有 NXT2 blob，
  走 fallback 身份，权限为空（`trust.m` 的 fallback 分支），所以默认查不到任何服务。

### 2.3 root
- 有 uid 0，但文件属主是假的：`chown` 被改写成 501，`stat` 永远看不到 root。
  需要"属主是 root 才工作"的软件（例如检查 setuid 位、检查 `st_uid == 0`）会不对。
- 非 platform 的父进程派生子进程时，子进程多出来的权限会被剥掉（`trust.m:763-786`）。
  所以 `sudo` 必须自己带 `sugid`，不能指望从 shell 继承。

### 2.4 代码签名
- 任何要执行的 Mach-O 都必须有用户证书的有效 Apple 签名，否则连身份都建不出来
  （`trust.m` 里每个分支都先做 `LCCheckCodeSignature`）。
- Procursus 的 deb 是 ad-hoc / ldid 签名，装完必须逐个 `SYS_sign`。
- **不确定**：`posix_spawn` shim 是否会在执行前自动签名未签名的文件
  （`Shims/posix_spawn.m` 522 行，我只看了概要，没逐行读）。
  也**不确定** 7 天免费证书过期后，数据分区里的二进制由谁重签——
  bootloader 的 `refreshROMSigningIfNeeded` 看名字只处理 ROM slot。

---

## 3. Nyxian 没有，必须自己实现的

1. **路径层（最大的一块）。**
   guest 只能通过 `SYS_vroot` 问到 `$vroot` 的真实路径（`LPLVRoot.c`），
   内核不替 guest 做路径改写；我读到的 guest shim 里只有 `access/faccessat` 两个 IO 补丁
   （`LPLLSIO.c`，79 行）。rootless 软件里写死的 `/var/jb/...`
   （包括 dylib 的 install name、shebang、`dlopen`、`posix_spawn`、CF/NS 字符串）
   都要我们自己的注入库改写成 `$vroot/var/jb/...`。功能上等同于 Switzach 的
   `NXRootlessCompatInit`，但必须独立重写。
   **不确定**：这个库怎样保证被注入到每一个 guest 进程（Broadpatch 的加载路径我没读完）。
   **现状（已实现，未上真机）：**
   - 注入点已确认：每个 guest 启动时 `Shims/environment.m:235-251` 会
     `dlopen("$vroot/boot/rtpatch")`，在 guest 自己的代码之前。stock Nyxian 在
     `ksurface_shimcache_build` 里现场编译它；ROM host 没有编译器，RomGen 模板把这一步留空
     （`RomGen.py` 的 `SHIMCACHE_M`）。本 ROM 用 `rom-overlay/kernel/shimcache.m`
     替换这一步：每次启动把 slot 里预编译的 `rtpatch` 拷到 `$mnt/bootfs/rtpatch`。
   - 改写方式：`libBroadpatch.dylib`（`@rpath`，真 dylib）为每个被 interpose 的函数导出
     `<name>__ptr` 槽位（`Broadpatch.h` 的 `LIBKERN_DEFINE_INTERPOSE_PATCHABLE`）。
     `src/rtpatch/nxjbpath.c` 用 `dlsym` 找槽位，把带路径参数的 36 个函数换成"先改写再调原值"的包装，
     所以 Nyxian 自己的补丁（`posix_spawn`、`access`、`chown`…）仍在下面生效。
     `posix_spawn` shim 自己先 `realpath` 再把真实路径交给内核（`Shims/posix_spawn.m:170`），
     所以我们**不**把 `realpath/getcwd` 的结果反向改回 `/var/jb`。
   - 符号链接：真内核解析符号链接，绝对目标 `/var/jb/...` 会指向不存在的真 `/var/jb`。
     安装器解包时、以及运行时的 `symlink()`，都把这类目标改存为相对路径。
   - **管不到的**：dyld 自己打开文件（dylib 的 install name、`dlopen`），不经过这些槽位。
     链接了 `/var/jb/usr/lib/*.dylib` 的二进制必须在打包 bootstrap 时把 load command 改成
     `@loader_path/...`（下一步）；之后 dpkg 装的包要靠触发器做同样的事。`#!` 行同理
     （仓库里没找到 Nyxian 处理 shebang 的代码）。
   - **不确定**：(a) 槽位符号从 `rtpatch` 里 `dlsym(RTLD_DEFAULT)` 能否拿到（按构建设置应当可以，
     没在真机上看过）；(b) libc 内部的 `fopen → __open_nocancel` 是否走槽位（Broadpatch 专门
     留了 `__open_nocancel` 槽位，推测是，但取决于 dyld 对 shared cache 的 interpose）。
     真机上用 `NXJB_DEBUG=1` 跑任意程序即可看到挂上了几个槽位。
2. **launchd 兼容守护进程 + launchctl**（设计见第 4 节）。
3. **libxpc / bootstrap 兼容层**：`bootstrap_check_in / look_up`、
   `xpc_connection_create_mach_service`（监听和连接两个方向）、
   `NSXPCConnection initWithMachServiceName:` / `NSXPCListener initWithMachServiceName:`。
4. **bootstrap 安装器**。ROM seal 要求 slot 里的文件除签名外不能变
   （`RomGen.py` 文件头说明），所以 Procursus bootstrap 不能解压进 slot，
   只能首次启动时解压到数据分区，再把它呈现为 `$vroot/var/jb`。
5. **SpringBoard**。模板 ROM 只有窗口服务器和一个应用列表（`NXMainSlot.m`），
   主屏幕、respring、安全模式、`uicache` 的注册接口都要自己做。
6. **dpkg 触发器**：解包后签名、扫描 `Library/LaunchDaemons`、扫描 `Applications`。
7. **TweakInject 加载器**：读 `DynamicLibraries/*.plist` 的 Filter，按 bundle id / 可执行名加载。

---

## 4. 建议的 launchd 方案

**独立守护进程，不改内核里的服务管理器。** 理由：这部分代码完全是我们自己的（许可证干净），
而且作为真正的父进程能直接拿到 `wait4` 的退出状态和 SIGCHLD。

- `launchd`（自己写）：由 ROM 的一个 `PE*` plist 启动，`PEShouldAutorestart = true`，
  manifest 里给它 `platform`、`platform-root`、`process.spawn`、`process.kill`、
  `process.enumeration`、`launch-services.set-endpoint.allow-list = [<id>.launchd]`。
- 它自己解析标准 launchd plist（两个目录），自己 `posix_spawn` 子进程
  （按 `UserName` 先 `setgid/setuid`），自己维护 Label → PID / 上次退出状态 / KeepAlive 重启、
  enable/disable 的持久化覆盖表。
- Mach 服务表也放在 launchd 里：每个 `MachServices` 名字由 launchd 预先建好端口，
  `check_in` 时把 receive right 交给守护进程，`look_up` 时发 send right。
  这样可以做到按需启动。只有 launchd 自己的控制端口登记在 `PEBootstrapRegistry`。
- `launchctl`：通过控制端口发请求。权限规则由 launchd 判断：
  调用者 euid == 0，或者是 Label 所属用户，才能 load/unload —— 不看"是不是 platform binary"。
  （调用者的 uid 从内核查，不信任调用者自报。**不确定**用哪个接口最稳妥，
  候选是 `proc_pidinfo`，它在 Broadpatch 槽位里。）
- **需要改内核的地方只有一处**：让所有进程都能 `GetEndpoint` 到 launchd 的那一个名字
  （否则 dpkg 装的普通 App 查不到）。用构建时的补丁脚本对 `pectl.m` 做，和 RomGen
  自己的 `patch_*` 函数同一种做法。

风险：
- libxpc 在 dyld shared cache 里，`__interpose` 对 cache 内部互相调用是否生效，**不确定**。
  如果不生效，`NSXPCConnection` 一类走 Foundation 内部的调用要用 ObjC swizzle 兜底。
- irisind / filad 是闭源的。我们能保证的是"launchctl 不再报 154、进程被拉起、
  Mach 服务能连上"；它们内部如果还依赖真实内核权限（例如真正的 root 文件访问、
  `task_for_pid` 到系统进程），就仍然不能工作。**验收测试 4 我不能事先保证通过。**

---

## 5. 许可证和仓库结构

- 仓库里只放：我们自己写的代码、对 Nyxian 源码的**补丁脚本**、manifest 生成脚本、CI。
  不提交 `RomGen.py generate` 生成出来的 `rom/src`，也不提交 `RomGen.py` 本身。
- CI 在构建时 clone 固定提交的 `emexlab/nyxian`，运行 `generate`，打补丁，编译。
- 但是 **`rom.zip` 本身一定含有 EPSL 代码的编译产物**。
  - 你自己构建、自己刷：EPSL 第 2 条允许（"Copying for private or internal use is permitted"）。
  - 给别人、放 Release、公开仓库的 Actions artifact：需要 emexLabs 书面许可。
    反正要去 developer.emexlabs.org 注册密钥，建议同时把再分发许可一起申请。
- 第三方组件（Procursus bootstrap、ElleKit、Sileo/Zebra）在构建时下载官方 deb，
  各自保留原许可证。Dopamine 的代码目前不打算用。
- 这不是法律意见；EPSL 是 emexLabs 自己写的许可证，有疑问以他们的书面答复为准。

---

## 6. 现实限制，以及需要你确认的事项

### 做不到或只能部分做到的
- **目标 4 / 验收 5（插件对 SpringBoard 生效）**：ROM 的 SpringBoard 是我们自己写的 App，
  不是 Apple 的 SpringBoard。针对 `SBIconView`、`SBHomeScreenViewController` 这类
  系统类的插件没有东西可以 hook。能生效的只有：hook UIKit / Foundation 通用类的插件，
  以及针对**跑在 Nyxian 里的 App** 的插件。手机上原生安装的 App 和系统进程完全碰不到。
- **C 函数 hook（`MSHookFunction`）**：未越狱设备上代码页不可写。ObjC 的
  `MSHookMessageEx` 没问题；内联 hook 是否可行取决于 Nyxian 的 JIT / `HWHook`
  （硬件断点）能力，我还没读这部分，**不确定**。
- **arm64e**：模板 Makefile 是 `ARCH := arm64`，所以 `iphoneos-arm64` 的包在架构上是合适的。
- **票据**：刷入时设备要联网向 TSS 取票据（`BootViewController.swift:588-628`）。
- **设备身份**：我读到的顺序是 App 包内 `UniqueID` 文件（NyxLoader）→ 容器里
  `Library/NyxLoader/UniqueID` 镜像 → 数据卷 UUID 的 SHA-256
  （`NXDeviceIdentity.m`）。和你描述的"容器 UUID"略有出入，
  我只读了这个文件的前 130 行，以官方文档为准。

### 请你确认
1. **分发范围**：只自己用（仓库设为私有），还是要公开？公开的话需要先拿到 emexLabs 的书面许可。
2. **`NXRomIdentifier`** 用什么？最低 Nyxian 版本定 0.12.0 还是 0.12.1？
3. 接受第 4 节的方案吗（独立 launchd + 一处内核补丁），还是希望尽量改内核里的服务管理器？
4. 接受"SpringBoard 插件只对 ROM 自己的 SpringBoard 和 Nyxian 内的 App 生效"这个范围吗？
5. CI 用 GitHub 的 macOS runner 可以吗（私有仓库会消耗付费分钟数）？
   ROM 签名私钥放 Actions secret，还是 CI 只出未签名包、你本地签？
6. 包管理器选 Sileo 还是 Zebra？

### 确认后的里程碑顺序
0. 构建管线：CI clone Nyxian → generate → 补丁 → 编译 → 未改功能的模板 ROM 能启动。
1. `/var/jb` + 路径层 + bootstrap 安装器 + 签名触发器 → `dpkg --print-architecture`。
2. launchd / launchctl / bootstrap+XPC 兼容层 → 验收测试 3。
3. sudo/su、TweakInject、安全模式。
4. SpringBoard、uicache、Sileo/Zebra。

每一步交付：源码、CI 产物、你在真机上执行的测试步骤。

---

## 7. 补充（2026-11-10）：对照 Fluxer 上的 0.12.0 安装包

你给的 `Nyxian.ipa` 是 0.12.0，构建号 `20261106.10.RELEASE`。它在 `Shared/kernel/` 里带了
1617 个头文件，我拿它们和源码逐个比对：

- 和 0.12.1 源码树（`02947af` 及之后）只有 7 个头文件不同，全部在 `LindChain/Utils/`
  （`NXROMFileHash.h`、`NXBootPolicy.h`、`NXROMTicket.h`、`NXTrustStore.h`、
  `NXROMDeviceTrust.h`、`NXROMTrust.h`、`NXDeviceIdentity.h`），是 bootloader 一侧的文件；
  差别是注释，外加一个函数声明（`NXROMDeviceVerifyOTAExecutable`）。
- `ProcEnvironment` 下所有头文件、`ksurface_abi.h`、`NXLiveProcessABI.h` 完全一致。

所以用 0.12.1 源码编 ROM 内核、声明最低版本 0.12.0 是合理的。
这只说明接口声明一致；实现文件我比不了（安装包里只有编译产物），能否启动仍以真机为准。

两处更正前文：

1. **设备身份**（更正第 6 节）：安装包头文件的注释写明来源有三种——
   `bundle`（NyxLoader 写进 App 包）、`container`（之前保存在容器里的）、
   `volume`（由数据卷 APFS UUID 算出，用于不是 NyxLoader 安装的版本）。
2. **不一定要注册密钥**（补充第 1 节）：`NXBootPolicy.plist` 由 NyxLoader 在安装 Nyxian 时
   按它自己的设置写进 App 包。`NXTrustStoreValidation = false` 时，没有 TrustStore 密钥签名的
   ROM 也能刷；`NXTSSValidation = false` 时，不需要安装票据。文件列表校验、设备封印、
   防降级仍然生效（`Nyxian/LindChain/Utils/NXBootPolicy.m`，`NXROMTrust.m:124-141`）。
   你给的安装包里没有这个文件（它是安装时才写入的），所以你的设备上是哪种设置，我不知道。
