# coloros_port

ColorOS/OxygenOS/realme UI ROM porting toolkit for Snapdragon 865/888 class devices.

This project automates:
- ROM extraction (payload, img, dat.br)
- partition merge/override logic (including mixed-port mode)
- device-specific patching and prop tuning
- image repacking
- packaging to OTA-style zip (`pack_method=stock`) or flashable fastboot zip

## Supported devices in this repo
Current device folders under `devices/`:
- `OnePlus8`
- `OnePlus8Pro`
- `OnePlus8T`
- `OnePlus9`
- `OnePlus9Pro`
- `OnePlus9R`
- `OP4E5D`

Common patches are stored in `devices/common/`.

## Host requirements
- Linux (x86_64/aarch64), WSL2, or macOS x86_64
- `sudo`/root for setup and running `port.sh`
- large free disk space (recommend 80GB+)
- enough RAM for APK/smali and image repack workloads (recommend 16GB+)

Install dependencies:

```bash
sudo ./setup.sh
```

Note: `setup.sh` installs most dependencies, but your environment should also provide common tools such as `git`, `jq`, `md5sum`, and `unix2dos`.

## Quick start
1. Install dependencies.
2. Edit `bin/port_config` if needed.
3. Run porting command.

Basic:

```bash
sudo ./port.sh /path/to/base.zip /path/to/port.zip
```

URLs are supported:

```bash
sudo ./port.sh "https://example.com/base.zip" "https://example.com/port.zip"
```

Mixed-port mode (third ROM + selected partitions):

```bash
sudo ./port.sh /path/base.zip /path/portA.zip /path/portB.zip "my_stock my_region my_manifest my_product"
```

## Usage

```bash
sudo ./port.sh <baserom> <portrom> [portrom2] [portparts]
```

- `baserom`: base ROM zip path or URL
- `portrom`: source ROM zip path or URL
- `portrom2`: optional second source ROM for mixed mode
- `portparts`: optional space-separated partitions taken from `portrom2`

## Packaging modes
Controlled by `pack_method` in `bin/port_config`.

### `pack_method=stock` (default in current config)
- Builds target-files style output under `out/target/product/<device>/`
- Generates OTA package using `otatools/bin/ota_from_target_files`

### `pack_method!=stock`
- Builds `super.img`
- Compresses to `super.zst`
- Creates flashable zip with platform scripts

## Key configuration (`bin/port_config`)
- `partition_to_port`: comma-separated partitions extracted from source ROM
- `possible_super_list`: candidate super partition list
- `repack_with_ext4`: ext4 repack toggle (default false)
- `remove_data_encryption`: data encryption behavior toggle
- `super_extended`: manual super extension toggle
- `pack_method`: output mode (`stock` or flashable)

## High-level workflow
1. Validate arguments and tools.
2. Detect ROM package format (`payload`, `img`, or `dat.br` for base).
3. Extract base and source partitions.
4. Apply device/common patches.
5. Repack modified images.
6. Disable vbmeta verification images.
7. Package final output.

## Output locations
- Final zips: `out/`
- Working images: `build/`
- Temporary edits: `tmp/`

## Common warnings and what they mean
- `Kaorios Toolbox: patcher directory not found — skipping`
	- non-fatal, build continues without that optional patch step

- `0001-core-framework-...patch not found; skipping`
	- optional patch file missing, non-fatal

- `perl: warning: Setting locale failed`
	- host locale issue, usually non-fatal for build

- `cp: cannot stat ...` for optional assets
	- missing optional file; may be harmless or device-feature-specific depending on what was missing

## Troubleshooting
- If a run fails, inspect the `[ERROR] Script died at line ...` output.
- Re-run after cleanup if needed:

```bash
sudo ./port.sh <base> <port>
```

`port.sh` already clears and recreates key working folders each run.

## Contributing
PRs and issues are welcome.

When reporting issues, include:
- full command used
- last 100+ lines of log
- base/source ROM names and versions
- device target folder used
