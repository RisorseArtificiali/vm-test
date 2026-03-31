# vm-test

Disposable GUI virtual machines for testing software on a vanilla OS. Spin up a fresh Fedora or Ubuntu desktop in seconds, test whatever you need, destroy it, repeat.

## How it works

Three layers of disk images, each building on the previous:

```
Fedora43-base           ← clean OS install (one-time, ~15 min)
  └─ Fedora43-devtools  ← your custom setup (optional, reusable)
       └─ test VM       ← disposable COW overlay (instant, few KB)
```

1. **Base** — install the OS from an ISO. Kept forever as a clean starting point.
2. **Prepared** — boot a base, install your packages/tools, shut down. Saved as a named image you can reuse.
3. **Test VM** — instant copy-on-write overlay of any base or prepared image. Destroy it when done, back to the snapshot.

## Prerequisites

```bash
sudo dnf install qemu-kvm libvirt virt-install virt-viewer genisoimage
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt $USER   # then re-login
```

## Usage

```bash
./scripts/test-vm.sh              # Interactive TUI
./scripts/test-vm.sh list         # Show VMs and images
./scripts/test-vm.sh destroy <vm> # Destroy a specific VM
./scripts/test-vm.sh destroy-all  # Destroy all test VMs
```

The TUI menu:

```
═══════════════════════════════════════════════════
           LINCE Test VM Manager
═══════════════════════════════════════════════════

  Images:
    Fedora43-base              base  8.2G
    Fedora43-devtools          prep  1.3G
    Ubuntu2404-base            base  9.1G

  s)  Start test VM
  n)  New OS install from ISO
  p)  Prepare image (customize a base)
  d)  Delete an image

  l)  List running VMs (0 active)
  x)  Destroy all test VMs

  q)  Quit
```

## Multiple versions

Default ISOs are provided for Fedora 43 and Ubuntu 24.04, but you can install any version from any ISO URL. Each gets its own label:

- `Fedora43-base`, `Fedora42-base`, `UbuntuNoble-base`, ...
- Prepared images are named `<base>-<name>`: `Fedora43-devtools`, `Fedora43-minimal`, ...

## Example: testing LINCE

Once the GNOME desktop is up, open a terminal and run:

```bash
curl -sSL https://lince.sh/install | bash
```

Any install script, provisioning tool, or dotfiles repo works the same way -- boot a disposable VM, run your stuff, destroy it.

Default login: **tester** / **tester**

## Storage

Everything lives in `~/.local/share/lince-test-vms/`:

| File | Size | Purpose |
|------|------|---------|
| `*.iso` | 2–6 GB each | Downloaded installer ISOs |
| `*-base.qcow2` | 8–12 GB each | Clean OS installs |
| `*-<name>.qcow2` | 1–5 GB each | Prepared images (delta from base) |
| `lince-test-*.qcow2` | Few KB–MB | Disposable test overlays |

## VM specs

4 CPUs, 16 GB RAM, 40 GB disk (configurable at the top of `scripts/test-vm.sh`).

## License

[MIT](LICENSE)
