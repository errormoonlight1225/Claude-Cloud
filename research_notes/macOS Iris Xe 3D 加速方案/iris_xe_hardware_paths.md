# Hardware-level paths to accelerated graphics in macOS (guest or bare metal) on Intel Iris Xe (Gen12 Xe-LP)

Date of note: 2026-11-04. Scope: Xe-LP iGPUs (Tiger Lake 11th gen mobile, Rocket Lake desktop UHD 750, Alder Lake/Raptor Lake incl. UHD 730/770 and Iris Xe), Meteor Lake Xe-LPG for context.
Method note: several primary pages (Phoronix, freedesktop mailing list, Arch wiki, Mesa GitLab) returned 403/Access Denied to my fetcher; those claims are marked "secondary" or "unverified". Some Intel/Dortania details come from fetch summaries produced by a small model; wording in quotes is as returned by the fetch tool.

## (a) Does macOS have any usable driver for Xe-LP iGPUs?

### Takeaway
No. Apple's Intel graphics kexts stop at Gen11 (Ice Lake); no shipping Mac has Gen12 Xe-LP, and every Tiger/Rocket/Alder/Raptor/Meteor Lake Hackintosh has no GPU acceleration (at best a framebuffer/VESA path or a disabled iGPU with a discrete AMD card). Spoofing Xe-LP as Ice Lake is reported not to work. Intel Macs end at macOS 26 Tahoe, so no future Apple Intel driver is expected.

### Cited Findings
- Dortania GPU Buyers Guide table: Ivy Bridge highest Big Sur; Haswell and Broadwell highest Monterey; Skylake highest Sequoia (note: Ventura drops Skylake iGPU, spoof as Kaby Lake); Kaby Lake through Comet Lake and Ice Lake (except UHD G1) "Current/Sequoia (15)"; Ice Lake initial support Catalina 10.15.4. — [Dortania Intel GPUs](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/intel-gpu.html)
- Same page: "The following GPUs are Xe based, with no support in any version of macOS" — Tiger Lake/Rocket Lake, Alder Lake/Rocket Lake, Raptor Lake and Meteor Lake listed with "None" for highest and initial supported OS; "All of the iGPUs for these CPUs are unsupported, as they are Xe based." — [Dortania Intel GPUs](https://dortania.github.io/GPU-Buyers-Guide/modern-gpus/intel-gpu.html)
- Dortania's table only goes to Sequoia (15) in its "highest" column; I did not verify whether Dortania states Tahoe status for Gen9–11 iGPUs (see Gaps).
- Reddit r/hackintosh, March 2026 (Alder Lake i3-1215U laptop, Sonoma 14.7.3, OpenCore): freeze at EXITBS:START; OP tried spoofing to Ice Lake with MacBookAir9,1 SMBIOS; the single commenter said "macOS only has video drivers up to 10th gen iGPU", "there is no Iris Xe macOS video driver", "You cannot spoof an Iris Xe iGPU as Iris Plus, as they are not compatible through spoofing." Anecdotal, one commenter. — [Reddit snapshot (mirror)](https://reddit.sentinel-team.org/posts/1rpmb02/snapshots/2026-03-11T09%3A39%3A01.441986Z)
- InsanelyMac, May 2024: moderator Slice on Tiger Lake Iris Xe: won't work "until the special driver is finished", black screen otherwise; on Alder Lake i5-1235U: "no chances"; Slice: "The stop is the impossibility of iGPU to show graphics." Workarounds tried by a user (VESA via `-igfxvesa`, ig-platform-id changes, faking a Comet Lake device-id) did not resolve boot. Another user said Sonoma "was working well" without acceleration (hardware unspecified). Thread references a community Tiger Lake Iris Xe effort (topic 358305, title "[80% Solved] Iris Xe iGPU on Tiger Lake...", claimed ICLLP framebuffer load and ~1536MB VRAM) — only the title was seen, not verified. — [InsanelyMac thread 359261](https://www.insanelymac.com/forum/topic/359261-need-help-on-legacy-shim-2-error/)
- GitHub `pawan295/Appleinteltgldriver.kext` (115 stars, 4 commits, 3 issues; dates not visible) claims a Tiger Lake (Gen12) macOS driver for device IDs 0x9a40–0x9a78. Its own Limitations section says it "only opens accelerator user clients for surface and display related, no command submission and metal". Features list contradicts this ("Full Metal framework support ... (Needs work)"). No evidence of working Metal. — [repo](https://github.com/pawan295/Appleinteltgldriver.kext)
- Reddit-sourced guide (via search summary, not independently opened): macOS on Alder Lake laptops "not possible" due to the unsupported iGPU; desktop Alder Lake builds rely on a discrete GPU, and features needing the iGPU (e.g. Sidecar on UHD 770) do not work. Acidanthera's Dec 2021 notes add Alder Lake CPU/ACPI support in OpenCore only (CPU, not GPU). — [Dortania/Acidanthera Dec 2021](https://dortania.github.io/hackintosh/updates/2021/12/07/acidanthera-december.html) (search snippet only; iGPU part not verified on the page)
- Apple announced at WWDC on 2025-06-09 that macOS Tahoe (26) is the last release to support Intel Macs; Intel Macs eligible for Tahoe: 2019 16-inch MBP, 2020 13-inch MBP (4 TB3 ports), 2020 27-inch iMac, 2019 Mac Pro. — [Six Colors](https://sixcolors.com/post/2025/06/macos-tahoe-is-the-last-release-to-support-intel/)
- macOS 27 "Golden Gate" runs exclusively on Apple silicon; Tahoe "will continue to receive security updates for 2 years" (TidBITS) vs "three years" (Six Colors, quoting reporting, no direct Apple quote) — sources conflict on duration. TidBITS (2026-07-20) said final macOS 27 releases were expected Sept/Oct; I did not verify the actual release date. — [TidBITS](https://tidbits.com/2026/07/20/the-real-system-requirements-for-%EF%A3%BFos-27/); conflicting duration: [Six Colors](https://sixcolors.com/post/2025/06/macos-tahoe-is-the-last-release-to-support-intel/)
- Apple security notes show Tahoe 26.7.2 (page dated 2026-10-26) still shipping, i.e. Intel Tahoe still serviced as of this note. — [Apple Support 149522](https://support.apple.com/en-us/149522) (via search snippet)

### Inferences
- Because Apple never shipped a Mac with Gen12 graphics (Apple moved to Apple silicon in 2020; the last Intel Macs use Coffee Lake/Comet Lake/Ice Lake iGPUs or AMD dGPUs) there is no Apple code to bind to Xe-LP device IDs. This is inference from the Dortania table plus the list of Tahoe-eligible Macs; I did not find an Apple statement.
- Since Intel Mac support ends with Tahoe, a native Apple Xe-LP driver will never appear; any macOS Xe-LP acceleration would have to be a third-party reimplementation (the TGL kext above is the only attempt seen, with no command submission/Metal).
- Fake-ID tricks fail because Gen12 uses a different display engine, GuC-submission model and ISA than Gen11; the Ice Lake kexts (AppleIntelICLGraphics) cannot drive it. Mechanism is inference; the failure reports are anecdotal.

### Gaps
- Could not verify what WhateverGreen's README/issues say about Gen12 (GitHub not searched directly); no WhateverGreen "support" statement found.
- Could not verify Dortania's wording on Tahoe-specific Intel iGPU support (page showed Sequoia as the last listed).
- No Tonymacx86 content found/opened. No Level1Techs content found.
- Did not verify the InsanelyMac "80% Solved" Tiger Lake thread beyond its title; no confirmation of what "80%" means.
- Macworld/Macwelt "Alder Lake Hackintosh mit Haken" articles appeared in results but were not opened.

## (b) Can the iGPU be shared/passed through to a macOS VM? GVT-g

### Takeaway
GVT-g (mediated vGPU) covered Broadwell through Comet Lake (Gen8–Gen9.5) and is discontinued; it was never extended to Gen12. Even for supported generations, a macOS guest would still need an Apple-side driver for the virtual device, which for Gen9 is the real Apple Gen9 driver but GVT-g/macOS success is not documented in what I found.

### Cited Findings
- Intel's "Graphics Virtualization Technologies Support for Each Intel Graphics Family" table: GVT-g listed for Skylake through Comet Lake, Ice Lake and Rocket Lake (as listed on the page); Tiger Lake "Not Supported"; Twin Lake/Alder Lake/Raptor Lake/Raptor Lake Refresh "SR-IOV"; Meteor Lake and Panther Lake/Wildcat Lake "SR-IOV (Supported on Linux host with Windows/Linux virtual machines)"; Arrow Lake SR-IOV; Lunar Lake and Arc A-series "Not Supported". — [Intel](https://www.intel.com/content/www/us/en/support/articles/000093216/graphics.html)
- Contradiction: the Intel table lists Ice Lake and Rocket Lake under GVT-g, while the Arch Linux wiki (via search summary; fetch blocked) says GVT-g is limited to 5th gen (Broadwell) to 10th gen (Comet Lake), attributing the cutoff to missing Gen11 support in i915, and says Ice Lake supports GVT-d only. The community statement is more consistent with kernel code; the Intel table's Rocket Lake (Gen12 iGPU) GVT-g entry looks like an error. Unresolved. — [Arch wiki GVT-g](https://wiki.archlinux.org/title/Intel_GVT-g) (search snippet); contradicted by [Intel table](https://www.intel.com/content/www/us/en/support/articles/000093216/graphics.html)
- LKML post of 2025-06-30 (Marcello Sylvester Bauer): "Starting with Tiger Lake, support for GVT-g was discontinued in favor of SR-IOV for graphics virtualization." — [LKML](https://lkml.indiana.edu/hypermail/linux/kernel/2506.3/09825.html)
- Proxmox forum (April 2026, user post, not authoritative): gvt-linux "officially discontinued by Intel", GitHub repo archived October 2024, GVT-g "effectively dead upstream", OP reports it no longer works on kernel 6.17; poster guesses breakage "around 6.8" (unverified). — [Proxmox forum](https://forum.proxmox.com/threads/status-of-mediated-devices-gvt-g.182937/)
- Upstream history: GVT-g/KVMGT upstreamed in Linux 4.10; 2022 series moved GVT code out of i915 into the kvmgt module with mdev API. — [KVMGT-qemu issue/search result](https://github.com/intel/KVMGT-qemu/issues/6); [lore series](https://lore.kernel.org/all/871qy1geko.fsf@intel.com/T/)

### Inferences
- There is no GVT-g path for Xe-LP iGPUs. The only vGPU option for Gen12 is SR-IOV (section c).
- For a macOS guest on a pre-Gen11 host (e.g. Coffee Lake with GVT-g), I found no community evidence of a macOS guest using a GVT-g vGPU; not claimed either way.

### Gaps
- Could not read the Arch wiki or kernel git directly; exact kernel version where GVT-g was removed/broken not verified.
- Whether any macOS guest has ever bound to a GVT-g vGPU: no source found.

## (c) SR-IOV on Gen12 iGPU

### Takeaway
SR-IOV on Xe-LP is real and works on Linux hosts with Linux/Windows guests, mostly via the out-of-tree strongtz/i915-sriov-dkms (still actively released, 2026-10-28). Upstream xe was moving toward enabling it for TGL/ADL (reported for 6.18) but real-world success with the in-kernel xe path was mixed. No report of a macOS guest using a VF was found, and none is expected since macOS has no Xe-LP driver.

### Cited Findings
- strongtz/i915-sriov-dkms: community snapshot of i915 and xe modules from mainline with SR-IOV ported from Intel's mainline-tracking; "not affiliated with or endorsed by Intel"; experimental. Latest tag 2026.10.28 for kernels 6.18.x–7.3.x; 6.12–6.18 use 2025.12.10.2; 6.8–6.12 use 2025.07.22; 6.1–6.7 use `intel-lts-v6.1` branch (older branches unmaintained). Up to 7 VFs (00:02.1–.7) via `i915.max_vfs=7`/`xe.max_vfs=7` or `sriov_numvfs`; `intel_iommu=on`; do not pass the PF (crashes other VFs); Secure Boot must be off; module is needed in the guest too. xe driver does not support MTL/LNL (use i915 there). Documented guests: Ubuntu and Windows 11 24H2 on Proxmox 8.3 (Intel driver 32.0.101.6460/6259). macOS not mentioned. For Xe_LP, CCS0 off by default since 2026.09.16/2025.12.10.1; Windows guests may need `xelp_enable_ccs=1`. — [GitHub](https://github.com/strongtz/i915-sriov-dkms)
- Upstream xe status, 2025-06-30: only Panther Lake had SR-IOV in drm-xe-next (v6.13.1); ADL/RPL only in the xe-for-CI debug branch; TGL no; Intel LTS i915 branches had TGL/ADL/RPL (v5.15) and MTL (v6.1). — [LKML](https://lkml.indiana.edu/hypermail/linux/kernel/2506.3/09825.html)
- July 2025 patch "drm/xe: Enable SR-IOV for TGL" posted to intel-xe (snippet: no official CI SR-IOV coverage for TGL but xe has all required changes). Merge status not confirmed (fetch blocked). — [intel-xe list](https://lists.freedesktop.org/archives/intel-xe/2025-July/089604.html) (search snippet)
- Phoronix (via search snippets, pages blocked): Linux 6.17 enabled SR-IOV PF by default for Panther Lake and Battlemage; Linux 6.18 pull reported to enable PF by default for Tiger Lake, Alder Lake and Arctic Sound (still behind the xe `force_probe` gate). — [Phoronix 6.18](https://www.phoronix.com/news/Linux-6.18-More-Xe-SR-IOV); [Phoronix 6.17](https://www.phoronix.com/news/Intel-Xe-Linux-6.17-PF-4K)
- CachyOS forum (2026-02-06): "Supposedly, Kernel 6.18 enabled support for SR-IOV on Tiger Lake and Alder Lake to Raptor Lake Refresh... However, I was unable to get it to work on my TGL laptop with the xe kernel driver"; poster points to the DKMS module. Single anecdote. — [CachyOS forum](https://discuss.cachyos.org/t/intel-gpus-getting-virtio-intel-native-context-support/22560)
- Proxmox forum: Alder Lake NUC 12 with i915-sriov-dkms on kernel 6.1 created VFs, needed hand-edited VM config; a separate 12th-gen full-iGPU passthrough to Windows hit error 43. — [Proxmox forum](https://forum.proxmox.com/threads/120947/)
- r/VFIO (2023): UHD 770 "Code 43 inside VM after installing drivers" even with VFs; a commenter noted guest drivers for VFs are different from native-hardware ones. Linux guests (video encode/QuickSync) reported working. Page itself failed to load; claims from search snippet. — [r/VFIO mirror](https://lr.eu.psf.lt/r/VFIO/comments/139vu5w/code_43_with_intel_igpu_uhd_770_via_sriov_or)
- Intel table lists Meteor Lake SR-IOV as "Supported on Linux host with Windows/Linux virtual machines"; Qubes forum commenter said Intel docs state SR-IOV unsupported on MTL/Lunar Lake (conflicts with Intel table's MTL entry, which is the primary source). — [Intel](https://www.intel.com/content/www/us/en/support/articles/000093216/graphics.html); [Qubes forum snippet](https://forum.qubes-os.org/t/lenovo-thinkpad-t14-gen-5/27923?page=2)
- MacStadium Orka docs mention Intel GPU passthrough for macOS guests up to Sonoma, but this is a hosted product on Apple hardware and the details were not read. — [MacStadium](https://docs.macstadium.com/orka/compatibility/compatibility-performance-improving-features)

### Inferences
- A VF exposes the Xe-LP device ID (the guest sees an Intel Gen12 iGPU VF with its own PCI IDs). macOS would enumerate the PCI device but no kext matches; at best it sits as an unclaimed PCI device. This is inference; no report found.
- SR-IOV mainly helps Linux/Windows guests, which have Intel's VF-capable drivers (Windows needs i915-sriov patch quirks as noted). For a macOS guest it only helps if someone writes an Xe-LP VF driver, and VF drivers must speak GuC/VF-specific protocol (inference from the r/VFIO comment).
- For a custom paravirtual GPU design, SR-IOV VFs are irrelevant; the host-side renderer should use the PF/render node.

### Gaps
- No report of a macOS guest with an SR-IOV VF found.
- Could not confirm whether xe SR-IOV for TGL/ADL actually merged in 6.18 or later (sources blocked); the CachyOS user's failure and the DKMS README's continued need for out-of-tree code suggest it is not turnkey.
- Display output from VFs (VFs are render-only, no display) — not stated in the sources I opened.

## Full iGPU passthrough (vfio-pci, legacy mode/UPT, ROM/GOP) to a macOS guest

### Takeaway
Reports exist only for pre-Gen11 iGPUs (HD/UHD 630, Skylake–Coffee Lake) and are inconsistent: display detected, Metal often not working. For Iris Xe there are no macOS reports; the guest would see an unsupported Gen12 device with no driver.

### Cited Findings
- Proxmox forum thread (HD 630, i5-7600K / i3-7100 / i7-7700HQ; Monterey): passthrough gave no signal or VM that would not start; one poster (July 2024) on q35+OVMF saw macOS detect both virtual and physical displays but "metal is not working"; works only with Primary GPU unchecked and Display not "none"; `legacy-igd` with i440fx/SeaBIOS failed for macOS; `romfile=i915ovmf.rom` was used but judged irrelevant; spoofing the 630 as 530 produced a signal but no acceleration; kernel 5.13 worked for Windows while 5.15/5.19 gave no signal. — [Proxmox forum](https://forum.proxmox.com/threads/pve-intel-gpu-passthrough-to-macos-monterey-no-signal.115502/)
- Search snippet: Proxmox VE 9 users report direct iGPU passthrough broken generally (Windows guest, error 43), reproduced by Proxmox staff without fix. — [Proxmox forum](https://forum.proxmox.com/goto/post?id=820594) (snippet only)
- Bare-metal reference for UHD 630: OpenCore+WhateverGreen with `AAPL,ig-platform-id` 0300913E and `enable-metal=01` (Ventura, Coffee Lake Refresh). — [perez987 guide](https://github.imc.re/perez987/Intel-UHD-630-on-macOS) (via search snippet)

### Inferences
- Iris Xe passthrough adds Gen12 specifics (GuC firmware required for ADL-P+ per Mesa docs, no legacy IGD OpRegion/ROM path comparable to older chips) but the dominant blocker is the missing Apple driver, so the guest would get at best a non-accelerated framebuffer via the VM's own GOP/VESA, or nothing.
- Because host loses display with legacy-IGD passthrough on an iGPU-only system, it conflicts with a use case where the iGPU is also the host renderer.

### Gaps
- No Iris Xe → macOS passthrough report found. No UPT/Intel-specific "legacy mode" documentation for Gen12 checked.

## Workarounds to get Metal on Iris Xe in macOS

### Takeaway
None is known to work. Spoofing, framebuffer patching and the one community Tiger Lake kext all stop short of Metal. Stable macOS on 11th–14th gen Intel requires disabling the iGPU or using a discrete AMD GPU (or software rendering).

### Cited Findings
- See (a): Dortania "None" for all Xe-based; Reddit March 2026 "cannot spoof Iris Xe as Iris Plus"; InsanelyMac 2024 "no chances" on ADL, "black screen" on TGL without a driver; GitHub TGL kext without command submission or Metal. — sources above.
- Search summary of Reddit/InsanelyMac/Dortania surfaced no success report of Metal-accelerated Iris Xe in macOS; I found no failure/success reports on tonymacx86 (not searched effectively).

### Inferences
- With Intel Macs ending at Tahoe and Hackintosh likewise ending, effort to write a Gen12 Metal driver is unlikely to grow; the existing community kext appears abandoned or stalled (no dates visible).

### Gaps
- tonymacx86 and Level1Techs not covered; no first-hand tests.

## Host-side acceleration on Linux (brief)

### Takeaway
Xe-LP is well supported on the Linux host (Mesa anv Vulkan, iris OpenGL), so a host-side renderer for a paravirtual GPU can rely on it; Intel virtio native context work is in progress.

### Cited Findings
- Collabora: at Vulkan 1.4 launch, ANV (Intel) was among 5 Mesa drivers conformant day-zero (NVK, ANV, RADV, Turnip, Honeykrisp). Not specific to Gen12. — [Collabora](https://www.collabora.com/news-and-blog/news-and-events/nvk-now-supports-vulkan-14.html) (search snippet)
- Mesa 20.3 added Alder Lake Gen12 support via the same code paths as Tiger Lake/Rocket Lake. — [Phoronix](https://www.phoronix.com/news/Mesa-20.3-Alder-Lake-Graphics)
- Mesa ANV docs: "Starting with Intel 12th generation/Alder Lake-P and Intel Arc Alchemist" the stack requires GuC firmware. — [Mesa ANV docs](https://docs.mesa3d.org/drivers/anv.html)
- CachyOS forum, 2026-02-06: post links Mesa MR !29870 "Support virtio-intel native context" (like AMDGPU !21658 and Freedreno), no release named; same poster saw mesa-git VirGL performing worse than Mesa 25.3.4, Venus unchanged. MR status not verified (GitLab blocked). — [CachyOS forum](https://discuss.cachyos.org/t/intel-gpus-getting-virtio-intel-native-context-support/22560)
- Mesa "KosmicKrisp" is a Vulkan-on-Metal driver (advertises Vulkan 1.4) — relevant for macOS-hosted Vulkan, not for Intel Gen12. — [Phoronix](https://phoronix.com/news/KosmicKrisp-Vulkan-1.4)

### Inferences
- A paravirtual GPU (virtio-gpu style) in a macOS guest would render on the Linux host with anv/iris for Xe-LP; the guest needs its own paravirtual macOS driver (not part of this note's scope).

### Gaps
- Exact OpenGL/Vulkan conformance versions for Gen12 under current Mesa not verified (docs.mesa3d.org features/conformance pages not fetched).
- virtio-intel native context merge status unknown.
