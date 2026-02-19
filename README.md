# qcom-firmware-updater.sh

Update Adreno GPU firmware on Snapdragon X Elite / X Plus laptops from Qualcomm's Windows Graphics Driver package.

> **Early release.** Always use `--dry-run` first to review changes before installing.

## Why

My goal is to keep the firmware up to date without requiring a dedicated Windows partition. The scripts retrieve the official Qualcomm Windows drivers and perform the firmware update from within a Linux environment.

This script:

- Downloads and extracts only the 17 firmware files Linux needs (~20MB)
- Cleans up Windows-only files (DLLs, SYS, EXE, CAT, INF, etc.)
- Compares checksums before installing to avoid unnecessary writes
- Updates initramfs automatically if display firmware changes
- Auto-detects your device from `/proc/device-tree/model`

## Quick run

```bash

curl -fsSL https://raw.githubusercontent.com/alejandroqh/qcom-firmware-updater/main/qcom-firmware-updater.sh | bash

```

The script will guide you through downloading and installing the latest firmware.

## Supported devices

Auto-detected from `/proc/device-tree/model`:

| SoC | Device | Firmware path |
|-----|--------|---------------|
| X Elite | Acer Swift 14 AI (SF14-11) | `x1e80100/ACER/SF14-11` |
| X Elite | ASUS Vivobook S 15 | `x1e80100/ASUSTeK/vivobook-s15` |
| X Plus | ASUS Zenbook A14 (UX3407QA) | `x1p42100/ASUSTeK/zenbook-a14` |
| X Elite | ASUS Zenbook A14 (UX3407RA) | `x1e80100/ASUSTeK/zenbook-a14` |
| X Elite | Dell Inspiron 14 Plus 7441 | `x1e80100/dell/inspiron-14-plus-7441` |
| X Elite | Dell Latitude 7455 | `x1e80100/dell/latitude-7455` |
| X Elite | Dell XPS 13 9345 | `x1e80100/dell/xps13-9345` |
| X Plus | HP EliteBook 6 G1q | `x1p42100/hp/elitebook-6-g1q` |
| X Elite | HP EliteBook Ultra G1q | `x1e80100/hp/elitebook-ultra-g1q` |
| X Plus | HP OmniBook 5 16" OLED | `x1p42100/hp/omnibook-5` |
| X Elite | HP Omnibook X 14 | `x1e80100/hp/omnibook-x14` |
| X Plus | Lenovo ThinkBook 16 Gen 7 | `x1p42100/LENOVO/21NH` |
| X Elite | Lenovo ThinkPad T14s Gen 6 | `x1e80100/LENOVO/21N1` |
| X Elite | Lenovo Yoga Slim 7x | `x1e80100/LENOVO/83ED` |
| X Elite | Microsoft Surface Laptop 7 | `x1e80100/microsoft/Romulus` |
| X Elite | Samsung Galaxy Book4 Edge | `x1e80100/SAMSUNG/galaxy-book4-edge` |

For unlisted devices, use `--device-path <soc/oem/board>`.

## Dependencies

```bash
sudo apt install 7zip msitools unzip curl
```

- `7zip` — extract WiX bootstrapper EXE and embedded CAB archives
- `msitools` — extract MSI with original filenames (7z mangles them into WiX internal IDs)
- `unzip` — extract outer ZIP from Qualcomm
- `curl` — download from URL (only needed with `--url`)

## Usage

```bash
# From a local ZIP (downloaded from Qualcomm Software Center)
./qcom-firmware-updater.sh ~/Downloads/Windows_Graphics_Driver.Core.251208031.0.133.2.Windows-ARM64.zip

# From a local EXE (already extracted from ZIP)
./qcom-firmware-updater.sh ~/Downloads/Qualcomm_Adreno_Driver-v31.0.133.2.exe

# Download directly from a URL
./qcom-firmware-updater.sh --url "https://softwarecenter.qualcomm.com/api/download/software/tools/Windows_Graphics_Driver/Windows/ARM64/251208031.0.133.2/Windows_Graphics_Driver.Core.251208031.0.133.2.Windows-ARM64.zip"

# Dry run — compare only, don't install (no sudo needed)
./qcom-firmware-updater.sh --dry-run ~/Downloads/Windows_Graphics_Driver.Core.*.zip

# Override device detection for an unlisted machine
./qcom-firmware-updater.sh --device-path x1e80100/dell/xps13-9345 driver.zip

# List supported devices
./qcom-firmware-updater.sh --list-devices
```

## How it works

The Qualcomm Graphics Driver package is a nested archive:

```
ZIP
 └── Qualcomm_Adreno_Driver-v*.exe    (WiX Burn bootstrapper, PE32)
      ├── UX payloads (manifest, DLL, icons)   ← extracted by 7z
      └── Attached container (CAB tail)         ← extracted by dd
           └── gfx_drivers_8380.msi             ← extracted by 7z
                └── QCDrivers/Drivers/.../       ← extracted by msiextract
                     ├── *.mbn, *.bin  (firmware) ✓
                     ├── *.dll, *.sys  (Windows)  ✗
                     └── *.cat, *.inf  (metadata) ✗
```

The extraction pipeline:

1. **ZIP → EXE** — `unzip` extracts the outer archive
2. **EXE → CAB** — `7z` extracts the WiX bootstrapper to read the tail size, then `dd` extracts the attached Microsoft Cabinet from the end of the EXE
3. **CAB → MSI** — `7z` extracts the Cabinet to get the MSI installer
4. **MSI → files** — `msiextract` (not `7z`) extracts with real filenames preserved

## Firmware files

The 17 files Linux uses from the Graphics Driver package:

| File | Purpose | Size |
|------|---------|------|
| `qcav1e8380.mbn` | AV1 video codec firmware | 4.4 MB |
| `qcdxkmbase8380.bin` | GPU kernel microcode (base) | 123 KB |
| `qcdxkmbase8380_{68,110,150}.bin` | GPU kernel microcode (OPP variants) | ~123 KB each |
| `qcdxkmbase8380_pa.bin` | GPU kernel microcode (power-adjusted base) | 124 KB |
| `qcdxkmbase8380_pa_{67,111,140}.bin` | GPU kernel microcode (PA OPP variants) | ~124 KB each |
| `qcdxkmsuc8380.mbn` | Display KMS microcontroller | 12 KB |
| `qcdxkmsucpurwa.mbn` | Display KMS (PURWA variant) | 12 KB |
| `qcvss8380.mbn` | Video subsystem firmware | 2.3 MB |
| `qcvss8380_pa.mbn` | Video subsystem (power-adjusted) | 2.3 MB |
| `sequence_manifest.bin` | Firmware load sequence descriptor | 2.8 KB |
| `unified_kbcs_{32,64}.bin` | Shader bitcode cache (32/64-bit) | 3.1 MB each |
| `unified_ksqs.bin` | Shader queue setup data | 453 KB |

Core GPU boot firmware (`gen71500_sqe.fw`, `gen71500_gmu.bin`, `gen71500_zap.mbn`) comes from the `linux-firmware` package and is **not** managed by this script.

## What happens on install

1. Backs up current firmware to `<firmware_dir>.bak-YYYYMMDD-HHMMSS/`
2. Copies changed/new firmware files with `root:root 0644` permissions
3. Removes Windows-only files (`.dll`, `.sys`, `.exe`, `.cat`, `.inf`, `.json`, `.so`, `.txt`) from the firmware directory
4. Runs `update-initramfs` if display KMS firmware (`qcdxkmsuc8380.mbn`) changed

## Complementary to qcom-firmware-extract

[qcom-firmware-extract](https://code.launchpad.net/ubuntu/+source/qcom-firmware-extract) pulls DSP firmware from a Windows partition, while this script pulls GPU, display, and video firmware from Qualcomm's driver installer, no Windows partition needed.

## Checking for new versions

Browse the [Qualcomm Software Center](https://softwarecenter.qualcomm.com/catalog/item/Windows_Graphics_Driver) for updated ARM64 Windows Graphics Drivers:
- Product: **Windows Graphics Driver**
- Platform: **Windows / ARM64**



The download URL pattern is:
```
https://softwarecenter.qualcomm.com/api/download/software/tools/Windows_Graphics_Driver/Windows/ARM64/{VERSION}/Windows_Graphics_Driver.Core.{VERSION}.Windows-ARM64.zip
```

Known versions:
- `251208031.0.133.2` — December 2025, driver v31.0.133.2

## Disclaimer

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

This script modifies system firmware files. Incorrect firmware can render your GPU or display non-functional. You are solely responsible for determining whether this script is suitable for your system. Always back up your data and verify changes with `--dry-run` before installing.
