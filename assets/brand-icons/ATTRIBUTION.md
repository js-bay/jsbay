# Brand icon sources

> **中文摘要（引擎标）**
> - **Meta Hermes**：官方矢量，来自 `vendor/hermes/doc/img/logo.svg`（MIT 仓库资源；商标属 Meta）。**用于 banner。**
> - **JavaScriptCore**：用 WebKit 指南针身份。完整标存 `webkit-logo.svg`（Wikimedia）；banner 内嵌简化平面版 `webkit-mark.svg`。Apple 商标，仅作识别。
> - **QuickJS / QuickJS-NG / Escargot**：上游无官方 logo → banner **只用实心圆点**，不用自绘替身。

Icons used in `assets/banner.svg` (and stored here for reuse). Trademarks remain with their owners; inclusion is for platform / engine identification only and does not imply endorsement.

## Host platforms

| File | Source | License / notes |
|------|--------|-----------------|
| `android-robot.svg` | [Wikimedia: Android robot.svg](https://commons.wikimedia.org/wiki/File:Android_robot.svg) (Google / Irina Blok; [Android brand guidelines](https://developer.android.com/distribute/marketing-tools/brand-guidelines)) | **CC BY 3.0** — attribute: *The Android robot is reproduced or modified from work created and shared by Google and used according to terms described in the Creative Commons 3.0 Attribution License.* Banner uses `#3DDC84` (current online green). |
| `android-robot-head.svg` | [Wikimedia: Android robot head.svg](https://commons.wikimedia.org/wiki/File:Android_robot_head.svg) | Same Android robot family (CC BY 3.0). |
| `android-robot-flat.svg` | Flattened (no `xlink:use`) derivative of `android-robot.svg` for reliable embedding | Same CC BY 3.0 attribution. **Used in banner.** |
| `apple-logo.svg` | [Wikimedia: Apple logo black.svg](https://commons.wikimedia.org/wiki/File:Apple_logo_black.svg) | PD-textlogo (simple geometric mark); Apple trademark. Banner uses white fill on black. **Used in banner.** |
| `windows-logo.svg` | [Wikimedia: Windows logo - 2021.svg](https://commons.wikimedia.org/wiki/File:Windows_logo_-_2021.svg) | PD-textlogo (four panes); Microsoft trademark. Fill `#0078D4`. Banner inlines equivalent four-rect geometry. **Used in banner.** |
| `tux.svg` | [Wikimedia: Tux.svg](https://commons.wikimedia.org/wiki/File:Tux.svg) (Larry Ewing, Simon Budig, Garrett LeSage) | Free use with attribution to Larry Ewing and The GIMP. |
| `tux-compact.svg` | Solid fills derived from `tux.svg` (filters removed) | Same Tux attribution. |
| `linux-simple.svg` / `linux-tux-mark.svg` | [Simple Icons `linux`](https://simpleicons.org/?q=linux) Tux silhouette (**CC0**), tinted `#FCC624` for dark backgrounds | Freely usable; Tux character originally by Larry Ewing. **Path used in banner.** |
| `harmony-mark.svg` | Huawei flower path via [Simple Icons `huawei`](https://simpleicons.org/?q=huawei) (**CC0**) | Huawei trademark. Compact HarmonyOS-adjacent mark. **Used in banner.** |
| `harmonyos-wordmark.svg` | [Wikimedia: HarmonyOS logo.svg](https://commons.wikimedia.org/wiki/File:HarmonyOS_logo.svg) (Huawei) | PD-textlogo / trademark Huawei. Wordmark archived for lockups. |
| `openharmony-logo.svg` / `openharmony-emblem.svg` | [Wikimedia: OpenHarmony Logo by OpenAtom.svg](https://commons.wikimedia.org/wiki/File:OpenHarmony_Logo_by_OpenAtom.svg) | OpenAtom Foundation mark; archived for reference. |
| `huawei-flower.svg` | Simple Icons `huawei` source for `harmony-mark.svg` | CC0 path data; Huawei trademark. |

## JS engines

| File | Source | License / notes |
|------|--------|-----------------|
| `hermes-logo.svg` | [facebook/hermes `doc/img/logo.svg`](https://github.com/facebook/hermes/blob/main/doc/img/logo.svg) (Meta Hermes JS engine; title *Hermes Full Color Logo*) | MIT-licensed repo asset; **Hermes / Meta trademark**. Identification only, no endorsement. Official green `#2bb673`. |
| `hermes-mark.svg` | Flattened (inline fills, no CSS classes) derivative of `hermes-logo.svg` for reliable banner embedding | Same Meta trademark / source. **Used in banner.** |
| `webkit-logo.svg` | [Wikimedia: WebKit logo.svg](https://commons.wikimedia.org/wiki/File:WebKit_logo.svg) (full compass; Brands of the World → Commons) | Tagged LGPL / BSD on Commons; **Apple WebKit trademark**. Apple’s WebKit terms do not grant a logo license for branding — identification only. Full archive; not inlined in banner. |
| `webkit-mark.svg` | Simplified flat compass face for ~26px pills, derived from the WebKit logo identity (blue dial + N/S needle) | Same WebKit / Apple trademark caveat. Stands in for **JavaScriptCore** (JSC is the WebKit JS engine). **Used in banner.** |
| `webkit-compass-box.svg` | [Wikimedia: Compass in a box.svg](https://commons.wikimedia.org/wiki/File:Compass_in_a_box.svg) | Related WebKit-compass artwork; archived, not used in banner. |

QuickJS, QuickJS-NG, and Escargot have **no official marks** upstream; the banner uses animated solid dots for those pills (not separate SVG files).

## Download / copy dates

- Host marks: 2026-10-22 from Wikimedia Commons (`Special:FilePath`) and jsDelivr Simple Icons.
- Hermes mark: 2026-10-30 from `vendor/hermes` (facebook/hermes submodule) `doc/img/logo.svg`.
- WebKit full logo + compass-box + simplified mark: 2026-10-30 from Wikimedia Commons / derived for banner.
