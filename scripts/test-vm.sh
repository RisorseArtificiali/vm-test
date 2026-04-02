#!/usr/bin/env bash
#
# test-vm.sh — Disposable GUI VM launcher for testing on vanilla OS
#
# Linux VMs (libvirt):
#   Base:     Clean OS install        (e.g., Fedora43-base)
#   Prepared: Custom setup on base    (e.g., Fedora43-devtools)
#   Test VM:  Disposable COW overlay  (destroyed after use)
#
# macOS VMs (quickemu):
#   Downloaded and launched via quickget/quickemu
#
# Prerequisites:
#   sudo dnf install qemu-kvm libvirt virt-install virt-viewer genisoimage
#   sudo systemctl enable --now libvirtd
#   sudo usermod -aG libvirt $USER  (then re-login)
#   Optional: sudo dnf install quickemu  (for macOS support)
#

set -e

# ── Config ───────────────────────────────────────────────────────────
IMAGE_DIR="$HOME/.local/share/lince-test-vms"
mkdir -p "$IMAGE_DIR"

declare -A DEFAULT_ISOS
DEFAULT_ISOS["Fedora43"]="https://download.fedoraproject.org/pub/fedora/linux/releases/43/Workstation/x86_64/iso/Fedora-Workstation-Live-43-1.6.x86_64.iso"
DEFAULT_ISOS["Ubuntu2404"]="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-desktop-amd64.iso"

VM_CPUS=4
VM_RAM=16384      # 16 GB
VM_DISK=40        # GB

# ── macOS / Quickemu Config ─────────────────────────────────────────
MACOS_DIR="$HOME/.local/share/vm-test-macos"
mkdir -p "$MACOS_DIR"

MACOS_VERSIONS=("sequoia" "sonoma" "ventura" "monterey")
declare -A MACOS_YEARS
MACOS_YEARS["monterey"]="2021"
MACOS_YEARS["ventura"]="2022"
MACOS_YEARS["sonoma"]="2023"
MACOS_YEARS["sequoia"]="2024"

HAS_QUICKEMU=false
if command -v quickemu &>/dev/null && command -v quickget &>/dev/null; then
    HAS_QUICKEMU=true
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────

os_variant_for() {
    local label="$1"
    # Try to extract version and build a valid os-variant
    case "$label" in
        [Ff]edora[0-9]*)
            local ver; ver=$(echo "$label" | grep -oP '(?i)fedora\K[0-9]+')
            echo "fedora${ver}" ;;
        [Uu]buntu[0-9]*)
            local ver; ver=$(echo "$label" | grep -oP '(?i)ubuntu\K[0-9]+')
            # Convert "2404" → "24.04", "2210" → "22.10"
            if [ ${#ver} -eq 4 ]; then
                echo "ubuntu${ver:0:2}.${ver:2:2}"
            else
                echo "ubuntu${ver}"
            fi ;;
        *)  echo "linux2022" ;;
    esac
}

distro_type_for() {
    case "$1" in
        [Ff]edora*) echo "fedora" ;;
        [Uu]buntu*) echo "ubuntu" ;;
        *)          echo "generic" ;;
    esac
}

file_size_or_dash() {
    [ -f "$1" ] && du -h "$1" | cut -f1 || echo "—"
}

cleanup_stale_refs() {
    local pattern="$1"
    for vm in $(virsh list --all --name 2>/dev/null | grep "^lince-"); do
        if virsh dumpxml "$vm" 2>/dev/null | grep -q "$pattern"; then
            echo -e "${YELLOW}Cleaning stale VM: ${vm}...${NC}"
            virsh destroy "$vm" 2>/dev/null || true
            virsh undefine "$vm" --remove-all-storage 2>/dev/null \
                || virsh undefine "$vm" 2>/dev/null || true
        fi
    done
}

cleanup_vm_def() {
    local vm_name="$1"
    if virsh dominfo "$vm_name" &>/dev/null; then
        virsh destroy "$vm_name" 2>/dev/null || true
        virsh undefine "$vm_name" --remove-all-storage 2>/dev/null \
            || virsh undefine "$vm_name" 2>/dev/null || true
    fi
}

# ── Image Discovery ──────────────────────────────────────────────────

# Base labels: files matching *-base.qcow2 → strip suffix
get_base_labels() {
    for f in "$IMAGE_DIR"/*-base.qcow2; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f" .qcow2)
        echo "${n%-base}"
    done
}

# Prepared image names: *.qcow2 that aren't bases or test overlays
get_prepared_names() {
    for f in "$IMAGE_DIR"/*.qcow2; do
        [ -f "$f" ] || continue
        local n; n=$(basename "$f" .qcow2)
        [[ "$n" == *-base ]] && continue
        [[ "$n" == lince-test-* ]] && continue
        echo "$n"
    done
}

# All launchable images (bases + prepared), sorted
get_all_images() {
    { get_base_labels | sed 's/$/-base/'; get_prepared_names; } | sort
}

# ── Picker ───────────────────────────────────────────────────────────

PICKED=""
PICKED_IDX=-1

pick_one() {
    local prompt="$1"; shift
    local items=("$@")
    local count=${#items[@]}
    [ "$count" -eq 0 ] && return 1

    for i in "${!items[@]}"; do
        echo -e "    ${BOLD}$((i+1))${NC})  ${items[$i]}"
    done
    echo ""
    while true; do
        read -rp "  $prompt [1-$count, q=cancel]: " choice
        [[ "$choice" =~ ^[qQ]$ ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            PICKED_IDX=$((choice - 1))
            PICKED="${items[$PICKED_IDX]}"
            return 0
        fi
        echo -e "${RED}  Invalid choice.${NC}"
    done
}

# ── Core Operations ──────────────────────────────────────────────────

download_iso() {
    local label="$1" url="$2"
    local dest="$IMAGE_DIR/${label}.iso"

    if [ -f "$dest" ]; then
        echo -e "${GREEN}✓ ISO exists: ${label}.iso${NC}"
        return 0
    fi

    echo -e "${CYAN}Downloading ISO for ${label}...${NC}"
    if ! curl --fail -L -# -o "$dest" "$url"; then
        rm -f "$dest"
        echo -e "${RED}✗ Download failed: $url${NC}"
        return 1
    fi

    local size
    size=$(stat --printf='%s' "$dest" 2>/dev/null || stat -f '%z' "$dest" 2>/dev/null)
    if [ "$size" -lt $((500 * 1024 * 1024)) ]; then
        rm -f "$dest"
        echo -e "${RED}✗ File too small (${size} bytes) — not a valid ISO.${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Downloaded: ${label}.iso${NC}"
}

install_base() {
    local label="$1" url="$2"
    local base="$IMAGE_DIR/${label}-base.qcow2"
    local iso="$IMAGE_DIR/${label}.iso"
    local vm_name="lince-base-${label}"

    download_iso "$label" "$url" || return 1

    cleanup_stale_refs "$(basename "$base")"
    cleanup_vm_def "$vm_name"
    rm -f "$base"

    echo ""
    echo -e "${YELLOW}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}${BOLD}  Installing: ${label}${NC}"
    echo -e "${YELLOW}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  A graphical installer will open. Complete the installation:"
    echo ""
    case "$(distro_type_for "$label")" in
        fedora)
            echo -e "  1. Click ${BOLD}Install to Hard Drive${NC} on the live desktop"
            echo -e "  2. Select language, click through"
            echo -e "  3. Installation Destination: select the disk, done"
            echo -e "  4. Create user: ${BOLD}tester${NC} / password: ${BOLD}tester${NC}"
            echo -e "  5. Begin installation, wait, reboot"
            ;;
        ubuntu)
            echo -e "  1. Choose ${BOLD}Install Ubuntu${NC}"
            echo -e "  2. Click through defaults"
            echo -e "  3. Create user: ${BOLD}tester${NC} / password: ${BOLD}tester${NC}"
            echo -e "  4. Wait for installation, restart"
            ;;
        *)
            echo -e "  Follow the distro installer."
            echo -e "  Suggested user: ${BOLD}tester${NC} / password: ${BOLD}tester${NC}"
            ;;
    esac
    echo ""
    echo -e "  After reboot + login, ${BOLD}shut down the VM${NC}."
    echo ""
    read -rp "  Press ENTER to start the installer..."

    qemu-img create -f qcow2 "$base" "${VM_DISK}G" >/dev/null

    virt-install \
        --name "$vm_name" \
        --memory $VM_RAM \
        --vcpus $VM_CPUS \
        --disk "path=$base,format=qcow2" \
        --cdrom "$iso" \
        --os-variant "$(os_variant_for "$label")" \
        --network default \
        --graphics spice,listen=none \
        --video qxl \
        --channel spicevmc \
        --boot cdrom,hd \
        --wait -1

    virsh undefine "$vm_name" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}${BOLD}✓ Base image created: ${label}-base${NC}"
    echo -e "  Size: $(file_size_or_dash "$base")"
    echo ""
}

prepare_image() {
    local base_label="$1" prep_name="$2"
    local full_name="${base_label}-${prep_name}"
    local base="$IMAGE_DIR/${base_label}-base.qcow2"
    local prep="$IMAGE_DIR/${full_name}.qcow2"
    local vm_name="lince-prepare-${full_name}"

    if [ ! -f "$base" ]; then
        echo -e "${RED}Base not found: ${base_label}-base${NC}"
        return 1
    fi

    cleanup_stale_refs "$(basename "$prep")"
    cleanup_vm_def "$vm_name"
    rm -f "$prep"

    echo ""
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  Preparing: ${full_name}${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  A VM will boot from ${BOLD}${base_label}-base${NC}."
    echo -e "  Install packages and configure what you need."
    echo ""
    echo -e "  When done, ${BOLD}shut down the VM${NC}."
    echo ""
    read -rp "  Press ENTER to start..."

    qemu-img create -f qcow2 -b "$base" -F qcow2 "$prep" "${VM_DISK}G" >/dev/null

    virt-install \
        --name "$vm_name" \
        --memory $VM_RAM \
        --vcpus $VM_CPUS \
        --disk "path=$prep,format=qcow2" \
        --os-variant "$(os_variant_for "$base_label")" \
        --network default \
        --graphics spice,listen=none \
        --video qxl \
        --channel spicevmc \
        --import \
        --wait -1

    virsh undefine "$vm_name" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}${BOLD}✓ Prepared image saved: ${full_name}${NC}"
    echo -e "  Size: $(file_size_or_dash "$prep") (delta from base)"
    echo ""
}

launch_vm() {
    local image_name="$1"
    local image_file="$IMAGE_DIR/${image_name}.qcow2"

    if [ ! -f "$image_file" ]; then
        echo -e "${RED}Image not found: $image_name${NC}"
        return 1
    fi

    local os_variant
    os_variant=$(os_variant_for "$image_name")

    local timestamp
    timestamp=$(date +%H%M%S)
    local vm_name="lince-test-${image_name}-${timestamp}"
    local overlay="$IMAGE_DIR/${vm_name}.qcow2"

    echo -e "${CYAN}Creating overlay from ${BOLD}${image_name}${NC}${CYAN}...${NC}"
    qemu-img create -f qcow2 -b "$image_file" -F qcow2 "$overlay" "${VM_DISK}G" >/dev/null

    echo -e "${CYAN}Launching VM: ${vm_name}...${NC}"
    virt-install \
        --name "$vm_name" \
        --memory $VM_RAM \
        --vcpus $VM_CPUS \
        --disk "path=$overlay,format=qcow2" \
        --os-variant "$os_variant" \
        --network default \
        --graphics spice,listen=none \
        --video qxl \
        --channel spicevmc \
        --import \
        --noautoconsole

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ${BOLD}VM: ${vm_name}${NC}"
    echo -e "${GREEN}║  ${DIM}From: ${image_name}${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  Login: tester / tester                                 ${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  Destroy:  $0 destroy ${vm_name}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${CYAN}Opening graphical display...${NC}"
    sleep 2
    virt-viewer --attach "$vm_name" 2>/dev/null &
    disown
    echo -e "${GREEN}✓ virt-viewer opened.${NC}"
}

list_vms() {
    echo ""
    echo -e "${BOLD}── Running VMs ──${NC}"
    echo ""
    local found=false
    for vm in $(virsh list --all --name 2>/dev/null | grep "^lince-test-"); do
        found=true
        local state
        state=$(virsh domstate "$vm" 2>/dev/null)
        if [ "$state" = "running" ]; then
            echo -e "  ${GREEN}●${NC} $vm  ${DIM}→ virt-viewer --attach $vm${NC}"
        else
            echo -e "  ${YELLOW}○${NC} $vm  ${DIM}($state)${NC}"
        fi
    done
    $found || echo -e "  ${DIM}No test VMs found.${NC}"
    echo ""
}

destroy_vm() {
    local vm_name="$1"
    if [ -z "$vm_name" ]; then
        echo -e "${RED}Usage: $0 destroy <vm-name>${NC}"
        exit 1
    fi
    echo -e "${CYAN}Destroying ${vm_name}...${NC}"
    virsh destroy "$vm_name" 2>/dev/null || true
    virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
    echo -e "${GREEN}✓ Destroyed${NC}"
}

destroy_all() {
    echo -e "${CYAN}Destroying all test VMs...${NC}"
    local found=false
    for vm in $(virsh list --all --name 2>/dev/null | grep "^lince-test-"); do
        found=true
        destroy_vm "$vm"
    done
    $found || echo -e "${DIM}  No test VMs to destroy.${NC}"
}

# ── macOS Operations (Quickemu) ──────────────────────────────────────

require_quickemu() {
    if ! $HAS_QUICKEMU; then
        echo -e "${RED}quickemu/quickget not found.${NC}"
        echo -e "Install: ${BOLD}sudo dnf install quickemu${NC}  or  https://github.com/quickemu-project/quickemu"
        return 1
    fi
}

# List installed macOS VMs (directories that have a matching .conf in MACOS_DIR)
get_macos_vms() {
    for conf in "$MACOS_DIR"/macos-*.conf; do
        [ -f "$conf" ] || continue
        local name; name=$(basename "$conf" .conf)
        [ -d "$MACOS_DIR/$name" ] && echo "$name"
    done
}

# Check if a quickemu macOS VM process is running
macos_vm_pid() {
    local vm_dir="$MACOS_DIR/$1"
    for pf in "$vm_dir"/*.pid; do
        [ -f "$pf" ] || continue
        local pid; pid=$(cat "$pf")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    done
    return 1
}

macos_install() {
    local version="$1"
    require_quickemu || return 1

    local vm_dir="$MACOS_DIR/macos-${version}"

    if [ -d "$vm_dir" ] && ls "$vm_dir"/disk.qcow2 &>/dev/null; then
        echo -e "${GREEN}✓ macOS ${version} already installed in ${vm_dir}${NC}"
        return 0
    fi

    echo -e "${CYAN}Downloading macOS ${version} via quickget...${NC}"
    echo -e "${DIM}  This downloads the recovery image from Apple and creates a disk image.${NC}"
    echo -e "${DIM}  First boot will run the macOS installer (~30-60 min).${NC}"
    echo ""

    # quickget creates macos-<version>/ directory itself, so run from MACOS_DIR
    (cd "$MACOS_DIR" && quickget macos "$version")

    if [ $? -eq 0 ] && [ -d "$vm_dir" ]; then
        echo -e "${GREEN}${BOLD}✓ macOS ${version} ready in ${vm_dir}${NC}"
    else
        echo -e "${RED}✗ quickget failed for macOS ${version}${NC}"
        return 1
    fi
}

macos_launch() {
    local version="$1"
    require_quickemu || return 1

    local vm_dir="$MACOS_DIR/macos-${version}"
    local conf
    conf=$(ls "$MACOS_DIR"/macos-${version}.conf 2>/dev/null | head -1)

    if [ -z "$conf" ]; then
        echo -e "${RED}No config found for macOS ${version}. Run install first.${NC}"
        return 1
    fi

    # Check if already running
    if macos_vm_pid "macos-${version}" &>/dev/null; then
        echo -e "${YELLOW}macOS ${version} is already running (PID $(macos_vm_pid "macos-${version}"))${NC}"
        return 0
    fi

    echo -e "${CYAN}Launching macOS ${version}...${NC}"
    # quickemu must run from MACOS_DIR since .conf uses relative paths
    (cd "$MACOS_DIR" && quickemu --vm "$(basename "$conf")" --display sdl) &
    disown

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ${BOLD}macOS ${version}${NC}"
    echo -e "${GREEN}║  ${DIM}Display: SDL window (from quickemu)${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║                                                          ${NC}"
    echo -e "${GREEN}║  ${BOLD}First boot — format the disk before installing:${NC}"
    echo -e "${GREEN}║    1. Open ${BOLD}Disk Utility${NC}"
    echo -e "${GREEN}║    2. View → Show All Devices                            ${NC}"
    echo -e "${GREEN}║    3. Select ${BOLD}QEMU HARDDISK${NC}${GREEN} (the whole disk)              ${NC}"
    echo -e "${GREEN}║    4. Erase → APFS, GUID Partition Map                   ${NC}"
    echo -e "${GREEN}║    5. Close Disk Utility → Reinstall macOS               ${NC}"
    echo -e "${GREEN}║                                                          ${NC}"
    echo -e "${GREEN}║  Later boots: straight to desktop                        ${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

macos_list() {
    echo ""
    echo -e "${BOLD}── macOS VMs (Quickemu) ──${NC}"
    echo ""
    local found=false
    for vm in $(get_macos_vms); do
        found=true
        local status disk_sz
        disk_sz="—"
        for qcow in "$MACOS_DIR/$vm"/*.qcow2; do
            [ -f "$qcow" ] && disk_sz=$(du -h "$qcow" | cut -f1) && break
        done
        if macos_vm_pid "$vm" &>/dev/null; then
            status="${GREEN}● running${NC} (PID $(macos_vm_pid "$vm"))"
        else
            status="${DIM}○ stopped${NC}"
        fi
        echo -e "  $vm  ${disk_sz}  ${status}"
    done
    $found || echo -e "  ${DIM}No macOS VMs installed.${NC}"
    echo ""
}

macos_destroy() {
    local vm="$1"
    local vm_dir="$MACOS_DIR/$vm"
    if [ ! -d "$vm_dir" ]; then
        echo -e "${RED}Not found: $vm${NC}"
        return 1
    fi
    # Kill if running
    if macos_vm_pid "$vm" &>/dev/null; then
        local pid; pid=$(macos_vm_pid "$vm")
        echo -e "${CYAN}Stopping macOS VM (PID $pid)...${NC}"
        kill "$pid" 2>/dev/null || true
        sleep 2
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -rf "$vm_dir"
    rm -f "$MACOS_DIR/${vm}.conf"
    echo -e "${GREEN}✓ Destroyed: $vm${NC}"
}

macos_destroy_all() {
    echo -e "${CYAN}Destroying all macOS VMs...${NC}"
    local found=false
    for vm in $(get_macos_vms); do
        found=true
        macos_destroy "$vm"
    done
    $found || echo -e "${DIM}  No macOS VMs to destroy.${NC}"
}

# ── TUI Actions ──────────────────────────────────────────────────────

action_launch() {
    mapfile -t images < <(get_all_images)
    if [ ${#images[@]} -eq 0 ]; then
        echo -e "${YELLOW}  No images available. Use ${BOLD}n${NC}${YELLOW} to install one first.${NC}"
        return
    fi

    # Build display list with sizes
    local display=()
    for img in "${images[@]}"; do
        local sz tag
        sz=$(file_size_or_dash "$IMAGE_DIR/${img}.qcow2")
        if [[ "$img" == *-base ]]; then
            tag="${GREEN}base${NC}"
        else
            tag="${CYAN}prep${NC}"
        fi
        display+=("$(printf '%-30s %b  %s' "$img" "$tag" "$sz")")
    done

    echo -e "  ${BOLD}Launch from which image?${NC}"
    echo ""
    if pick_one "Image" "${display[@]}"; then
        launch_vm "${images[$PICKED_IDX]}"
    fi
}

action_new_install() {
    # Build options: defaults + custom
    local labels=()
    local urls=()
    local display=()

    for label in $(printf '%s\n' "${!DEFAULT_ISOS[@]}" | sort); do
        labels+=("$label")
        urls+=("${DEFAULT_ISOS[$label]}")
        local exists=""
        [ -f "$IMAGE_DIR/${label}-base.qcow2" ] && exists="  ${DIM}(exists)${NC}"
        display+=("${label}${exists}")
    done
    labels+=("__custom__")
    urls+=("")
    display+=("Custom ISO URL")

    echo -e "  ${BOLD}Install from:${NC}"
    echo ""
    if ! pick_one "Choice" "${display[@]}"; then return; fi

    local label url
    if [ "${labels[$PICKED_IDX]}" = "__custom__" ]; then
        echo ""
        read -rp "  ISO download URL: " url
        [ -z "$url" ] && return
        read -rp "  Label (e.g., Fedora42, UbuntuNoble): " label
        [ -z "$label" ] && return
    else
        label="${labels[$PICKED_IDX]}"
        url="${urls[$PICKED_IDX]}"
    fi

    if [ -f "$IMAGE_DIR/${label}-base.qcow2" ]; then
        echo ""
        read -rp "  ${label}-base already exists. Overwrite? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return
    fi

    install_base "$label" "$url"
}

action_prepare() {
    mapfile -t bases < <(get_base_labels)
    if [ ${#bases[@]} -eq 0 ]; then
        echo -e "${YELLOW}  No base images. Use ${BOLD}n${NC}${YELLOW} to install one first.${NC}"
        return
    fi

    # Build display with sizes
    local display=()
    for b in "${bases[@]}"; do
        local sz
        sz=$(file_size_or_dash "$IMAGE_DIR/${b}-base.qcow2")
        display+=("${b}-base  ${DIM}${sz}${NC}")
    done

    echo -e "  ${BOLD}Customize which base?${NC}"
    echo ""
    if ! pick_one "Base" "${display[@]}"; then return; fi
    local base_label="${bases[$PICKED_IDX]}"

    echo ""
    read -rp "  Name for prepared image (e.g., devtools, java-dev): " prep_name
    [ -z "$prep_name" ] && return

    local full_name="${base_label}-${prep_name}"
    if [ -f "$IMAGE_DIR/${full_name}.qcow2" ]; then
        read -rp "  ${full_name} already exists. Overwrite? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return
    fi

    prepare_image "$base_label" "$prep_name"
}

action_macos() {
    require_quickemu || return

    echo -e "  ${BOLD}macOS VM:${NC}"
    echo ""
    local opts=("Launch / install a macOS version" "List macOS VMs" "Delete a macOS VM" "Delete all macOS VMs")
    if ! pick_one "Action" "${opts[@]}"; then return; fi

    case "$PICKED_IDX" in
        0)  # Launch / install
            local display=()
            for ver in "${MACOS_VERSIONS[@]}"; do
                local tag=""
                if [ -d "$MACOS_DIR/macos-${ver}" ]; then
                    if macos_vm_pid "macos-${ver}" &>/dev/null; then
                        tag="  ${GREEN}running${NC}"
                    else
                        tag="  ${DIM}installed${NC}"
                    fi
                fi
                display+=("macOS ${ver} (${MACOS_YEARS[$ver]})${tag}")
            done
            echo ""
            echo -e "  ${BOLD}Which version?${NC}"
            echo ""
            if ! pick_one "Version" "${display[@]}"; then return; fi
            local chosen="${MACOS_VERSIONS[$PICKED_IDX]}"

            if [ ! -d "$MACOS_DIR/macos-${chosen}" ] || ! ls "$MACOS_DIR/macos-${chosen}"/*.qcow2 &>/dev/null; then
                macos_install "$chosen" || return
            fi
            macos_launch "$chosen"
            ;;
        1)  macos_list ;;
        2)  # Delete one
            mapfile -t vms < <(get_macos_vms)
            if [ ${#vms[@]} -eq 0 ]; then
                echo -e "${DIM}  No macOS VMs to delete.${NC}"
                return
            fi
            local display=()
            for vm in "${vms[@]}"; do
                local sz="—"
                for qcow in "$MACOS_DIR/$vm"/*.qcow2; do
                    [ -f "$qcow" ] && sz=$(du -h "$qcow" | cut -f1) && break
                done
                display+=("${vm}  ${DIM}${sz}${NC}")
            done
            echo ""
            echo -e "  ${BOLD}Delete which macOS VM?${NC}"
            echo ""
            if ! pick_one "VM" "${display[@]}"; then return; fi
            local target="${vms[$PICKED_IDX]}"
            echo ""
            read -rp "  Delete ${target}? This removes the entire disk. [y/N]: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && macos_destroy "$target"
            ;;
        3)  # Delete all
            echo ""
            read -rp "  Destroy ALL macOS VMs? [y/N]: " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] && macos_destroy_all
            ;;
    esac
}

action_delete() {
    mapfile -t images < <(get_all_images)
    if [ ${#images[@]} -eq 0 ]; then
        echo -e "${DIM}  No images to delete.${NC}"
        return
    fi

    local display=()
    for img in "${images[@]}"; do
        local sz tag
        sz=$(file_size_or_dash "$IMAGE_DIR/${img}.qcow2")
        if [[ "$img" == *-base ]]; then
            tag="${GREEN}base${NC}"
        else
            tag="${CYAN}prep${NC}"
        fi
        display+=("$(printf '%-30s %b  %s' "$img" "$tag" "$sz")")
    done

    echo -e "  ${BOLD}Delete which image?${NC}"
    echo ""
    if ! pick_one "Image" "${display[@]}"; then return; fi
    local target="${images[$PICKED_IDX]}"

    # Warn if deleting a base that has prepared images depending on it
    if [[ "$target" == *-base ]]; then
        local base_label="${target%-base}"
        local deps=()
        for p in $(get_prepared_names); do
            [[ "$p" == "${base_label}-"* ]] && deps+=("$p")
        done
        if [ ${#deps[@]} -gt 0 ]; then
            echo ""
            echo -e "  ${YELLOW}Warning: these prepared images depend on ${target}:${NC}"
            for d in "${deps[@]}"; do
                echo -e "    ${d}"
            done
            echo -e "  ${YELLOW}They will become unusable if you delete the base.${NC}"
        fi
    fi

    echo ""
    read -rp "  Delete ${target}? This cannot be undone. [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cleanup_stale_refs "$(basename "$IMAGE_DIR/${target}.qcow2")"
        rm -f "$IMAGE_DIR/${target}.qcow2"
        echo -e "${GREEN}✓ Deleted: ${target}${NC}"
    fi
}

# ── TUI Main Menu ────────────────────────────────────────────────────

show_menu() {
    while true; do
        mapfile -t all_images < <(get_all_images)

        local vm_count=0
        for vm in $(virsh list --name 2>/dev/null | grep "^lince-test-"); do
            vm_count=$((vm_count + 1))
        done

        echo ""
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}${BOLD}              Test VM Manager${NC}"
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════${NC}"
        echo ""

        if [ ${#all_images[@]} -gt 0 ]; then
            echo -e "  ${BOLD}Linux Images:${NC}"
            for img in "${all_images[@]}"; do
                local sz tag
                sz=$(file_size_or_dash "$IMAGE_DIR/${img}.qcow2")
                if [[ "$img" == *-base ]]; then
                    tag="${GREEN}base${NC}"
                else
                    tag="${CYAN}prep${NC}"
                fi
                printf "    %-30s %b  %s\n" "$img" "$tag" "$sz"
            done
        else
            echo -e "  ${DIM}No Linux images yet. Use ${BOLD}n${NC}${DIM} to install one.${NC}"
        fi

        # Show macOS VMs if quickemu available
        if $HAS_QUICKEMU; then
            local macos_vms
            mapfile -t macos_vms < <(get_macos_vms)
            if [ ${#macos_vms[@]} -gt 0 ]; then
                echo ""
                echo -e "  ${BOLD}macOS VMs ${DIM}(quickemu)${NC}${BOLD}:${NC}"
                for vm in "${macos_vms[@]}"; do
                    local sz="—" status_tag
                    for qcow in "$MACOS_DIR/$vm"/*.qcow2; do
                        [ -f "$qcow" ] && sz=$(du -h "$qcow" | cut -f1) && break
                    done
                    if macos_vm_pid "$vm" &>/dev/null; then
                        status_tag="${GREEN}running${NC}"
                    else
                        status_tag="${DIM}stopped${NC}"
                    fi
                    printf "    %-30s %b  %s\n" "$vm" "$status_tag" "$sz"
                done
            fi
        fi

        echo ""
        echo -e "  ${BOLD}s${NC})  Start test VM ${DIM}(Linux)${NC}"
        echo -e "  ${BOLD}n${NC})  New OS install from ISO"
        echo -e "  ${BOLD}p${NC})  Prepare image ${DIM}(customize a base)${NC}"
        echo -e "  ${BOLD}d${NC})  Delete an image"
        if $HAS_QUICKEMU; then
            echo ""
            echo -e "  ${BOLD}m${NC})  macOS VM ${DIM}(via quickemu)${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}l${NC})  List running VMs ${DIM}($vm_count active)${NC}"
        echo -e "  ${BOLD}x${NC})  Destroy all test VMs"
        echo ""
        echo -e "  ${BOLD}q${NC})  Quit"
        echo ""

        read -rp "  Choose: " choice
        echo ""

        case "$choice" in
            s|S) action_launch ;;
            n|N) action_new_install ;;
            p|P) action_prepare ;;
            d|D) action_delete ;;
            m|M) action_macos ;;
            l|L) list_vms ; $HAS_QUICKEMU && macos_list ;;
            x|X) destroy_all ; $HAS_QUICKEMU && macos_destroy_all ;;
            q|Q) return ;;
            *)   echo -e "${RED}  Invalid choice.${NC}" ;;
        esac
    done
}

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    echo -e "${BOLD}test-vm.sh${NC} — Disposable GUI VMs for testing on vanilla OS"
    echo ""
    echo "Usage:"
    echo "  $0                  Interactive TUI"
    echo "  $0 list             Show VMs and images"
    echo "  $0 destroy <name>   Destroy a specific VM"
    echo "  $0 destroy-all      Destroy all test VMs"
    echo ""
    echo "Linux images (libvirt):"
    echo "  <Label>-base        Clean OS install (e.g., Fedora43-base)"
    echo "  <Label>-<name>      Prepared image   (e.g., Fedora43-devtools)"
    echo "  lince-test-*        Disposable test VM overlays"
    echo ""
    echo "macOS VMs (quickemu — optional):"
    echo "  Requires: quickemu, quickget"
    echo "  Install:  sudo dnf install quickemu"
    echo ""
    echo "Linux login: tester / tester"
    echo "Linux images: $IMAGE_DIR"
    echo "macOS VMs:    $MACOS_DIR"
}

# ── Main ─────────────────────────────────────────────────────────────
case "${1:-}" in
    "")
        show_menu
        ;;
    list)
        list_vms
        mapfile -t all_images < <(get_all_images)
        if [ ${#all_images[@]} -gt 0 ]; then
            echo -e "${BOLD}── Linux Images ──${NC}"
            echo ""
            for img in "${all_images[@]}"; do
                local sz tag
                sz=$(file_size_or_dash "$IMAGE_DIR/${img}.qcow2")
                if [[ "$img" == *-base ]]; then
                    tag="${GREEN}base${NC}"
                else
                    tag="${CYAN}prep${NC}"
                fi
                printf "  %-30s %b  %s\n" "$img" "$tag" "$sz"
            done
            echo ""
        fi
        $HAS_QUICKEMU && macos_list
        ;;
    destroy)
        destroy_vm "$2"
        ;;
    destroy-all)
        destroy_all
        $HAS_QUICKEMU && macos_destroy_all
        ;;
    *)
        usage
        ;;
esac
