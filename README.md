# Project ReVork — ColorOS/OxygenOS Porting

A practical toolkit to port ColorOS/OxygenOS/realme UI ROMs onto Qualcomm Snapdragon 865/888 devices with sane defaults for smoothness, thermals, and battery.

## 📋 Table of Contents
- [What changed recently](#what-changed-recently)
- [Supported devices](#supported-devices)
- [Performance profiles (ROM side)](#performance-profiles-rom-side)
- [OnePlus 9 Pro notes](#oneplus-9-pro-notes)
- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Tips](#tips)
- [Known issues](#known-issues)
- [Contributing](#contributing)

---

## What changed recently
- OP9 Pro balanced daily profile: lower idle CPU/GPU floors, quicker ramp-down, longer touch boost for first-frame smoothness.
- Warp Charge restored: full 65W allowed when cool; thermal triggers step down to keep temps in check.
- ColorOS CN quality-of-life: CN bootanimation apply and 3D wallpaper integration.
- Debloat additions: removes common HeyTap/Health/IR/QuickGame extras by default.

## Supported devices
- SM8350 (Snapdragon 888): OnePlus 9, 9 Pro (global/CN), 9R, 9RT, OPPO Find X3 / Pro.
- SM8250 (Snapdragon 865): OnePlus 8, 8 Pro, 8T.

## Performance profiles (ROM side)
| Profile | CPU floor | GPU floor | Intent |
|---------|-----------|-----------|--------|
| Normal | ~1.2GHz big | ~180MHz | Daily use |
| Gaming | ~1.5GHz big | ~500MHz | Sustained play |
| Benchmark | Max lock | ~750MHz | Score runs |
| Battery Saver | ~600MHz | ~135MHz | Low power |

## OnePlus 9 Pro notes
- Display: LTPO QHD+ kept at 120Hz when active; drops intelligently on idle/video.
- Smoothness: input boost 60ms and lower idle clocks keep heat down without hurting scroll.
- GPU: 234–750MHz by default (300MHz floor on 12GB builds); faster idle timer for better standby.
- Charging: Warp 65T allowed (6.5A). Screen-on uses ~6.0A. Gaming while charging trims to ~3.5A. Thermal high flag drops to ~3.5–4A and restores when cool.
- Thermals: vapor-chamber-aware thermal-engine tweaks; balanced BCL thresholds to avoid surprise throttles.

## Quick start
1) Install deps: sudo ./setup.sh (Ubuntu/WSL).
2) Run with local zips: sudo ./port.sh /path/to/baserom.zip /path/to/portrom.zip
3) Or with URLs: sudo ./port.sh "https://example.com/base.zip" "https://example.com/port.zip"
4) For mixed ports, add optional third/partition args as before.

## Requirements
- Linux/WSL, 40GB free, 8GB+ RAM recommended.
- Android 14+ source ROMs; payload/bin or img-based packages.

## Tips
- OP9 Pro: flash, then check temps during 10–15 minutes of gaming to confirm the new current limits behave in your environment.
- ColorOS CN: GApps are not bundled; flash your preferred package separately if you want them.
- If GitHub assets are missing, place required ROM/tool files manually in their expected paths.

## Known issues
- Some kernels omit KGSL nodes used for GPU tuning; those writes are best-effort.
- Charging current caps still obey the kernel/PMIC hard limits; values above hardware limits are ignored by the driver.

## Contributing
PRs and issues are welcome. Keep changes reproducible and note any device-specific quirks you encounter.
