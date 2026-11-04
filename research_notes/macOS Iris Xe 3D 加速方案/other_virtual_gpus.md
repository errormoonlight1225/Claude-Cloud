# Non-Apple-PV virtual GPU options for macOS guests (and feasibility of a new guest GPU driver) on Linux/KVM + Intel Iris Xe

Research date: 2026-11-04. Scope: x86_64 macOS guests, Sonoma to Tahoe 26. Host: Linux KVM/QEMU, Intel Iris Xe iGPU.
Method note: web pages were read via a fetch tool that summarises pages with a small model, so quotes/numbers are as relayed by it. GitHub READMEs are self-reported by their authors and I did not build or run any of this code. "Inference" sections are mine.

Big-picture caveat for the report writer: the only credible 3D path found for a macOS guest on Linux/KVM is NOT a new guest driver. It is a host-side re-implementation of Apple's paravirtual GPU device ("apple-gfx" / `AppleParavirtGPU.kext`) that translates Metal to Vulkan (reims-vgpu). That is technically "Apple-PV-protocol" and is probably covered by another researcher, but it is the answer to "which non-VMware/non-Apple-host option exists", so it is included here. Every other non-Apple-PV option I checked gives the guest no 3D at all.

---

## 1. VMware SVGA3D / VMware Fusion / Workstation / QEMU vmware-svga

### Takeaway
VMware's SVGA3D is not what gives macOS guests 3D. VMware's own macOS-guest 3D (Fusion on Intel Macs) uses Apple's paravirtual GPU (`appleGPU0.present`), not SVGA3D, and the VMwareGfx kext in VMware Tools is a 2D driver. QEMU's `vmware-svga` implements no 3D at all, so there is no SVGA3D route for a macOS guest on Linux/KVM.

### Cited Findings
- VMware's KB for Metal 3D in macOS guests tells users to add `appleGPU0.present = "TRUE"` and `svga.present = "FALSE"` to the .vmx, i.e. it replaces the VMware SVGA device with Apple's paravirtual GPU. The KB (written for Big Sur) says OpenGL apps are not supported and only a subset of Metal is available in the VM, and warns of rendering crashes, guest panics and vmx crashes on some hardware. — [VMware KB 81657 (via search result)](https://kb.vmware.com/s/article/81657) (direct fetch of the Broadcom copy returned 404, so this is from a search-result summary)
- VMware Fusion docs: the macOS Tools ship a kernel extension `com.vmware.kext.VMwareGfx` that provides the VMware video driver; kexts are not loaded automatically on Big Sur+, user must approve "System Extension Blocked" prompts per kext and reboot. — [Fusion 12 docs](https://docs.vmware.com/en/VMware-Fusion/12/com.vmware.fusion.using.doc/GUID-FC74F5F1-ECC1-4C1C-AA25-7C9AF2DC2ADB.html) (seen in search snippet only)
- MacStadium: Tools are installed by mounting `darwin.iso` (extracted from the VMware Tools download) in the guest. — [MacStadium docs](https://docs.macstadium.com/docs/install-vmware-guest-tools)
- A third-party guide states the SVGA-only macOS setup gives "no accelerated 2D/3D graphics". Low-authority source, snippet only. — [sysnettechsolutions](https://sysnettechsolutions.com/en/install-vmware-tools-macos)
- A VMware employee in an old forum thread (undated in my fetch; page redirected) is quoted as saying Apple provides no driver API for third parties to build accelerated graphics, and that Apple's software 3D renderer remains available in the VM with limited performance. — [VMware Communities thread](https://communities.vmware.com/message/2673996) (relayed via search snippet; **old, pre-Big Sur**)
- Sequoia (2024): a Broadcom community user states the VMware SVGA adapter doesn't support 3D acceleration for macOS guests and suggests the Metal/appleGPU config. In the thread I fetched (Nov 20, 2024) the poster has "Accelerate 3D Graphics" ticked with 2048 MB and still gets "graphics configuration doesn't support hardware acceleration"; no resolution. — [Broadcom thread](https://community.broadcom.com/vmware-cloud-foundation/discussion/sequoia-graphics-configuration-not-supported)
- Fusion 13 on Intel: MacRumors report that Sonoma VMs got Apple paravirtual video working via two .vmx lines but the poster could not get it working on Sequoia; a Broadcom post shows an Intel Mac mini 2018 Sequoia 15.0 VM working with `appleGPU0.*` settings "only a few times". A Broadcom reply says macOS was dropped from Fusion 13's guest OS compatibility list, with little/no 3D support. — [MacRumors thread](https://forums.macrumors.com/threads/sequoia-as-virtual-machine-on-intel-fusion-or-parallels.2429074) and [Broadcom thread](https://community.broadcom.com/vmware-cloud-foundation/discussion/sequoia-graphics-configuration-not-supported-again) (search snippets; MacRumors page returned 403 on direct fetch)
- Fusion 13 requirements list only Monterey and Ventura as hosts; page lists no macOS guest support. Fusion also needs an Intel Mac host for eGPU. — [Broadcom KB 315608](https://knowledge.broadcom.com/external/article/315608)
- QEMU `hw/display/vmware_vga.c` (master): `SVGA_CAP_3D` is defined but the capabilities register only sets rect copy, rect fill and cursor bits; `SVGA_FIFO_3D_HWVERSION` is never read/written; surface/fence opcodes are no-ops; unknown opcodes are logged. So vmware-svga in QEMU is 2D-only. — [QEMU source](https://gitlab.com/qemu-project/qemu/-/raw/master/hw/display/vmware_vga.c)
- Practical QEMU use: OSX-KVM notes say switching to `vmware-svga` "fixed" a resolution problem on Ventura; an Unraid user used the VMware SVGA kext from darwin.iso for (experimental) 2D acceleration. No report found of any 3D via vmware-svga. — [OSX-KVM notes](https://gitea.wit.com/interesting/OSX-KVM/raw/branch/master/notes.md), [Unraid thread](https://forums.unraid.net/topic/99434-qemu-args/)
- Mesa has an open SVGA3D guest driver (Linux/Windows guests), but that is a guest driver for Linux; the host side (VMware's vmx) is closed. Mesa docs: [vmware-guest](https://grok.dragonflybsd.org/source/xref/dports/graphics/mesa-dri-classic/mesa-20.2.3/docs/vmware-guest.rst?a=true) (old copy, Mesa 20.2).

### Inferences
- A usable SVGA3D path would need three missing pieces: (a) a host-side SVGA3D renderer in QEMU (does not exist upstream), (b) a macOS guest SVGA3D driver (VMware ships none that exposes 3D for macOS; Apple has no public API to plug a 3D accelerator in), (c) a Metal/GL front end. Not realistic.
- Fusion's "3D for macOS" on Intel is really Apple PV GPU; on a non-Apple host it is irrelevant (Fusion needs a Mac host anyway; VMware does not run on Linux hosts with macOS guests officially).

### Gaps
- Could not retrieve the current Broadcom copy of KB 81657 (404) and so could not confirm whether it was revised for Sonoma/Sequoia/Tahoe.
- No Tahoe-guest-in-Fusion report found. No official statement that VMware Tools (darwin.iso) is still shipped/updated for Tahoe; not verified.
- Did not verify any source that mentions VMware-specific Mesa svga *host* usage outside VMware (Mesa's svga driver targets the guest; I found no standalone host-side use).

---

## 2. Parallels and VirtualBox

### Takeaway
Parallels' macOS-guest 3D (Big Sur+) is Apple's Paravirtualized Graphics framework driven by a Mac host plus Parallels Tools; it is closed and Mac-host-only. VirtualBox has no Guest Additions for macOS and no 3D for macOS guests; macOS guests are experimental and Mac-host-only.

### Cited Findings
- Parallels: no 2D/3D acceleration for OS X/macOS guests earlier than Big Sur; Metal needs macOS 11+ host and guest and Parallels Desktop 16+; mechanism is Apple's Paravirtualized Graphics framework (virtual GPU backed by the Mac's real GPU); install/update Parallels Tools to enable. OpenGL not mentioned. — [Parallels KB 124095](https://kb.parallels.com/en/124095), [KB 125105](https://kb.parallels.com/en/125105)
- Parallels forum reports of poor performance on Intel (Iris 550) and guest crashes with eGPU attached under Big Sur. Dated ~2020-2021. — [Parallels forum](https://forum.parallels.com/threads/metal-graphics-support-for-macos-big-sur-virtual-machines.351524/)
- VirtualBox 7.0 manual: macOS guests are an experimental feature (macOS hosts only), single CPU, 1024x768 default via EFI display; "Oracle VM VirtualBox does not provide Guest Additions for Mac OS X at this time"; 3D acceleration is only listed for Windows, Linux and Solaris guests. — [VirtualBox 7.0 Known Limitations](https://docs.oracle.com/en/virtualization/virtualbox/7.0/user/KnownIssues.html)

### Inferences
- Both are unusable as-is on a Linux/KVM host: Parallels is Mac-only and closed; VirtualBox gives no macOS guest driver to build on. Neither host side is documented or reproducible beyond the Apple PV protocol (which is what reims-vgpu reimplements, see section 4).

### Gaps
- No Parallels/VirtualBox source/driver documentation found; I did not verify whether VirtualBox 7.1/7.2 changed macOS-guest status (docs fetched were 7.0). Parallels Tahoe-guest-on-Intel status not checked (Parallels dropped Intel hosts in recent versions? Not verified).

---

## 3. virtio-gpu / VirGL / Venus / gfxstream / QXL / Intel GVT-g for macOS guests

### Takeaway
No working macOS guest driver exists for virtio-gpu, VirGL, Venus, gfxstream or QXL 3D. One alpha community kext implements virtio-gpu 2D framebuffer only. Intel GVT-g/SR-IOV do not list macOS guests and Iris Xe is not in GVT-g's supported range.

### Cited Findings
- `litecreator/virtio-gpu-macos` (author Marlon Hanks, MIT): self-described "Alpha - Core architecture complete, basic 2D framebuffer functional". Control command submission not fully implemented (`sendControlCommand()` doesn't DMA yet), no blob resources, no 3D/Metal/OpenGL; Virgl listed as planned; guests 10.15+; must be built on macOS; kext signing/SIP workarounds needed; README "last updated 2024-04-07"; 3 commits, 6 stars, 0 forks. — [GitHub](https://github.com/litecreator/virtio-gpu-macos)
- Stock macOS ships `AppleVirtIO.kext` (virtio-console/serial, blk, 9p) and `AppleVirtualGraphics.kext` matching QEMU stdvga (0x11111234) and cirrus (0x00001013) only; no virtio-gpu (2019 Mojave analysis, **old**). — [kraxel.org](https://www.kraxel.org/blog/2019/06/macos-qemu-guest/)
- QXL: Quickemu notes `qxl-vga` gives seamless mouse and sane default resolutions in macOS guests (display/input convenience, no 3D). QEMU issue shows QXL availability is build-dependent. — [quickemu commit](https://git.binarymagic.net/AIR/quickemu/commit/9b5a6a44acf2690952008cd5225d1911d5ae3b25), [QEMU issue 1284](https://gitlab.com/qemu-project/qemu/-/issues/1284)
- `RuriMeiko/macos-gpu-vm-lab` (2026): plans a macOS guest with virtio-gpu + Venus on Linux/KVM as the "main track" with VFIO passthrough as baseline; README says "early research. Nothing here is proven to work yet"; no Intel iGPU mention; PolyForm Noncommercial. — [GitHub](https://github.com/RuriMeiko/macos-gpu-vm-lab)
- `ericcurtin/vmmbox` PR #6 ("Vulkan GPU for macOS guests"): body is actually a Linux guest (Mesa Venus) on a Mac host via virglrenderer + KosmicKrisp; QEMU/virglrenderer patches not upstream; PR closed unmerged Nov 1, 2026. Title is misleading, not a macOS-guest driver. — [PR](https://github.com/ericcurtin/vmmbox/pull/6)
- Venus-on-macOS-host QEMU patches (RFC, Dec 2025) and UTM "Neptune" (D3D over virtio-gpu; Linux host/guest only for now) concern macOS *hosts*/Windows guests, not macOS guests. — [qemu-devel RFC](https://ratatoskr.run/qemu-devel/2025/12/14412636/t), [UTM Neptune](https://blog.getutm.app/2026/introducing-neptune-direct3d-virtualization-for-qemu/)
- QEMU virtio-gpu docs (guest drivers for Linux/Windows): [qemu.org](https://qemu.org/docs/master/system/devices/virtio-gpu.html). Venus: [Mesa docs](https://docs.mesa3d.org/drivers/venus).
- Intel GVT-g: legacy, Intel no longer accepts patches, supported for Gen 6th-10th only; Iris Xe (11th gen+) uses SR-IOV, which is out-of-tree and lists only Windows/Linux guests. — [Intel support article](https://www.intel.com/content/www/us/en/support/articles/000093216.html), [Arch wiki](https://wiki.archlinux.org/title/Intel_GVT-g)

### Inferences
- A virtio-gpu 3D path for macOS would need a guest Metal driver (see section 5); the existing kext only addresses the framebuffer layer, which is the easy part.
- Even if a vGPU slice of Iris Xe via SR-IOV existed, macOS has no driver for Tiger Lake/Alder Lake Xe graphics (not verified in this research; outside scope). Then the guest would be limited to framebuffer-only anyway.

### Gaps
- Did not find gfxstream-for-macOS-guest projects or any Venus macOS guest client; absence is from limited searching, not proof.
- virtio-gpu-macos repository activity beyond README date unverified; fetch showed no commit dates.
- No macOS-guest SR-IOV/GVT-g report found (searched once).

---

## 4. Host-side reimplementation of Apple's paravirtual GPU on Linux (reims-vgpu) - the only 3D path found

### Takeaway
reims-vgpu (2026, Beta, GPL-2.0+/LGPL-3.0+) lets stock macOS use `AppleParavirtGPU.kext` against a QEMU `apple-gfx-pci` device whose command stream is decoded on the Linux host and executed via Vulkan (metal2vulkan). x86-64 Tahoe guests are tested on KVM. Intel iGPU is untested/unmentioned but the Vulkan 1.2+ requirement is in principle within Iris Xe's reach.

### Cited Findings
- README: virtual GPU for macOS VMs, "accelerated graphics, through Metal on a Mac or Vulkan on Linux", no guest driver install. Status: Beta ("largely stabilized", performance depends on host/GPU). Tested: arm64 macOS 13/14/15/26 on M3 Max; x86-64 macOS 26 on Linux with an RTX 5080 laptop GPU. — [reims-vgpu README](https://github.com/steelbrain/reims-vgpu/blob/master/README.md)
- Linux x86-64 path: KVM, q35 + OpenCore, PCI `apple-gfx-pci` (106b:eeee) with option ROM, Vulkan via metal2vulkan; OpenCore image includes one small kext `ReimsVgpu.kext`; reims-vgpu replaces Apple's ParavirtualizedGraphics.framework; needs `/dev/udmabuf` (otherwise guest can crash at higher resolutions, even 4K desktop); optional `vm.max_map_count` for NVIDIA; one-time `METAL_ERROR_MODE=5` from Recovery or the icon service crashes; Dock icons may be blank; Fn/Globe keys don't reach the guest; no HDR; `reims-ctl` fetches the installer (13-20 GB). — [reims-vgpu wiki](https://github.com/steelbrain/reims-vgpu/wiki), README above
- Forum announcement (AMD-OSX, Sep 14, 2026): "alpha", Big Sur through Tahoe reportedly work, tested Sonoma guest on Linux x86 + RTX 2080 Ti; "translation engine is slow"; no replies; no Intel/AMD results. — [AMD-OSX forum](https://forum.amd-osx.com/threads/reims-vgpu-graphics-paravirtualization-for-macos.6616/). Note label mismatch (alpha vs README Beta) - likely due to project maturing.
- Forks/relatives: Windows 11/WHPX fork claims ~5-7 to ~93 fps on a Safari CSS animation (RTX 4060, macOS 13 guest) (self-reported); Orchard boots arm64 Ventura on QEMU/TCG on Linux with reims-vgpu. — [MAXZVER fork](https://github.com/MAXZVER/reims-vgpu), [Orchard wiki](https://github.com/yaelliethy/orchard/wiki)
- `qemus/qemu-macos` Docker image/repo packages QEMU with Reims for Linux/KVM hosts; requirements: KVM, Reims vGPU device, memfd-backed RAM, Vulkan 1.2+, Reims GOP ROM. — [Docker Hub](https://hub.docker.com/r/qemux/qemu-macos), [GitHub](https://github.com/qemus/qemu-macos)
- Upstream QEMU `apple-gfx-pci` (patch series v16) targets macOS *hosts* (needs host Metal GPU), x86-64 macOS guests supported there. — [patchew](https://patchew.org/QEMU/20241223221645.29911-1-phil@philjordan.eu/)

### Inferences
- Iris Xe on Linux uses Mesa ANV, which advertises Vulkan 1.3, so the "Vulkan 1.2+" requirement is plausibly met, but whether metal2vulkan's feature needs (argument buffers, descriptor indexing, sparse/format features, memory model) run correctly/performantly on ANV is unknown. Treat as untested; Iris Xe is a weak GPU and the translation overhead is described as slow even on RTX cards.
- Legal: Apple's macOS licence restricts virtualisation to Apple hardware (noted by Orchard); applies to the whole approach.
- Compared to writing an in-guest driver, this reuses Apple's own Metal stack in the guest, so Metal 3 features exposed are whatever AppleParavirtGPU/reims supports (not documented here).

### Gaps
- No Intel iGPU (Iris Xe/ANV) test reports found anywhere; no benchmarks beyond fork self-report.
- No third-party confirmation of reims-vgpu claims; no independent review/news found. Not verified: Sonoma/Sequoia x86-64 guests (README tests only Tahoe on x86-64; forum post claims Sonoma on 2080 Ti).

---

## 5. Feasibility of a new third-party macOS guest GPU driver exposing a Metal device

### Takeaway
Hard but demonstrably possible; two 2026 community projects ship Metal drivers for macOS on real GPUs, but they are invasive (SIP/AMFI/Secure Boot relaxed, kexts, Hackintosh/OpenCore), reverse-engineered-ish, and rely on closed/private Apple interfaces. DriverKit does not cover this. For a virtual GPU the cheaper route is reuse of Apple's PV driver (section 4).

### Cited Findings
- **NullMoth NVIDIA driver (prior art for a full third-party Metal driver):** Metal driver bundle `NVMTLDriver.bundle` in `/Library/GPUBundles/` implements Metal device/queue/encoder on Vulkan; AIR to SPIR-V translator (LGPL-3.0, based on metal2vulkan); Mesa NVK/NAK; `NVRM.kext` (NVIDIA open GPU kernel modules ported to XNU); separate kexts: `NVRMFB.kext` (IOFramebuffer), `NVAccel.kext` (IOAccelerator, used by WindowServer/IOSurface), `NVRMAGDC.kext` (graphics-device-control). Display kexts link against IOGraphicsFamily/IOAcceleratorFamily2 which exist only in macOS's kernel collections, so they load via the Auxiliary Kernel Collection (rebuilt with kmutil). Requires SIP bits (`csr-active-config` 0x0A43/430A0000), `SecureBootModel=Disabled`, AMFI args (`amfi=0x80 amfi_get_out_of_my_way=0x1`), Lilu + AMFIPass, exclude IONDRVSupport. Targets macOS 15.5+ (tested 15.7.x/15.8.1) or macOS 26, x86_64 only, Turing+ GPUs, mostly tested on RTX 5060. Claims Metal 3, argument buffers tier 2, RT, mesh shaders, MPS, MetalFX path, GL via Apple's GL-on-Metal. License PolyForm Noncommercial 1.0.0 (a SourceForge mirror says MIT - conflict). — [HOW-IT-WORKS](https://raw.githubusercontent.com/nullmoth/nvidia-macos-driver/master/docs/HOW-IT-WORKS.md), [README](https://raw.githubusercontent.com/nullmoth/nvidia-macos-driver/main/README.md), [Magica/Hwbusters coverage](https://hwbusters.com/?p=119089)
- **nullarc (AMD Radeon 780M, macOS Tahoe 26.6.2):** same pattern: `NVMTLDriver.bundle` (Metal on Vulkan), `libnvmtl_translate` (LGPL, from metal2vulkan), Mesa RADV with Darwin winsys, `PhxAccel.kext` (IOAccelerator `NMXAccel`, framebuffer `PhxAMDFB`, AGDC), `PhxBringup.kext` (PSP firmware, MES, per-process GPUVM). WindowServer "only loads an ad-hoc signed driver with AMFI relaxed"; AMFI relaxation disables library validation system-wide and breaks FairPlay playback. Works: WindowServer compositing at 120 Hz, Liquid Glass, ~46 tested apps incl. sandboxed WebKit GPU process; not yet: external displays, HW video codec. Shader translate/compile pause 1-3 s on first use. Code partly PolyForm Noncommercial. — [nullarc wiki](https://github.com/luuumi-dev/nullarc/wiki)
- **DriverKit compute-only precedent:** `lemonade-sdk/mac-amdgpu` is a PCIDriverKit dext for AMD R9700 on Apple Silicon/Tahoe (Thunderbolt 5): needs entitlements `com.apple.developer.driverkit`, `...driverkit.transport.pci` (Apple must approve match scope), `...allow-any-userclient-access`, `system-extension.install`; SIP disabled; paid developer account; explicitly no Metal/display ("future work"); repo archived Oct 3, 2026. — [GitHub](https://github.com/lemonade-sdk/mac-amdgpu)
- TinyGPU (Tiny Corp): reported as an Apple-approved DriverKit extension enabling AMD RDNA3+/NVIDIA Ampere+ eGPUs on Apple Silicon over Thunderbolt/USB4, compute/AI only: no display output, no Metal. Attribution conflicts with a MacRumors/WebProNews story naming Sapling's "Miracle" driver; could not resolve. — [NYU Shanghai summary](https://rits.shanghai.nyu.edu/ai/tinygpu-brings-nvidia-and-amd-egpus-to-apple-silicon-macs/), [MacRumors](https://forums.macrumors.com/threads/apple-approves-driver-for-nvidia-egpu-on-arm-mac-for-accelerated-compute-news-stories.2480483/) (secondary sources)
- Apple DriverKit scope (WWDC20 session 10210): replaces IOKit drivers for USB, serial, network, HID, PCI, SCSI controller families; display/framebuffer not listed; kexts deprecated; Big Sur does not load deprecated kexts by default. — [WWDC20 10210](https://developer.apple.com/videos/play/wwdc2020/10210/) (via search snippets). IOFramebuffer deprecated but still present in IOGraphicsFamily (2017 mailing list, **old**) — [darwin-drivers](https://groups.google.com/g/darwin-drivers/c/6jJ4Zykybx8)
- Apple's MTLDevice docs note textures from one Metal device cannot be used by an encoder from another device (relevant for interposers). — [Apple docs](https://developer.apple.com/documentation/metal/mtldevice.md)
- macOS 26 Tahoe is the last release supporting Intel Macs (per Magica/Hwbusters coverage of NullMoth), so a long-term x86_64 guest target is a shrinking one. — [Magica](https://magica.com/news/nullmoth-metal-driver-nvidia-rtx-macos-sequoia)

### Inferences
- A paravirtual Metal driver in the guest would need the same full stack as nullarc/NullMoth minus hardware bring-up: an IOAccelerator kext, IOFramebuffer/AGDC kexts, a GPUBundles Metal plugin implementing MTLDevice and shader translation (AIR to something host-executable), IOSurface sharing for WindowServer, plus guest/host transport (virtio-gpu blob, etc.). The guest side effort is on the order of the existing driver projects (multi-person-months+), and requires disabling SIP/AMFI/Secure Boot in the guest, acceptable in a Hackintosh-style VM but not on a hardened system. Not a quick project.
- The notably cheaper hybrid: reuse `AppleParavirtGPU.kext` (guest already knows how to talk to it) and implement the host (section 4). A custom IOAccelerator/GPUBundles guest driver only makes sense if that protocol is a dead end.
- Intel iGPU is irrelevant for the guest driver design; only the host Vulkan driver (ANV) matters in the PV approach.
- Whether future macOS (27+) will break these AMFI/SIP-relaxed approaches is unknown; Apple trajectory (kext deprecation) suggests ongoing risk. Inference only.

### Gaps
- Could not find Apple documentation on the Metal driver plugin loading mechanism (GPUBundles, MTLDevice plugin interface), entitlement requirements for IOAccelerator kexts, or confirmation DriverKit has no GPU family; the DriverKit scope statement is from a 2020 session list plus search snippets.
- Not verified: how the NullMoth/nullarc stacks behave in a VM; both target physical GPUs. Both READMEs are self-reported; not independently tested.
- License conflict for NullMoth (PolyForm NC vs MIT mirror) unresolved.

---

## 6. Metal-over-Vulkan/remote interposers inside macOS (prior art)

### Takeaway
Metal-to-Vulkan translation exists as a driver (NullMoth/nullarc, via metal2vulkan) and as a host library (reims-vgpu). I found no public project that interposes `Metal.framework` in user space to fake an MTLDevice backed by a remote GPU; macOS-system-wide interposition looks unattractive because WindowServer and system frameworks use Metal directly.

### Cited Findings
- metal2vulkan: AIR to SPIR-V translator (LGPL-3.0) used inside NullMoth, nullarc and reims-vgpu's Vulkan path (see section 5, 4 sources). No standalone project page found in search ("not a standalone project" per search result).
- Chromium's historical `MTLDeviceProxy`/`metal_api_proxy` is a local wrapper for watchdog reporting, not remoting. — [Chromium source](https://chromium.googlesource.com/chromium/src.git/+/5bb31c07fbefa8ec97f1c9e7ebc9e94151738ff5/components/viz/common/gpu/metal_api_proxy.h)
- Search for macOS Metal remoting/MTLDevice network interposer found nothing authoritative; one unverified Reddit-style post speculates on sharing eGPU memory across Macs via RDMA (not reliable).
- MoltenVK is the reverse direction (Vulkan on Metal): [MoltenVK user guide](https://skia.googlesource.com/external/github.com/KhronosGroup/MoltenVK/+/872d13dcee3a942f23c6965a49e43f0fc6a5e69b/Docs/MoltenVK_Runtime_UserGuide.md). KosmicKrisp (Mesa Vulkan-on-Metal) is mentioned in the vmmbox PR (macOS host).

### Inferences
- A user-space interposer could serve a single app (like a game wrapper) but not WindowServer-rendered desktop acceleration; the Apple PV driver or a kext-level accelerator is the realistic entry point for the whole OS.

### Gaps
- No evidence found for or against gfxstream-for-Apple-guests or remote-Metal projects beyond the single search; searches were shallow.

---

## 7. Summary table

| Option | Guest macOS versions | 3D API exposed to guest | Host requirements | Openness | Status (Nov 2026) |
|---|---|---|---|---|---|
| QEMU `vmware-svga` + VMwareGfx kext | Mojave-era to Ventura reports (2D); newer not verified | None (2D/framebuffer only; QEMU device has no SVGA3D) | Any QEMU | Device open; guest kext is VMware's (darwin.iso) | Works as display only; no 3D |
| VMware Fusion/Workstation SVGA3D | No macOS SVGA3D driver found | None via SVGA | VMware, Mac host (Fusion) | Closed host | Not applicable |
| VMware Fusion "Metal" for macOS (`appleGPU0`) | Big Sur+; Sonoma works per reports; Sequoia flaky (anecdotal) | Metal subset (no OpenGL) | Mac host (Intel Mac, Fusion 13) | Closed; uses Apple PV | Macs only; macOS dropped from Fusion 13 compat list per Broadcom reply |
| Parallels | Big Sur+ | Metal | Mac host, Parallels 16+ | Closed; Apple PV | Mac only |
| VirtualBox | Experimental macOS guests | None (no Guest Additions) | macOS host only | Open host, no macOS GA | No 3D |
| virtio-gpu (QEMU) + `virtio-gpu-macos` kext | 10.15+ per README | None (2D only; Virgl "planned") | Linux KVM OK | MIT, open | Alpha, README 2024-04-07, 6 stars |
| VirGL / Venus / gfxstream | No macOS guest driver | None | Linux KVM | Open host (virglrenderer) | No guest support; research repo (macos-gpu-vm-lab) "nothing proven" |
| QXL / stdvga | Any with AppleVirtualGraphics (stdvga) | None | Any QEMU | Open | Display/mouse only |
| Intel GVT-g / SR-IOV | No macOS guest support listed | None | GVT-g gen 6-10 only; SR-IOV out-of-tree, Windows/Linux guests | Open (Linux) | GVT-g legacy; Iris Xe unsupported for macOS |
| reims-vgpu (host-side Apple PV reimplementation) | x86-64: Tahoe 26 tested; Sonoma claimed on forum; arm64 13-26 | Metal (via stock AppleParavirtGPU + metal2vulkan to Vulkan) | Linux KVM, Vulkan 1.2+, /dev/udmabuf, OpenCore; Iris Xe untested | GPL-2.0+/LGPL-3.0+ | Beta (README), "slow" per alpha forum post; tested on NVIDIA |
| NullMoth / nullarc (Metal driver for physical GPU, not virtual) | Sequoia 15.5+/Tahoe, x86_64 (NullMoth); Tahoe (nullarc) | Metal 3 (claims), GL via Apple GL-on-Metal | Physical NVIDIA Turing+ / AMD 780M, OpenCore, SIP/AMFI relaxed | PolyForm NC (mixed) | Working on real HW, not virtual |
| Writing a new guest Metal driver | n/a | Would be Metal | Needs IOAccelerator kext + GPUBundles plugin; relaxed SIP/AMFI/SecureBoot | Yours | Not done for virtual GPUs as far as I found |
