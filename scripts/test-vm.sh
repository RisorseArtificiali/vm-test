#!/usr/bin/env bash
#
# test-vm.sh — Disposable GUI VM launcher for LINCE testing
#
# Manages layered VM images:
#   Base:     Clean OS install        (e.g., Fedora43-base)
#   Prepared: Custom setup on base    (e.g., Fedora43-devtools)
#   Test VM:  Disposable COW overlay  (destroyed after use)
#
# Prerequisites:
#   sudo dnf install qemu-kvm libvirt virt-install virt-viewer genisoimage
#   sudo systemctl enable --now libvirtd
#   sudo usermod -aG libvirt $USER  (then re-login)
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
    echo -e "${GREEN}║  Test LINCE:  curl -sSL https://lince.sh/install | bash ${NC}"
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
        echo -e "${BLUE}${BOLD}           LINCE Test VM Manager${NC}"
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════${NC}"
        echo ""

        if [ ${#all_images[@]} -gt 0 ]; then
            echo -e "  ${BOLD}Images:${NC}"
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
            echo -e "  ${DIM}No images yet. Start with a new install.${NC}"
        fi

        echo ""
        echo -e "  ${BOLD}s${NC})  Start test VM"
        echo -e "  ${BOLD}n${NC})  New OS install from ISO"
        echo -e "  ${BOLD}p${NC})  Prepare image ${DIM}(customize a base)${NC}"
        echo -e "  ${BOLD}d${NC})  Delete an image"
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
            l|L) list_vms ;;
            x|X) destroy_all ;;
            q|Q) return ;;
            *)   echo -e "${RED}  Invalid choice.${NC}" ;;
        esac
    done
}

# ── Usage ────────────────────────────────────────────────────────────

usage() {
    echo -e "${BOLD}test-vm.sh${NC} — Disposable GUI VMs for LINCE testing"
    echo ""
    echo "Usage:"
    echo "  $0                  Interactive TUI"
    echo "  $0 list             Show VMs and images"
    echo "  $0 destroy <name>   Destroy a specific VM"
    echo "  $0 destroy-all      Destroy all test VMs"
    echo ""
    echo "Image layers:"
    echo "  <Label>-base        Clean OS install (e.g., Fedora43-base)"
    echo "  <Label>-<name>      Prepared image   (e.g., Fedora43-devtools)"
    echo "  lince-test-*        Disposable test VM overlays"
    echo ""
    echo "Login: tester / tester"
    echo "Images: $IMAGE_DIR"
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
            echo -e "${BOLD}── Images ──${NC}"
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
        ;;
    destroy)
        destroy_vm "$2"
        ;;
    destroy-all)
        destroy_all
        ;;
    *)
        usage
        ;;
esac
