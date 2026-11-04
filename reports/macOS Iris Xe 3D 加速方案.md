# 借 Apple 半虚拟显卡，让 Iris Xe 间接跑 Metal

**结论先行：在 2026 年 11 月，「只模拟显卡、让 macOS 获得 Metal 3D 加速」在原理上可行，且有一条现成的开源路线，但这条路线从未在 Intel Iris Xe 上被任何人验证过。** 这条路线不依赖 macOS 对 Iris Xe 的原生驱动（该驱动并不存在），而是让 Linux 宿主重新实现 Apple 自家 `AppleParavirtGPU` 设备的宿主侧：guest 里的 macOS 加载自带的官方驱动，把 Metal 命令流发给虚拟 PCI 显卡，宿主把命令流解码、把着色器翻译成 SPIR-V，再交给 Mesa anv 的 Vulkan 执行。目前最成熟的实现是 steelbrain 的 reims-vgpu（Beta，宣称 x86-64 的 macOS 26 Tahoe 在 Linux/KVM 上可用），另有 libapplegfx-vulkan 与 ultimate-macOS-KVM 的 `pvg-metal-vulkan` 分支两个独立实现。三者所有公开测试都在 NVIDIA 显卡上完成，实测帧率只有约 25 到 30 帧每秒，且全部是 2026 年才出现的单人维护项目，README 中的性能与稳定性数字均为作者自报，没有任何第三方复现。原生路线（伪装成 Ice Lake、自制 Xe 驱动）、iGPU 直通、GVT-g 和 SR-IOV 对 macOS guest 全部不通。因此最现实的方案是「软件渲染兜底 + 并行验证 Reims 能否在 anv 上跑通」：先用现成 Docker 镜像在这台机器上做一次一到三天的验证，再决定是否把它并入 MacBoot。法律上，Apple 的许可协议只允许在 Apple 品牌硬件上运行 macOS，这对所有路线一视同仁。

## Iris Xe 本身无路可走：原生驱动、直通、GVT-g 与 SR-IOV 全部落空

要回答「依赖原生驱动可不可以」，先要排除掉让 Iris Xe 直接服务 macOS 的所有办法。Dortania 的显卡选购指南明确写道，基于 Xe 的 iGPU（Tiger Lake、Rocket Lake、Alder Lake、Raptor Lake、Meteor Lake）「在任何版本的 macOS 中都不受支持」，最高与最初支持版本都标为 None ([Dortania](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/intel-gpu.html))。原因不难推断：Apple 从未出货过 Gen12 图形的 Mac，而 Tahoe 是最后一个支持 Intel Mac 的版本 ([Six Colors](https://sixcolors.com/post/2025/06/macos-tahoe-is-the-last-release-to-support-intel/))，所以 Apple 官方驱动永远不会出现。社区的「伪装成 Ice Lake」办法也被报告无效：2026 年 3 月 r/hackintosh 上的一位评论者称 Iris Xe 不能伪装成 Iris Plus ([Reddit 镜像](https://reddit.sentinel-team.org/posts/1rpmb02/snapshots/2026-03-11T09%3A39%3A01.441986Z))，InsanelyMac 版主 Slice 对 Alder Lake 的评价是「没有机会」([InsanelyMac](https://www.insanelymac.com/forum/topic/359261-need-help-on-legacy-shim-2-error/))。这些都是个案证词，但与 Dortania 的表格方向一致。GitHub 上唯一的 Tiger Lake 第三方 kext 自己承认「只打开表面与显示相关的用户客户端，没有命令提交，没有 Metal」([pawan295](https://github.com/pawan295/Appleinteltgldriver.kext))，不能视为 Metal 方案。

虚拟化层面的分享手段同样走不通。Intel 的 GVT-g（中介式 vGPU）只覆盖到 Comet Lake 一代，从 Tiger Lake 起被 SR-IOV 取代 ([LKML](https://lkml.indiana.edu/hypermail/linux/kernel/2506.3/09825.html))。SR-IOV 在 Xe-LP 上对 Linux 与 Windows guest 确实可用，社区维护的 strongtz/i915-sriov-dkms 在 2026-10-28 仍在发布新版本，但文档列出的 guest 只有 Ubuntu 和 Windows 11，macOS 不在其中 ([strongtz](https://github.com/strongtz/i915-sriov-dkms))。即使 VF 暴露给了 macOS，guest 里也没有任何 kext 会匹配这个 Gen12 设备，最多是一个无人认领的 PCI 设备（这是推断，未见实测报告）。整颗 iGPU 直通更糟：连 HD 630 这种 Apple 有驱动的老核显，Proxmox 论坛上的 macOS 直通案例也是「识别到显示器但 Metal 不工作」([Proxmox 论坛](https://forum.proxmox.com/threads/pve-intel-gpu-passthrough-to-macos-monterey-no-signal.115502/))，而在纯核显机器上直通核显还会让宿主自己失去显示。唯一的结论是：Iris Xe 只能以「宿主侧 Vulkan 设备」的身份参与，guest 需要看到的必须是另一块虚拟显卡。

## 唯一现实的路线：在 Linux 上复刻 Apple 半虚拟显卡的宿主侧

Apple 的 ParavirtualizedGraphics 框架本是宿主侧的黑盒：虚拟机应用声明一块虚拟显卡，创建 PGDevice 并提供任务内存的创建、映射、读取回调，再为每个显示器创建 PGDisplay；macOS 11 起 guest 里就自带对应驱动 `AppleParavirtGPU.kext` ([Apple 文档](https://developer.apple.com/tutorials/data/documentation/paravirtualizedgraphics.md)，[Parallels KB](https://kb.parallels.com/en/124095))。QEMU 10.0 合入的 `apple-gfx-pci` 与 `apple-gfx-mmio` 设备正是调用这个框架，因此只能在 macOS 宿主上用，要求 macOS 11 以上并有支持 Metal 的 GPU，在 x86-64 guest 上提供 3D 与 GPGPU，但只保证基线 Metal 特性集，且只支持单显示器、不支持迁移 ([patchew 封面信](https://patchew.org/QEMU/20241029205819.69888-1-phil@philjordan.eu/))。它对 Linux 宿主毫无用处，除非有人重写这层框架——2026 年，真的有人做了。

**reims-vgpu** 是其中最成熟的。项目自称「实验性虚拟 GPU」，状态 Beta、「已基本稳定」，x86-64 路径是 QEMU q35 加 OpenCore，加 PCI `apple-gfx-pci` 设备与 UEFI 选项 ROM，宿主端用 Rust 写的核心库解码命令流，并借 metal2vulkan 把 Metal 着色器翻译成 SPIR-V；guest 无需安装任何自定义显卡驱动，只有 OpenCore 镜像里一个很小的 `ReimsVgpu.kext`。仓库有 3395 次提交、660 颗星、24 个未决 issue，许可证为 GPL-2.0+ 或 LGPL-3.0+ ([reims-vgpu](https://github.com/steelbrain/reims-vgpu)，[wiki](https://github.com/steelbrain/reims-vgpu/wiki))。它的验证面很窄：arm64 guest 在 Apple M3 Max 上测了 macOS 13/14/15/26，x86-64 guest 只在一块 NVIDIA RTX 5080 笔记本显卡上测了 macOS 26。宿主要求 `/dev/kvm`、Vulkan 1.2 以上驱动、`/dev/udmabuf` 访问权限（缺失时高分辨率会崩溃）和 memfd 共享的 guest 内存，已知的坑包括：x86-64 guest 必须在恢复模式里一次性设置 `METAL_ERROR_MODE=5`，否则图标服务崩溃、Dock 可能不出现；Fn/Globe 键无法传入；没有 HDR；关闭显示窗口会让虚拟机断电。`qemus/qemu-macos` 提供了打包好的 Docker 镜像，Docker Hub 上显示约一个月前更新，是目前门槛最低的试用入口 ([Docker Hub](https://hub.docker.com/r/qemux/qemu-macos)，[qemus/qemu-macos](https://github.com/qemus/qemu-macos))。AMD-OSX 论坛上作者 2026-09-14 的首发帖则称「翻译引擎仍然很慢」，当时标的是 alpha，测的是 Sonoma 加 RTX 2080 Ti，无人回帖 ([AMD-OSX](https://forum.amd-osx.com/threads/reims-vgpu-graphics-paravirtualization-for-macos.6616/))。

第二个实现是 Matthew Jackson 的 **libapplegfx-vulkan**（MIT，986 次提交，10 颗星），按「洁净室」方式重写协议：解码每流 FIFO、遍历每任务三级基数页表、把 Metal 命令流翻译成 Vulkan，并自带 AIR 到 SPIR-V 翻译器 ([libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan))。其里程碑清单显示在 2026-05-18 于 lavapipe（CPU 版 Vulkan）上渲染出第一个像素，但 95 个 Render 操作码只接通了约 10 个，也就是说它距离「桌面可用」还很远，更适合当作协议参考与交叉验证的备份。第三个实现是 nassosyian 的 `ultimate-macOS-KVM` 的 `pvg-metal-vulkan` 分支：QEMU 设备 `pvg-linux-pci`，Vulkan 1.3 回放 guest 命令缓冲，自带 `air2spv`，在一台 RTX 3060 Ti 的 Linux 机器上测得 **约 25 到 29 帧每秒的呈现速率**，桌面、Liquid Glass、Safari、地图、照片、SceneKit 3D 可用；不支持 argument buffer，部分特效不绘制，Blender 4.x 启动即崩；README 也声明该项目由 AI 模型编写 ([ultimate-macOS-KVM](https://github.com/nassosyian/ultimate-macOS-KVM)，[pvg 分支 README](https://github.com/nassosyian/ultimate-macOS-KVM/blob/pvg-metal-vulkan/pvg-metal-vulkan/README.md))。三个项目互相独立却共享同一个设计（Apple 的 PCI ID、官方 kext、Metal 到 Vulkan），这本身是一个信号：协议层面可行，且不是一个人的幻觉。

难点集中在着色器与 Metal 语义的翻译。guest 自带的 Metal 编译器产出 AIR 位码，宿主必须把它翻译成 SPIR-V；metal2vulkan 声称支持 compute、render、tessellation、tile 和 mesh 管线，需要 Vulkan 1.2 设备，遇到不支持的输入会明确拒绝，但它没有列出任何经过测试的驱动，并自己承认 `spirv-val` 通过不等于语义与 Metal 等价 ([metal2vulkan](https://github.com/steelbrain/metal2vulkan))。tile 着色器、argument buffer、间接命令缓冲这类 Metal 特性是最容易在 Vulkan 上出问题的部分，这从 pvg 分支「无 argument buffer」的限制中已能看到端倪。

## 所有路线的证据强度、风险与工作量

下表把用户问到的各条路线摆在一起。证据强度按「是否有第三方复现、是否在相近硬件上测过」分级；工作量是笔者对一个熟悉 Linux/QEMU 的个人开发者的判断，没有可引用的来源。

| 路线 | 能否「只模拟显卡」拿到 Metal | 证据强度 | 主要风险 | 工作量（人月，判断） |
|---|---|---|---|---|
| A. Reims 宿主侧复刻 Apple 半虚拟显卡 + anv | 是，guest 用官方 kext | 中偏低：Beta，仅 NVIDIA 上自测，无第三方复现 ([reims-vgpu](https://github.com/steelbrain/reims-vgpu)) | Iris Xe 零验证；单维护者；约 25 到 30 帧；着色器翻译缺口 | 验证 0.1 到 0.2；排查并修复 Intel 特有问题 1 到 3 |
| B. libapplegfx-vulkan | 是 | 低：仅 lavapipe，约 10 个渲染操作码 ([libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan)) | 功能严重不全 | 作为 A 的备份，不单独投入 |
| C. pvg-metal-vulkan | 是 | 中偏低：单台 RTX 3060 Ti，有帧率实测 ([README](https://github.com/nassosyian/ultimate-macOS-KVM/blob/pvg-metal-vulkan/pvg-metal-vulkan/README.md)) | AI 编写、实验性、GPL-3.0、无 argument buffer | 同 A，可并行试用 |
| D. 软件渲染兜底（vmware-svga / OVMF GOP） | 否，无 Metal 加速 | 中：长期惯用，但无 Tahoe 的量化数据 ([OSX-KVM notes](https://github.com/kholia/OSX-KVM/blob/master/notes.md)) | Tahoe 偏卡，Liquid Glass 吃 CPU | 0.5 到 1 |
| E. Iris Xe 原生 / 伪装 / 自制 Xe kext | 理论上是 | 证伪或无证据 ([Dortania](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/intel-gpu.html)) | 无命令提交、无 Metal | 不设上限 |
| F. GVT-g / SR-IOV / iGPU 直通 | 否 | 证伪（macOS 无 Xe 驱动） | guest 无驱动 | 不可行 |
| G. 自写 virtio-gpu 的 macOS 3D 驱动 | 否，现有 kext 仅 2D alpha ([virtio-gpu-macos](https://github.com/litecreator/virtio-gpu-macos)) | 现成仅 2D | 需整套 IOAccelerator、IOFramebuffer 与 Metal 插件，并放宽 SIP/AMFI | 6 到 12 以上 |
| H. 独立 AMD 显卡 VFIO 直通 | 是，但不是模拟显卡 | 低：Sequoia 上 RX 6600 XT 出现黑屏的报告 ([Proxmox 论坛](https://forum.proxmox.com/threads/macos-sequoia-rx-6600-xt-passthrough-boot-logo-black-screen.160854/)) | 笔记本无独显则无从谈起 | 1 到 2 加硬件 |
| I. 换 Mac 宿主跑 `apple-gfx-pci` | 是 | 高，但违背「Linux 极简宿主」目标 | 无 | 0.2 到 0.5 |

路线 G 值得多说一句：它在技术上有先例，NullMoth（NVIDIA）与 nullarc（AMD Radeon 780M）两个 2026 年的项目都给真实显卡做出了第三方 Metal 驱动，需要 IOAccelerator、IOFramebuffer、GPUBundles 里的 Metal 插件、AIR 到 SPIR-V 翻译，并放宽 SIP、AMFI 与安全启动 ([HOW-IT-WORKS](https://raw.githubusercontent.com/nullmoth/nvidia-macos-driver/master/docs/HOW-IT-WORKS.md)，[nullarc wiki](https://github.com/luuumi-dev/nullarc/wiki))。但这两个是物理 GPU 驱动，不是虚拟 GPU 驱动；对一台只想模拟显卡的 Iris Xe 机器来说，复用 Apple 自带的 `AppleParavirtGPU` 是同一功能的低成本版本，没有理由重做 guest 驱动。

## Iris Xe 上尚未被任何人验证：必须被当作未知而非「应该可以」

此处必须说得直白：**在全部四份调研记录覆盖的所有来源里，没有任何一条是 Intel Iris Xe（或任何 Intel/AMD 核显）运行 Reims、libapplegfx-vulkan 或 pvg-metal-vulkan 的测试报告。** Reims 的 x86-64 验证是一块 NVIDIA RTX 5080 笔记本显卡，pvg 分支是 RTX 3060 Ti（私有驱动），libapplegfx-vulkan 只测过 lavapipe，qemu-macos 与 metal2vulkan 的页面都没有提到 Intel、ANV 或 Mesa；唯一一个非 NVIDIA 的数据点是 Orchard 项目在 AMD Renoir 加 Mesa RADV 上跑 arm64 guest 的报告，它说明 Mesa 驱动不是天然的障碍，但路径和 Iris Xe 不同 ([Orchard wiki](https://github.com/yaelliethy/orchard/wiki))。「Mesa anv 支持 Vulkan 1.3，所以应该满足 Vulkan 1.2 以上」只是一个纸面推断：Collabora 的报道说明 ANV 是首批通过 Vulkan 1.4 一致性的 Mesa 驱动之一 ([Collabora](https://www.collabora.com/news-and-blog/news-and-events/nvk-now-supports-vulkan-14.html))，但这不等于 metal2vulkan 需要的特性（如曲面细分、descriptor indexing、buffer device address、64 位原子操作）在 anv 上全部可用、行为正确。

Iris Xe 与已验证的 NVIDIA 环境至少有三处结构性差异，每一处都可能是独立的失败点。第一，内存模型：Iris Xe 是与 CPU 共享系统内存的核显，Reims 依赖 memfd 与 `/dev/udmabuf` 把 guest 内存导入 Vulkan，该路径在 UMA 核显上的行为与独立显卡不同，笔者没有找到任何证据说明它能工作或不能工作。第二，驱动与特性画像：metal2vulkan 需要一个 Vulkan 设备画像 JSON，里面没有 anv 的条目，需要有人检查并编写。第三，性能：在 RTX 3060 Ti 上，pvg 分支就只有 25 到 29 帧，其 README 将瓶颈归于执行器管线延迟（命令缓冲在工作队列里等待 5 到 9 毫秒）而不是 GPU 算力，因此换成较慢的核显未必线性变慢，但这是笔者的推测，没有数据支撑。最后，Reims 的 x86-64 验证只列了 macOS 26，Sonoma 与 Sequoia 是否能用没有证据，因此对 MacBoot 来说应把 Tahoe 当作首选 guest，它同时也是 Intel 平台最后一个版本，反而意味着目标版本不会再变（但 Tahoe 的安全更新期限在来源中冲突：TidBITS 说两年，Six Colors 说三年 ([TidBITS](https://tidbits.com/2026/07/20/the-real-system-requirements-for-%EF%A3%BFos-27/)，[Six Colors](https://sixcolors.com/post/2025/06/macos-tahoe-is-the-last-release-to-support-intel/)))。另外要警惕一处细节：Reims wiki 里作者自己的测试宿主写成「macOS 27.0.1（build 26A434）」，版本字符串前后不一致，应对其 wiki 的数字保持审慎 ([wiki](https://github.com/steelbrain/reims-vgpu/wiki))。

PCI ID 方面，调研中的说法并不一致：一份二手摘要给出 Reims 使用的设备为 `106b:eeee`，pvg 分支 README 同样使用 `106b:eeee`，但用户简报中的 `106b:1b30` 在任何来源里都没有出现，应以真实 guest 中的 `lspci -nn` 或 Apple 框架头文件中的 `PG_PCI_DEVICE_ID` 为准，不要把它硬编码进 MacBoot。

## 下一步：先花几天验证，再决定是否并入 MacBoot

建议的顺序是先保底、再验证、最后集成。第一步，不要等待加速方案，直接让 MacBoot 的第一版用软件渲染兜底：QEMU 加 OVMF 加 OpenCore，用 vmware-svga 或 GOP 帧缓冲，1080p，关闭透明与动效。这个组合的好处是已被长期使用，缺点是 Tahoe 的 Liquid Glass 在无加速下偏卡，目前没有可引用的量化数据，AMD-OSX 论坛上有人明确说无加速时「Tahoe 尤其慢」([AMD-OSX](https://forum.amd-osx.com/goto/post?id=43666))。同时要先做一次基线检查：宿主 CPU 是否具备 Ventura 以后要求的 AVX2、是否有可用的 TSC，OSX-KVM 对此有说明 ([OSX-KVM](https://github.com/kholia/OSX-KVM))。

第二步，在这台 Iris Xe 机器上，用一个普通的 Linux 发行版而不是 MacBoot 的极简环境，运行 `qemux/qemu-macos` 镜像，guest 选 Tahoe。开始前先检查四件事：`/dev/kvm` 可访问，`vulkaninfo` 能列出 anv 设备且版本不低于 1.2，`/dev/udmabuf` 存在且当前用户可读写，Reims 的 `METAL_ERROR_MODE=5` 一次性设置按 wiki 完成。记录结果时分三档：能出桌面、能出桌面且 Metal 设备可用、Safari 或 Maps 等 Metal 应用可用，并保存 `vulkaninfo` 输出与 Reims 日志。如果失败，用 lavapipe 作对照（libapplegfx-vulkan 已在 lavapipe 上出过像素），把「Intel 专有问题」与「项目本身问题」分开；如果 Reims 失败，再并行尝试 pvg 分支。建议设一个时间盒，比如一周，到期仍无桌面，就把加速模式降级为「等待上游」而不是自己下场改。

第三步，只有验证通过，才把它作为 MacBoot 的可选「加速模式」集成进去：默认仍走软件渲染，加速模式用开关启用，这样任何一次 Reims 更新、macOS 小版本变化或 anv 的回归都不会让整机变砖。第四步，无论成败，都应把结果回报给上游（在 Reims 仓库开 issue 附上 anv 数据）：这将是公开记录中第一个 Intel 数据点，也能换来维护者对 anv 画像的帮助。

法律上，Apple 的 macOS 许可只授权「单台 Apple 品牌电脑」，并允许在已运行 macOS 的 Apple 品牌电脑上再装最多两个虚拟实例；协议另有禁止逆向工程的条款。需要说明，调研取到的是一份点名 Sequoia 的 PDF，Tahoe 版本措辞可能不同 ([Apple SLA](https://www.apple.com/legal/sla/docs/macOSTahoe.pdf))。在 Intel Linux 宿主上运行 macOS 违反「Apple 品牌」条款，这一点对本报告所有路线都成立；现有项目的做法是不再分发 Apple 二进制，而由用户从自己的 guest 里取出 `AppleParavirtEFI.rom`、通过脚本下载恢复镜像，MacBoot 如果要对外发布，应沿用同一原则，并自行向法律顾问确认，调研并不提供法律意见。

## 结论

这项调研改变的最大判断是：问题不在「Iris Xe 有没有 macOS 驱动」，这个答案很早就是否定的，而在「Linux 宿主侧复刻 Apple 半虚拟显卡的开源项目能否把 Iris Xe 当作 Vulkan 后端」，这个问题的答案此刻仍然是「没人知道」。三个独立项目在 2026 年相继出现，说明协议层面已被逆向到可用，Iris Xe 反而因为 Tahoe 是最后一个 Intel 版本、目标不再移动而成为一个相对稳定的验证对象。

对 MacBoot 而言，这意味着风险可以被切成两半：软件渲染保证第一版今天就能交付，Reims 的 Iris Xe 验证是一个几天量级的低成本实验，两者互不阻塞。即使实验成功，现实预期也应是「桌面可用、约 25 到 30 帧、部分 Metal 特性缺失」，而不是游戏或专业应用级别的加速；若失败，也只损失几天，并换来一个对社区有价值的公开数据点。
