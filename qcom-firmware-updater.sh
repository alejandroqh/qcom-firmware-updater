#!/usr/bin/env bash
#
# qcom-firmware-updater.sh — Update Adreno GPU firmware from Qualcomm Graphics Driver package
#
# Extracts Linux-relevant firmware files (.mbn/.bin) from a Qualcomm Windows
# Graphics Driver package (WiX bootstrapper EXE inside a ZIP) and installs
# them to /lib/firmware/qcom/<soc>/<oem>/<board>/.
#
# Supports all Snapdragon X Elite / X Plus machines known to qcom-firmware-extract.
# Auto-detects the device from /proc/device-tree/model, or use --device-path to override.
#
# Runs as a normal user; elevates with sudo only for the install step.
#
# Usage:
#   ./qcom-firmware-updater.sh /path/to/file.zip
#   ./qcom-firmware-updater.sh /path/to/file.exe
#   ./qcom-firmware-updater.sh --url "https://..."
#   ./qcom-firmware-updater.sh --dry-run /path/to/file.zip
#   ./qcom-firmware-updater.sh --device-path x1e80100/dell/xps13-9345 /path/to/file.zip
#   curl -fsSL <URL> | bash

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

VERSION="1.0.0"
FIRMWARE_BASE="/lib/firmware/qcom"

# Firmware files Linux actually uses (from the Qualcomm Graphics Driver)
FIRMWARE_FILES=(
    qcav1e8380.mbn
    qcdxkmbase8380.bin
    qcdxkmbase8380_68.bin
    qcdxkmbase8380_110.bin
    qcdxkmbase8380_150.bin
    qcdxkmbase8380_pa.bin
    qcdxkmbase8380_pa_67.bin
    qcdxkmbase8380_pa_111.bin
    qcdxkmbase8380_pa_140.bin
    qcdxkmsuc8380.mbn
    qcdxkmsucpurwa.mbn
    qcvss8380.mbn
    qcvss8380_pa.mbn
    sequence_manifest.bin
    unified_kbcs_32.bin
    unified_kbcs_64.bin
    unified_ksqs.bin
)

# Windows-only file extensions to clean from firmware dir
WINDOWS_EXTS=(dll sys exe cat inf json so txt)

# ── Globals ──────────────────────────────────────────────────────────────────

TMPDIR=""
DRY_RUN=false
INPUT_URL=""
INPUT_FILE=""
DEVICE_PATH=""
FIRMWARE_DIR=""

# ── Helpers ──────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ":: $*" >&2; }
warn() { echo "WARNING: $*" >&2; }

cleanup() {
    if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

# ── Device Detection ─────────────────────────────────────────────────────────

# Device table matching qcom-firmware-extract (v17) plus additional machines.
# Maps /proc/device-tree/model → firmware path under /lib/firmware/qcom/.
detect_device() {
    local model
    if [[ ! -r /proc/device-tree/model ]]; then
        die "Cannot read /proc/device-tree/model. Use --device-path to specify manually."
    fi
    model="$(tr -d '\0' </proc/device-tree/model)"
    info "Detected device: $model"

    case "$model" in
        "Acer Swift 14 AI (SF14-11)")
            DEVICE_PATH="x1e80100/ACER/SF14-11"
            ;;
        "ASUS Vivobook S 15")
            DEVICE_PATH="x1e80100/ASUSTeK/vivobook-s15"
            ;;
        "ASUS Zenbook A14 (UX3407QA)"|"ASUS Zenbook A14 (UX3407QA, LCD)"|"ASUS Zenbook A14 (UX3407QA, OLED)")
            DEVICE_PATH="x1p42100/ASUSTeK/zenbook-a14"
            ;;
        "ASUS Zenbook A14 (UX3407RA)")
            DEVICE_PATH="x1e80100/ASUSTeK/zenbook-a14"
            ;;
        "Dell Inspiron 14 Plus 7441")
            DEVICE_PATH="x1e80100/dell/inspiron-14-plus-7441"
            ;;
        "Dell Latitude 7455")
            DEVICE_PATH="x1e80100/dell/latitude-7455"
            ;;
        "Dell XPS 13 9345")
            DEVICE_PATH="x1e80100/dell/xps13-9345"
            ;;
        "HP EliteBook 6 G1q"*)
            DEVICE_PATH="x1p42100/hp/elitebook-6-g1q"
            ;;
        "HP EliteBook Ultra G1q")
            DEVICE_PATH="x1e80100/hp/elitebook-ultra-g1q"
            ;;
        "HP OmniBook 5"*)
            DEVICE_PATH="x1p42100/hp/omnibook-5"
            ;;
        "HP Omnibook X 14")
            DEVICE_PATH="x1e80100/hp/omnibook-x14"
            ;;
        "Lenovo ThinkBook 16 Gen 7"*)
            DEVICE_PATH="x1p42100/LENOVO/21NH"
            ;;
        "Lenovo ThinkPad T14s Gen 6")
            DEVICE_PATH="x1e80100/LENOVO/21N1"
            ;;
        "Lenovo Yoga Slim 7x")
            DEVICE_PATH="x1e80100/LENOVO/83ED"
            ;;
        "Microsoft Surface Laptop 7 (13.8 inch)"|"Microsoft Surface Laptop 7 (15 inch)")
            DEVICE_PATH="x1e80100/microsoft/Romulus"
            ;;
        "Samsung Galaxy Book4 Edge")
            DEVICE_PATH="x1e80100/SAMSUNG/galaxy-book4-edge"
            ;;
        *)
            die "Unsupported device: $model
Use --device-path <soc/oem/board> to specify manually.
Run with --list-devices to see supported machines."
            ;;
    esac

    info "Firmware path: $FIRMWARE_BASE/$DEVICE_PATH"
}

list_devices() {
    cat <<'EOF'
Supported devices (from qcom-firmware-extract device table):

  SoC             OEM/Model                           Firmware path
  ─────────────   ─────────────────────────────────   ─────────────────────────────────────────
  X Elite (80100) Acer Swift 14 AI (SF14-11)          x1e80100/ACER/SF14-11
  X Elite (80100) ASUS Vivobook S 15                  x1e80100/ASUSTeK/vivobook-s15
  X Plus  (42100) ASUS Zenbook A14 (UX3407QA)         x1p42100/ASUSTeK/zenbook-a14
  X Elite (80100) ASUS Zenbook A14 (UX3407RA)         x1e80100/ASUSTeK/zenbook-a14
  X Elite (80100) Dell Inspiron 14 Plus 7441          x1e80100/dell/inspiron-14-plus-7441
  X Elite (80100) Dell Latitude 7455                  x1e80100/dell/latitude-7455
  X Elite (80100) Dell XPS 13 9345                    x1e80100/dell/xps13-9345
  X Plus  (42100) HP EliteBook 6 G1q                  x1p42100/hp/elitebook-6-g1q
  X Elite (80100) HP EliteBook Ultra G1q              x1e80100/hp/elitebook-ultra-g1q
  X Plus  (42100) HP OmniBook 5 16" OLED               x1p42100/hp/omnibook-5
  X Elite (80100) HP Omnibook X 14                    x1e80100/hp/omnibook-x14
  X Plus  (42100) Lenovo ThinkBook 16 Gen 7           x1p42100/LENOVO/21NH
  X Elite (80100) Lenovo ThinkPad T14s Gen 6          x1e80100/LENOVO/21N1
  X Elite (80100) Lenovo Yoga Slim 7x                 x1e80100/LENOVO/83ED
  X Elite (80100) Microsoft Surface Laptop 7          x1e80100/microsoft/Romulus
  X Elite (80100) Samsung Galaxy Book4 Edge           x1e80100/SAMSUNG/galaxy-book4-edge

For unlisted devices, use --device-path <soc/oem/board>.
EOF
}

# ── Functions ────────────────────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --url)
                [[ $# -ge 2 ]] || die "--url requires an argument"
                INPUT_URL="$2"
                shift 2
                ;;
            --device-path)
                [[ $# -ge 2 ]] || die "--device-path requires an argument (e.g. x1e80100/dell/xps13-9345)"
                DEVICE_PATH="$2"
                shift 2
                ;;
            --list-devices)
                list_devices
                exit 0
                ;;
            -V|--version)
                echo "qcom-firmware-updater $VERSION"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                [[ -z "$INPUT_FILE" ]] || die "Only one input file allowed"
                INPUT_FILE="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$INPUT_URL" && -z "$INPUT_FILE" ]]; then
        interactive_prompt
    fi
    if [[ -n "$INPUT_URL" && -n "$INPUT_FILE" ]]; then
        die "Specify either --url or a file path, not both"
    fi
}

interactive_prompt() {
    # Open a terminal fd for interactive reads (works even when piped)
    local tty_fd
    if [[ -t 0 ]]; then
        tty_fd=0
    elif [[ -c /dev/tty ]]; then
        exec 3</dev/tty
        tty_fd=3
    else
        die "No terminal available for interactive prompts. Provide arguments on the command line."
    fi

    cat >&2 <<EOF

  qcom-firmware-updater v${VERSION}

  Adreno GPU firmware updater for Snapdragon X Elite / X Plus

EOF

    # Check OS and architecture — this script only works on Linux aarch64
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    if [[ "$os" != "Linux" || "$arch" != "aarch64" ]]; then
        die "This script requires Linux on ARM64 (aarch64). Detected: $os $arch"
    fi

    # Dry run by default
    local dry_run_answer
    read -r -p "Dry run (compare only, no changes)? [Y/n]: " dry_run_answer <&$tty_fd
    dry_run_answer="${dry_run_answer:-Y}"
    if [[ "$dry_run_answer" =~ ^[Yy] ]]; then
        DRY_RUN=true
    fi

    cat >&2 <<EOF

  Download the latest ARM64 Windows Graphics Driver from:
  https://softwarecenter.qualcomm.com/catalog/item/Windows_Graphics_Driver

  You can paste the download URL or provide a path to an already-downloaded file.

EOF
    local input
    read -r -p "URL or file path: " input <&$tty_fd
    [[ -n "$input" ]] || die "No input provided"

    if [[ "$input" =~ ^https?:// ]]; then
        INPUT_URL="$input"
    else
        INPUT_FILE="$input"
    fi

    # If not dry run, confirm before modifying firmware
    if ! $DRY_RUN; then
        local confirm
        read -r -p "This will modify system firmware. Continue? [y/N]: " confirm <&$tty_fd
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            die "Aborted by user"
        fi
    fi

    # Close the tty fd if we opened one
    [[ $tty_fd -eq 3 ]] && exec 3<&-
}

usage() {
    cat <<'EOF'
Usage: qcom-firmware-updater.sh [OPTIONS] [FILE]

Update Adreno GPU firmware from a Qualcomm Windows Graphics Driver package.
Supports all Snapdragon X Elite / X Plus machines known to qcom-firmware-extract.

Arguments:
  FILE                        Local .zip or .exe driver package

Options:
  --url URL                   Download driver package from URL instead of local file
  --device-path SOC/OEM/BOARD Override auto-detected firmware install path
                              (e.g. x1e80100/dell/xps13-9345)
  --list-devices              Show supported devices and exit
  --dry-run                   Compare only, don't install
  -V, --version               Show version and exit
  -h, --help                  Show this help

Examples:
  # Auto-detect device, install from local ZIP (sudo prompted at install time)
  ./qcom-firmware-updater.sh ~/Downloads/Windows_Graphics_Driver.Core.*.zip

  # Download driver package directly from Qualcomm
  ./qcom-firmware-updater.sh --url "https://softwarecenter.qualcomm.com/api/download/..."

  # Compare checksums without installing (no sudo needed)
  ./qcom-firmware-updater.sh --dry-run ~/Downloads/driver.zip

  # Unlisted device: manually specify where firmware gets installed
  ./qcom-firmware-updater.sh --device-path x1e80100/MYOEM/BOARD ~/Downloads/driver.zip

  # Pipe from curl (interactive prompts still work via /dev/tty)
  curl -fsSL <URL> | bash
EOF
}

check_deps() {
    local missing=()
    if ! command -v 7zz &>/dev/null && ! command -v 7z &>/dev/null; then
        missing+=(7zip)
    fi
    command -v msiextract &>/dev/null || missing+=(msitools)
    command -v unzip &>/dev/null || missing+=(unzip)
    command -v sha256sum &>/dev/null || missing+=(coreutils)
    if [[ -n "$INPUT_URL" ]]; then
        command -v curl &>/dev/null || missing+=(curl)
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}
Install with: sudo apt install ${missing[*]}"
    fi
}

# Get the 7z command (7zz from p7zip-full or 7z)
sz() {
    if command -v 7zz &>/dev/null; then
        7zz "$@"
    else
        7z "$@"
    fi
}

download_driver() {
    local dest="$1"
    info "Downloading driver package..."
    curl -fSL --progress-bar -o "$dest" "$INPUT_URL" \
        || die "Download failed from: $INPUT_URL"
    info "Downloaded to $dest"
}

extract_exe() {
    local input="$1"
    local extract_root="$TMPDIR/extract"
    mkdir -p "$extract_root"

    local exe_path=""

    # Determine input type
    case "$input" in
        *.zip|*.ZIP)
            info "Extracting ZIP archive..."
            local zip_out="$extract_root/zip"
            mkdir -p "$zip_out"
            unzip -q "$input" -d "$zip_out" || die "Failed to extract ZIP"

            # Find the .exe inside
            exe_path=$(find "$zip_out" -maxdepth 3 -name '*.exe' -type f | head -1)
            [[ -n "$exe_path" ]] || die "No .exe found inside ZIP archive"
            info "Found EXE: $(basename "$exe_path")"
            ;;
        *.exe|*.EXE)
            exe_path="$input"
            ;;
        *)
            die "Unsupported file type: $input (expected .zip or .exe)"
            ;;
    esac

    # Stage 1: Extract WiX Burn bootstrapper EXE with 7z
    # This gets the UX payloads (XML manifest, DLLs, icons) but NOT the
    # attached container which holds the MSI. 7z reports it as "Tail Size".
    info "Stage 1: Extracting WiX bootstrapper..."
    local stage1="$extract_root/stage1"
    mkdir -p "$stage1"
    local sz_output
    sz_output=$(sz x "$exe_path" -o"$stage1" -y 2>&1) \
        || die "Failed to extract EXE (is 7zip installed?)"

    # Stage 2: Extract the WiX attached container (MSI inside a CAB tail)
    # The WiX Burn format appends the MSI payload as a Microsoft Cabinet
    # archive at the end of the EXE. 7z reports its size as "Tail Size".
    info "Stage 2: Extracting attached container..."
    local tail_size
    tail_size=$(echo "$sz_output" | sed -n 's/^Tail Size = //p')
    if [[ -z "$tail_size" || "$tail_size" -eq 0 ]]; then
        die "No attached container found in EXE (not a WiX Burn bundle?)"
    fi

    local exe_size
    exe_size=$(stat -c%s "$exe_path")
    local tail_offset=$((exe_size - tail_size))

    # Extract the CAB using efficient block-aligned dd
    local attached_cab="$extract_root/attached.cab"
    local bs=65536
    local skip_blocks=$((tail_offset / bs))
    local skip_remainder=$((tail_offset % bs))

    if [[ $skip_remainder -eq 0 ]]; then
        dd if="$exe_path" of="$attached_cab" bs="$bs" skip="$skip_blocks" 2>/dev/null
    else
        # Not block-aligned: skip whole blocks first, then trim leading bytes
        dd if="$exe_path" bs="$bs" skip="$skip_blocks" 2>/dev/null \
            | dd of="$attached_cab" bs=1 skip="$skip_remainder" 2>/dev/null
    fi

    [[ -s "$attached_cab" ]] || die "Failed to extract attached container"

    # Extract the CAB to get the MSI
    local cab_out="$extract_root/cab"
    mkdir -p "$cab_out"
    sz x "$attached_cab" -o"$cab_out" -y >/dev/null 2>&1 \
        || die "Failed to extract attached CAB"
    rm -f "$attached_cab"

    # Stage 3: Extract the MSI with msiextract (preserves real filenames)
    info "Stage 3: Extracting MSI contents..."
    local msi_path
    msi_path=$(find "$cab_out" -maxdepth 1 -type f | head -1)
    [[ -n "$msi_path" ]] || die "No MSI found in attached container"

    local msi_out="$extract_root/msi"
    mkdir -p "$msi_out"
    (cd "$msi_out" && msiextract "$msi_path" >/dev/null 2>&1) \
        || die "Failed to extract MSI (is msitools installed?)"
    rm -f "$msi_path"

    echo "$extract_root"
}

find_firmware() {
    local extract_root="$1"
    local fw_staging="$TMPDIR/firmware"
    mkdir -p "$fw_staging"

    local found=0
    for fw_name in "${FIRMWARE_FILES[@]}"; do
        # Search case-insensitively through all extracted stages
        local fw_path
        fw_path=$(find "$extract_root" -iname "$fw_name" -type f 2>/dev/null | head -1)
        if [[ -n "$fw_path" ]]; then
            cp "$fw_path" "$fw_staging/$fw_name"
            ((found++))
        fi
    done

    if [[ $found -eq 0 ]]; then
        die "No firmware files found in extracted package. Extraction may have failed or this is not a Qualcomm Graphics Driver package."
    fi

    info "Found $found/${#FIRMWARE_FILES[@]} firmware files"
    echo "$fw_staging"
}

compare_firmware() {
    local fw_staging="$1"

    printf "\n%-35s  %-8s  %-10s\n" "File" "Status" "Size (new)"
    printf "%-35s  %-8s  %-10s\n" "---" "------" "----------"

    local changed=0 same=0 new_fw=0 missing=0

    for fw_name in "${FIRMWARE_FILES[@]}"; do
        local new_file="$fw_staging/$fw_name"
        local cur_file="$FIRMWARE_DIR/$fw_name"

        if [[ ! -f "$new_file" ]]; then
            printf "%-35s  %-8s  %s\n" "$fw_name" "SKIP" "(not in package)"
            ((missing++))
            continue
        fi

        local new_size
        new_size=$(stat -c%s "$new_file")
        local new_size_h
        new_size_h=$(numfmt --to=iec-i --suffix=B "$new_size" 2>/dev/null || echo "${new_size}B")

        if [[ ! -f "$cur_file" ]]; then
            printf "%-35s  \e[33m%-8s\e[0m  %s\n" "$fw_name" "NEW" "$new_size_h"
            ((new_fw++))
            continue
        fi

        local cur_hash new_hash
        cur_hash=$(sha256sum "$cur_file" | cut -d' ' -f1)
        new_hash=$(sha256sum "$new_file" | cut -d' ' -f1)

        if [[ "$cur_hash" == "$new_hash" ]]; then
            printf "%-35s  %-8s  %s\n" "$fw_name" "SAME" "$new_size_h"
            ((same++))
        else
            printf "%-35s  \e[32m%-8s\e[0m  %s\n" "$fw_name" "CHANGED" "$new_size_h"
            ((changed++))
        fi
    done

    printf "\nSummary: %d changed, %d new, %d same, %d not in package\n" \
        "$changed" "$new_fw" "$same" "$missing"

    # Return non-zero if nothing to update
    [[ $((changed + new_fw)) -gt 0 ]]
}

install_firmware() {
    local fw_staging="$1"

    # Validate sudo credentials upfront (one password prompt before work begins)
    info "Requesting elevated privileges for firmware installation..."
    sudo -v || die "Failed to obtain sudo credentials"

    # Create firmware directory if it doesn't exist
    [[ -d "$FIRMWARE_DIR" ]] || sudo mkdir -p "$FIRMWARE_DIR"

    # Backup current firmware
    local backup_dir="${FIRMWARE_DIR}.bak-$(date +%Y%m%d-%H%M%S)"
    info "Backing up current firmware to $backup_dir"
    sudo cp -a "$FIRMWARE_DIR" "$backup_dir"

    # Install new firmware files
    local installed=0
    local kms_changed=false

    for fw_name in "${FIRMWARE_FILES[@]}"; do
        local new_file="$fw_staging/$fw_name"
        [[ -f "$new_file" ]] || continue

        local cur_file="$FIRMWARE_DIR/$fw_name"

        # Skip if identical
        if [[ -f "$cur_file" ]]; then
            local cur_hash new_hash
            cur_hash=$(sha256sum "$cur_file" | cut -d' ' -f1)
            new_hash=$(sha256sum "$new_file" | cut -d' ' -f1)
            [[ "$cur_hash" != "$new_hash" ]] || continue
        fi

        sudo cp "$new_file" "$cur_file"
        sudo chmod 0644 "$cur_file"
        sudo chown root:root "$cur_file"
        ((installed++))

        # Track if display firmware changed (needs initramfs update)
        if [[ "$fw_name" == "qcdxkmsuc8380.mbn" || "$fw_name" == "qcdxkmsucpurwa.mbn" ]]; then
            kms_changed=true
        fi
    done

    info "Installed $installed firmware file(s)"

    # Clean up Windows-only files
    cleanup_windows_files

    # Update initramfs if display firmware changed
    if $kms_changed; then
        info "Display firmware changed — updating initramfs..."
        sudo update-initramfs -u -k "$(uname -r)"
        info "Initramfs updated"
    fi
}

cleanup_windows_files() {
    local removed=0
    local freed=0

    for ext in "${WINDOWS_EXTS[@]}"; do
        while IFS= read -r -d '' winfile; do
            local fsize
            fsize=$(stat -c%s "$winfile" 2>/dev/null || echo 0)
            sudo rm -f "$winfile"
            ((removed++))
            freed=$((freed + fsize))
        done < <(find "$FIRMWARE_DIR" -maxdepth 1 -type f -name "*.${ext}" -print0 2>/dev/null)
    done

    if [[ $removed -gt 0 ]]; then
        local freed_h
        freed_h=$(numfmt --to=iec-i --suffix=B "$freed" 2>/dev/null || echo "${freed}B")
        info "Cleaned up $removed Windows-only file(s), freed $freed_h"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    [[ $EUID -ne 0 ]] || warn "No need to run as root — sudo is used only when needed."
    parse_args "$@"
    check_deps

    # Resolve device firmware path
    if [[ -z "$DEVICE_PATH" ]]; then
        detect_device
    else
        info "Using manual device path: $DEVICE_PATH"
    fi
    FIRMWARE_DIR="$FIRMWARE_BASE/$DEVICE_PATH"

    TMPDIR=$(mktemp -d /tmp/qcom-fw-update.XXXXXX)

    local input_path=""

    if [[ -n "$INPUT_URL" ]]; then
        input_path="$TMPDIR/download.zip"
        download_driver "$input_path"
    else
        [[ -f "$INPUT_FILE" ]] || die "File not found: $INPUT_FILE"
        input_path="$INPUT_FILE"
    fi

    local extract_root
    extract_root=$(extract_exe "$input_path")

    local fw_staging
    fw_staging=$(find_firmware "$extract_root")

    if compare_firmware "$fw_staging"; then
        if $DRY_RUN; then
            info "Dry run — no changes made"
        else
            echo
            install_firmware "$fw_staging"
            info "Done. Reboot to load updated firmware."
        fi
    else
        info "All firmware files are up to date — nothing to do"
    fi
}

main "$@"
