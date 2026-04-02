# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**vm-test** is a Bash utility for creating disposable graphical VMs to test software on a vanilla OS. It uses libvirt/QEMU with a layered copy-on-write disk image system for Linux VMs, and quickemu for macOS VMs. VMs can be spun up instantly and destroyed without side effects.

## Running

```bash
./scripts/test-vm.sh              # Interactive TUI
./scripts/test-vm.sh list         # Show VMs and images
./scripts/test-vm.sh destroy <n>  # Destroy a specific VM
./scripts/test-vm.sh destroy-all  # Destroy all test VMs
```

## Prerequisites

Requires `qemu-kvm`, `libvirt`, `virt-install`, `virt-viewer`, `genisoimage` and an active `libvirtd` service. The current user must be in the `libvirt` group. Bash 4+ required for associative arrays. Optional: `quickemu` and `quickget` for macOS VM support.

## Architecture

Single script: `scripts/test-vm.sh`. Two backends:

### Linux VMs (libvirt) — Three-layer image system:

1. **Base images** (`*-base.qcow2`) — Clean OS from ISO install. Multiple versions supported (e.g., `Fedora43-base`, `Ubuntu2404-base`). Default ISOs provided; custom URLs accepted.
2. **Prepared images** (`*-<name>.qcow2`) — COW on top of a base with user customizations (e.g., `Fedora43-devtools`). Optional layer for pre-installing packages before testing.
3. **Test overlays** (`lince-test-*.qcow2`) — Disposable COW of any base or prepared image. Destroyed after use.

### macOS VMs (quickemu):

Downloaded and managed via `quickget`/`quickemu`. Supports Sonoma, Sequoia, Ventura, Monterey. Stored in `~/.local/share/vm-test-macos/`.

Key functions:
- `install_base()` — Downloads ISO, runs interactive OS install via `virt-install`, saves as base qcow2
- `prepare_image()` — Boots COW of a base, user customizes, saves as named prepared image
- `launch_vm()` — Creates COW overlay of any image, launches VM with `virt-install --import`, opens `virt-viewer --attach`
- `show_menu()` — TUI loop: discovers images by scanning `IMAGE_DIR` for qcow2 files, dispatches to action functions. Keys: `s`=start VM, `n`=new install, `p`=prepare, `d`=delete, `l`=list VMs, `x`=destroy all
- Image discovery: `get_base_labels()` scans for `*-base.qcow2`, `get_prepared_names()` excludes bases and test overlays

## Conventions

- All images stored in `~/.local/share/lince-test-vms/`
- Naming: `<Label>-base.qcow2` for bases, `<Label>-<name>.qcow2` for prepared, `lince-test-*` for disposable overlays
- VM names: `lince-base-*` (install), `lince-prepare-*` (prepare), `lince-test-*` (test)
- Default credentials: `tester` / `tester`
- SPICE + QXL for graphical display, `virt-viewer --attach` to connect
- `set -e` for fail-fast; stale VM cleanup before operations that create disk images
- Default ISO URLs stored in `DEFAULT_ISOS` associative array at top of script
