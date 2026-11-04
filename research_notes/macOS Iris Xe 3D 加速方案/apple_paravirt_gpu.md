# Apple paravirtualized GPU (ParavirtualizedGraphics / AppleParavirtGPU) with a Linux KVM/QEMU host on Intel Iris Xe

Research date: 2026-11-04. Method: web search plus page fetches (about 16 tool calls). Several primary sources were blocked (lore.kernel.org 403, qemu.org docs 404, Phoronix 403, patchwork Anubis block, damoang.net 403). Some details below come from search-tool summaries or from fetch-tool summaries of pages, not from raw page text. These are flagged "secondary". Page-fetch summaries did not show commit dates for any GitHub repo, so "last activity" is mostly unverified.

## 1. Guest side: how it works, PCI IDs, MMIO variant, macOS versions, x86_64 vs arm64

### Takeaway
Apple's framework is a host-side black box that talks to a stock guest driver (AppleParavirtGPU.kext) shipped in macOS 11 and later. The guest sees a PCI device (x86_64) or an MMIO device (arm64 VMApple). The same guest driver is reported to work for x86-64 guests (QEMU PCI variant, macOS 11+ per the QEMU authors; macOS 26 confirmed by Reims), but the ID "106b:1b30" in the brief was not verified. One secondary source says 106b:eeee.

### Cited Findings
- Apple documents the framework as "hardware-accelerated graphics for macOS running in a virtual machine". The OS ships a graphics driver in the guest that talks to the framework in the host OS to get Metal acceleration. The VM app must (1) advertise the virtual graphics card in the VM hardware, (2) create a PGDeviceDescriptor/PGDevice with blocks the framework calls for memory operations, and (3) create a PGDisplayDescriptor/PGDisplay per display. — [Apple docs](https://developer.apple.com/tutorials/data/documentation/paravirtualizedgraphics.md)
- Apple exposes the PCI identity as constants `PG_PCI_VENDOR_ID`, `PG_PCI_DEVICE_ID`, `PG_PCI_BAR_MMIO`, `PG_PCI_MAX_MSI_VECTORS`, and `PGCopyOptionROMURL()` (an option ROM for the guest graphics device). The numeric values are not printed in that page. — [Apple docs](https://developer.apple.com/tutorials/data/documentation/paravirtualizedgraphics.md)
- QEMU's apple-gfx-pci sets vendor/device IDs from `PG_PCI_VENDOR_ID`/`PG_PCI_DEVICE_ID` and uses class "other display controller", so QEMU does not hardcode them. — [QEMU source mirror](https://qemu.googlesource.com/qemu/+/fb89ceac92012d154f1113190e24e45a42f396fc/hw/display/apple-gfx-pci.m) (via search summary)
- Apple's PCI vendor ID is 0x106b. — [FRET-qemu pci ids commit](https://git.cs.tu-dortmund.de/SYS-OSS/FRET-qemu/commit/4ebcf884836887324848291032a385fe0df7b0af) (via search summary)
- One search summary of the Reims wiki says its x86-64 path is "q35 through OpenCore, PCI apple-gfx-pci (106b:eeee) with its option ROM". This is a secondary summary, and I could not fetch the underlying table. — [reims-vgpu wiki](https://github.com/steelbrain/reims-vgpu/wiki)
- Guest driver is in-box from macOS 11 on: Parallels KB says Paravirtualized Graphics was introduced in Big Sur 11.0 and both host and VM need Big Sur or later (Intel Macs). — [Parallels KB](https://kb.parallels.com/en/124095)
- QEMU cover letter (v5, Oct 2024): apple-gfx "mainly targets x86-64 macOS guests from version 11 on"; the PCI variant provides 3D acceleration and GPGPU with a baseline Metal feature set regardless of host GPU; a UEFI bootrom provides basic framebuffer mode. The MMIO variant (apple-gfx-mmio) replicates the Virtualization.framework arm64 device and is required for the `vmapple` machine type. — [patchew v5 cover](https://patchew.org/QEMU/20241029205819.69888-1-phil@philjordan.eu/)
- Reims project reports using the stock `AppleParavirtGPU.kext` in the guest with no custom guest driver for the GPU itself; it ships only a small `ReimsVgpu.kext` in the OpenCore image (purpose of that kext not stated in what I read). — [Docker Hub qemux/qemu-macos](https://hub.docker.com/r/qemux/qemu-macos); [reims-vgpu repo](https://github.com/steelbrain/reims-vgpu)
- Reims reports x86-64 guests tested on macOS 26 (Tahoe) only; arm64 guests on 13, 14, 15, 26. — [reims-vgpu repo](https://github.com/steelbrain/reims-vgpu)
- MMIO/arm64 variant: Apple's headers only cover the PCI variant, so QEMU needed extra declarations for MMIO. — [apple-gfx-mmio commit page via search](https://git.cs.tu-dortmund.de/SYS-OSS/FRET-qemu/commit/2352159c97a1fd245e998daafa08fcaaf57d4fa8) (secondary summary)
- The libapplegfx-vulkan README states PCI/MSI details: all stamp and pending interrupts use MSI vector 0; a pending-displays bitmask where the bit is the display index (0-7). — [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan)

### Inferences
- Because the same in-box kext serves Virtualization.framework (arm64 and, historically, Intel Mac VMs) and the QEMU PCI device, the x86_64 guest path is a supported configuration on Apple's side up to the last Intel macOS (Tahoe 26 is the last release with Intel support, from my background knowledge, not verified in this research). Reims' x86 test on macOS 26 supports that.
- Whether Sonoma/Sequoia x86_64 guests work on the Linux-host stacks is untested in the sources I found (Reims lists only macOS 26 for x86-64; mos-docker mentions Sequoia).

### Gaps
- The exact PCI IDs: "1b30" appears nowhere in my sources; "eeee" comes from a secondary summary. Check `PG_PCI_DEVICE_ID` in a Mac's ParavirtualizedGraphics.framework headers, or `lspci -nn` in a running QEMU guest.
- The guest wire protocol is not documented by Apple; what is known comes from clean-room reverse engineering (section 3/4).
- No source on the kext's exact bundle layout, dependencies or macOS-version-specific behaviour.

## 2. QEMU apple-gfx-pci / apple-gfx-mmio: requirements, versions, limitations

### Takeaway
Upstream QEMU (10.0, April 2025) devices apple-gfx-pci and apple-gfx-mmio only work on macOS hosts because they call Apple's closed-source ParavirtualizedGraphics.framework and Metal. They are useless on Linux unless the framework is replaced by a third-party reimplementation.

### Cited Findings
- QEMU 10.0 (released 22 April 2025) added the two Apple graphics devices; coverage says they work only with a macOS host. — [Phoronix coverage via search results](https://www.phoronix.com/news/QEMU-10.0-Released) (page itself returned 403; this is secondary)
- Cover letter: "macOS 11 is also required on the host side, as well as a GPU that supports the Metal API." — [patchew v5 cover](https://patchew.org/QEMU/20241029205819.69888-1-phil@philjordan.eu/)
- Limitations from the cover letter: x86-64 guests on arm64 hosts boot partway but render corrupted; only one display supported; no state serialization (migration blocker set); guest framebuffer is copied to system memory and drawn with CPU-based QEMU drawing. vmapple: macOS 13+ guests failed early boot at that time (only macOS 12 worked), needs hvf on an arm64 macOS host, legacy IRQs make USB input laggy. — [patchew v5 cover](https://patchew.org/QEMU/20241029205819.69888-1-phil@philjordan.eu/)
- Source facts: the device picks a Metal device via `MTLCopyAllDevices()` (prefers unified memory / non-removable), uses `PGNewDeviceWithDescriptor`, and sets callbacks `createTask`, `destroyTask`, `mapMemory`, `unmapMemory`, `readMemory`. Display serial numbers must be unique or the guest ignores the display. Default modes 1920x1080, 1440x1080, 1280x1024 @60. — [QEMU apple-gfx.m](https://raw.githubusercontent.com/qemu/qemu/master/hw/display/apple-gfx.m)
- The vmapple limitation list is old (Oct 2024); Reims later reports arm64 guests on macOS 13/14/15/26 working (with its own QEMU fork). — [reims-vgpu repo](https://github.com/steelbrain/reims-vgpu)
- Task-memory callbacks mean the host must map guest RAM for GPU access; Reims requires shared memfd-backed guest RAM for the Linux path. — [Docker Hub qemux/qemu-macos](https://hub.docker.com/r/qemux/qemu-macos)

### Inferences
- The "task" memory-callback design (guest RAM mapped into the host GPU process) is what a Linux reimplementation must reproduce; hence memfd/udmabuf requirements on Linux.

### Gaps
- Official QEMU doc page (docs/system/devices/apple-gfx) could not be fetched (404 on both attempted URLs); release-note text not read first-hand.
- No data on QEMU 10.1/10.2/11 changes to apple-gfx. (mos-qemu is based on 10.2.2 per libapplegfx-vulkan README, which suggests 10.2.x exists.)

## 3. Has anyone reimplemented the host side on Linux? Status as of late 2026

### Takeaway
Yes, at least two independent efforts exist. Reims (steelbrain/reims-vgpu) is the most mature: beta, 3,395 commits, x86-64 macOS 26 guests on a Linux/KVM/Vulkan host reported working on an NVIDIA RTX 5080 laptop. libapplegfx-vulkan (MattJackson) is a smaller clean-room library, proven to render triangle-class content on lavapipe (CPU Vulkan) with only part of the Render opcodes wired. Neither mentions Intel Iris Xe or Mesa anv testing.

### Cited Findings
**Reims (steelbrain/reims-vgpu)**
- Described as an "experimental virtual GPU for macOS guests", Beta, "has largely stabilized", gives macOS VMs accelerated graphics via Metal on Mac or Vulkan on Linux; no guest driver install. — [reims-vgpu wiki](https://github.com/steelbrain/reims-vgpu/wiki); [repo](https://github.com/steelbrain/reims-vgpu)
- Stats at fetch time: 3,395 commits, 660 stars, 83 forks, 24 open issues, 34 open PRs. License: GPL-2.0-or-later OR LGPL-3.0-or-later. Maintainer: owner steelbrain (no further identity found). Last commit date not shown. — [repo](https://github.com/steelbrain/reims-vgpu)
- Three paths: x86-64 macOS on Linux/KVM (QEMU q35 + OpenCore + PCI apple-gfx-pci + Vulkan via metal2vulkan); arm64 macOS on Apple silicon with HVF and Metal; arm64 on Apple silicon with Vulkan through MoltenVK. Core lib in Rust (`crates/`), C API `reims_vgpu.h`, QEMU fork in `vendor/qemu`, UEFI option ROM, `reims-ctl` tool. — [wiki](https://github.com/steelbrain/reims-vgpu/wiki)
- Tested hardware: Apple M3 Max (arm64 guests), NVIDIA RTX 5080 laptop GPU on Linux (x86-64 guests). Linux needs `/dev/kvm`, a Vulkan driver (Vulkan 1.2+ per Docker listing), access to `/dev/udmabuf` (otherwise crashes at higher resolution), shared memfd guest RAM. — [wiki](https://github.com/steelbrain/reims-vgpu/wiki); [Docker Hub](https://hub.docker.com/r/qemux/qemu-macos)
- Known limitations: Fn/Globe key not delivered, no HDR, behaviour varies by host/GPU driver, x86-64 guests need a one-time Metal error-mode setting (`METAL_ERROR_MODE=5`) done via Recovery/OpenCore picker or the icon service crashes and the desktop may not appear, closing the display window powers off the VM. — [wiki](https://github.com/steelbrain/reims-vgpu/wiki); [repo](https://github.com/steelbrain/reims-vgpu)
- A Docker image (qemux/qemu-macos) packages a Reims-enabled QEMU build; "last updated about 1 month ago" relative to a pulls figure for Oct 19-25 (so roughly Sept-Oct 2026); marked "Sponsored OSS". — [Docker Hub](https://hub.docker.com/r/qemux/qemu-macos)
- Intel/AMD iGPU: no mention on the Reims wiki or repo page. — [repo](https://github.com/steelbrain/reims-vgpu)

**libapplegfx-vulkan (MattJackson)**
- Linux clean-room reimplementation of the ParavirtualizedGraphics host side with a Vulkan backend, public C API prefix `lagfx_*`. It decodes the paravirt wire protocol, walks per-task radix page tables, translates Metal command streams to Vulkan, renders via Mesa lavapipe or any Vulkan ICD. License MIT (relicensed from AGPL-3.0 on 2026-07-19 by the sole copyright holder). 986 commits, 10 stars, 2 forks. — [GitHub](https://github.com/MattJackson/libapplegfx-vulkan)
- Milestones: M1 kext attaches (2026-04-21), M2 IOAccelerator class tree visible (2026-04-21), M3 `MTLCreateSystemDefaultDevice()` returns non-nil (2026-05-03), M4 CmdExecIndirect2 parsing + 3-level radix VA-to-GPA translation (2026-04-26), M5 first visible pixel via Vulkan/lavapipe (2026-05-18). Claimed ~99.7% frame coverage with real guest geometry and translated vertex+fragment shaders on lavapipe. Only ~10 of 95 Render opcodes wired; Compute (32 opcodes) and Blit (24 opcodes) decoders exist with tests. — [GitHub](https://github.com/MattJackson/libapplegfx-vulkan)
- Consumers: mos-qemu (QEMU 10.2.2 fork, device `apple-gfx-pci-linux`) and mos-docker (OpenCore 1.0.7); in mos-docker the Apple paravirt GPU is opt-in (`MOS_USE_APPLE_GFX_PCI=1`), default display is `-vga std`; mos-docker names macOS Sequoia. — [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan); [mos-docker](https://github.com/MattJackson/mos-docker)
- Maintainer: Matthew Jackson (Olympia, WA; works on GetBusbar). — [GitHub profile](https://github.com/MattJackson)
- Intel GPU: not mentioned; only lavapipe tested. — [GitHub](https://github.com/MattJackson/libapplegfx-vulkan)

**Orchard (yaelliethy/orchard)**
- Boots arm64 macOS 13 under QEMU/TCG on x86-64 Linux with Reims as the GPU; tested on AMD Renoir with Mesa RADV; 108 stars, 22 forks, 6 commits. LGPL-3.0 for the reims-vgpu part. Not relevant to x86 guests but shows Mesa RADV works as a Vulkan backend. — [orchard wiki](https://github.com/yaelliethy/orchard/wiki)

**Not relevant**
- litecreator/virtio-gpu-macos: a macOS guest virtio-gpu IOKit driver, alpha, 2D framebuffer only, 3D (Virgl) not implemented; README last updated 2024-04-07. — [GitHub](https://github.com/litecreator/virtio-gpu-macos)
- A Korean forum post repeating Reims claims (60+ fps in macOS 13) was seen only in a search summary; not verified. — [damoang.net](https://damoang.net/free/6818549)

### Inferences
- Reims is the practical starting point; libapplegfx-vulkan is a second, less complete implementation (and a possible fallback or cross-check). They are not clearly related, but mos-docs/reims both claim "stock kext" operation.
- Both projects appear to have developed rapidly in 2026 (commit counts of ~1,000 and ~3,400). Activity dates were not retrievable, so "alive" is inferred from Docker Hub "updated ~1 month ago" and 2026 milestone dates.
- Intel Iris Xe via anv should satisfy "Vulkan 1.2+" (anv on Tiger Lake and later supports Vulkan 1.3/1.4 from my background knowledge), but nothing tested.

### Gaps
- No Intel (any generation) test report from any of these projects. The HN/Reddit/tonymacx86/InsanelyMac searches returned nothing in this pass (I did not search those forums directly beyond the general queries).
- Last-commit dates for all repos were not retrievable.
- No independent verification of the "99.7% frame coverage", "60 fps", or "working x86-64 macOS 26" claims; all are project self-reports.
- Unknown how well real apps (WindowServer compositing, Safari, Metal apps) perform.

## 4. Protocol details publicly known; the hard part (Metal shaders)

### Takeaway
Apple's public API surface is small (PGDevice/PGDisplay + memory callbacks); the actual guest-to-host command protocol is undocumented and has been reverse-engineered by clean-room projects (opcode catalogs, ring/stamp mechanism, radix page tables). The hard part is translating the guest's compiled Metal shaders (AIR bitcode in metallibs) to SPIR-V and mapping Metal semantics (tile, mesh, tessellation, argument buffers, heaps) onto Vulkan.

### Cited Findings
- Public API: PGDeviceDescriptor with blocks for task create/destroy/map/unmap/read, PGDisplay with frame/mode/cursor events; frames encoded to a Metal texture with `encodeCurrentFrameToCommandBuffer:texture:region:`. — [QEMU apple-gfx.m](https://raw.githubusercontent.com/qemu/qemu/master/hw/display/apple-gfx.m); [Apple docs](https://developer.apple.com/tutorials/data/documentation/paravirtualizedgraphics.md)
- Reverse-engineered wire-protocol facts (libapplegfx-vulkan README): per-stream FIFOs; Render (95 opcodes), Compute (32), Blit (24) command sets; `CmdExecIndirect2`; per-task 3-level radix page table (VA to guest physical); stamps (monotonic, never write 0) with ack/ring-wrap behaviour; a stock-shader catalog in MSL plus precompiled .spv. Detailed whitepapers are "in mos-docs, not yet published". — [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan)
- Shader approach A (libapplegfx-vulkan): clean-room AIR to SPIR-V translator in `src/air2spirv/` (MIT). — [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan)
- Shader approach B (Reims): the `metal2vulkan` project (steelbrain, Rust, beta, 306 stars, 987 commits, GPL-2.0+/LGPL-3.0+) converts metallib containers, AIR bitcode or LLVM `.ll` to SPIR-V per stage; supports compute, render, tessellation, tile and mesh pipelines; runtime on Vulkan 1.2 (via `ash`) covering devices, queues, buffers, textures, heaps, events; unsupported input is refused with a typed error naming the Metal feature (docs/REFUSALS.md, not read). Needs a Vulkan 1.2 device profile JSON. Tested drivers are not listed on its main page; it notes `spirv-val` passing does not prove semantic equivalence with Metal. — [metal2vulkan](https://github.com/steelbrain/metal2vulkan)
- On non-Mac hosts Reims uses precommitted metallibs for its own internal shaders (verified by sha256); Apple's compiler is needed to produce them, which is why they are checked in. — [reims wiki](https://github.com/steelbrain/reims-vgpu/wiki)
- Related but different: joshuaswarren/metal2vk compiles MSL compute source to SPIR-V (MIT, ~61 stars); it does not handle AIR, so it is not usable for guest-compiled shaders. — [metal2vk via search](https://github.com/joshuaswarren/metal2vk/wiki)
- MoltenVK is the opposite direction (Vulkan on Metal) and is cited as precedent. — [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan)

### Inferences
- The guest compiles MSL to AIR in-guest (the Metal compiler runs in the guest) and sends AIR/metallib to the host, which is why AIR to SPIR-V is needed on non-Apple hosts. Both Linux projects' architectures match this; no source states the mechanism outright.
- Hardest items: tile shaders / imageblocks, argument buffers, tessellation, indirect command buffers, MSL address-space semantics, and Apple's baseline Metal feature set expectations in WindowServer/CoreAnimation. Mesa anv supports mesh shaders and Vulkan 1.3 features, which helps, but nothing here tests that.

### Gaps
- Full opcode/field layouts are unpublished (whitepapers unpublished); only source code is available.
- No data on which AIR constructs metal2vulkan refuses (docs/REFUSALS.md not read).
- No performance numbers for any Linux-host implementation.

## 5. Guest-side Apple-hardware checks (VMM flag, SMBIOS, board-id, SIP/AMFI) under QEMU/KVM + OpenCore

### Takeaway
No source documents hard Apple-hardware checks that block the in-box driver under QEMU. Working setups use q35 + OpenCore. Beyond that, nothing is stated, so this question remains largely open.

### Cited Findings
- Reims x86-64 recipe: QEMU q35 behind OpenCore; `reims-ctl` builds OpenCore image and disk, or the user supplies one with `--opencore` (which keeps its Mac identity); a small ReimsVgpu.kext is in the image. The README does not discuss SMBIOS, SIP/AMFI or boot-args. — [reims-vgpu repo](https://github.com/steelbrain/reims-vgpu)
- The only guest-config requirement stated for x86-64: set `METAL_ERROR_MODE=5` once, else the icon service crashes. — [reims-vgpu repo](https://github.com/steelbrain/reims-vgpu)
- mos-docker uses QEMU + OpenCore; mos-patcher is a Lilu-style kernel-hook framework (per-instance vtable swap on Sequoia). Its README does not discuss SMBIOS etc. for the paravirt GPU. — [mos-docker](https://github.com/MattJackson/mos-docker); [MattJackson profile](https://github.com/MattJackson)
- The QEMU code sets no minimum macOS version and does no OS check on the host side; guest-side gating is not covered. — [QEMU apple-gfx.m](https://raw.githubusercontent.com/qemu/qemu/master/hw/display/apple-gfx.m)
- Licensing: Apple's license permits macOS virtualization only on Apple-branded hardware; a Linux/Intel host does not satisfy it. — [orchard wiki](https://github.com/yaelliethy/orchard/wiki) (secondary statement; check the macOS SLA directly)

### Inferences
- Given that Reims boots macOS 26 on q35+OpenCore with the in-box kext and an RTX 5080 host, the kext binds without a real Mac SMBIOS beyond what OpenCore presents. Whether the hypervisor CPUID bit, `vmx` flag, or board-id matter was not tested in any source I read. In practice for hackintosh VMs the usual OpenCore settings (e.g. a macOS-model SMBIOS, `-no_compat_check`, SIP configuration) apply, but I have no source linking them to AppleParavirtGPU.
- AMFI/SIP likely matter only for the custom kexts (ReimsVgpu.kext, Lilu/mos-patcher), not for the in-box kext. This is inference.

### Gaps
- No source on VMM-flag/board-id/model-gating specific to AppleParavirtGPU.
- No Sonoma or Sequoia x86 test report for Reims; mos-docker mentions Sequoia but its GPU path is opt-in and lavapipe-only.

## 6. Effort estimate and risks for a hobbyist/small team on Intel Iris Xe via Mesa/Vulkan

### Takeaway
Do not reimplement from scratch: adopt Reims (or libapplegfx-vulkan) and test on Iris Xe. Expected effort is days to a few weeks for bring-up and driver-specific bug fixes, versus many person-months for a new host implementation. These estimates are my judgment, not sourced.

### Cited Findings
- Reims exposes a Vulkan 1.2+ requirement and notes "behavior varies with host platform and GPU driver"; it also asks for `/dev/udmabuf`, memfd-backed RAM and KVM. — [Docker Hub](https://hub.docker.com/r/qemux/qemu-macos); [reims-vgpu repo](https://github.com/steelbrain/reims-vgpu)
- Reims's x86 Linux validation is a single discrete NVIDIA laptop GPU; the Orchard project validated the arm64 path on AMD RADV. No iGPU/ANV report. — [reims-vgpu wiki](https://github.com/steelbrain/reims-vgpu/wiki); [orchard wiki](https://github.com/yaelliethy/orchard/wiki)
- libapplegfx-vulkan has had only lavapipe testing with ~10 of 95 render opcodes wired. — [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan)
- Both Linux-host stacks use project-specific QEMU forks (vendor/qemu in Reims; mos-qemu on 10.2.2) rather than upstream QEMU. — [reims-vgpu](https://github.com/steelbrain/reims-vgpu); [libapplegfx-vulkan](https://github.com/MattJackson/libapplegfx-vulkan)

### Inferences
- Likely work items on Iris Xe: (1) build and run Reims reference setup; (2) check anv exposes the Vulkan features metal2vulkan's device profile needs (tessellation, mesh, descriptor indexing, buffer device address, 64-bit atomics, etc.), and write an anv profile JSON; (3) debug shader-translation or driver quirks on a unified-memory iGPU (udmabuf/dma-buf import of guest RAM into Vulkan, `vm.max_map_count`); (4) tune performance (the display path copies frames; shared RAM with the CPU).
- Risks: young projects (all new in 2026), few contributors (bus factor, one primary maintainer each), copyleft/other licenses differ (Reims GPL/LGPL, libapplegfx MIT), partial Metal coverage may break specific apps, each macOS point release may change the guest driver/protocol, Tahoe 26 is the end of Intel macOS support (background knowledge), and the Apple EULA prohibits macOS on non-Apple hardware.
- Iris Xe has no discrete-GPU memory, so memory-import paths and tiling/modifiers may behave differently from the NVIDIA test setup. Not tested.

### Gaps
- No empirical Iris Xe data at all; the user should verify with a quick trial of Reims (Docker image qemux/qemu-macos is the lowest-effort route) before investing in anything.
- Performance expectations (fps, WindowServer smoothness) unknown.
- Not searched in depth: tonymacx86, InsanelyMac, Reddit, Hacker News reports (general searches surfaced none).
