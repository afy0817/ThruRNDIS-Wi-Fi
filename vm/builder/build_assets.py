#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 GodSeon
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build the ThruRNDIS-Wi-Fi guest kernel + initramfs inside an Alpine aarch64 container.

The layout follows ThruRNDIS_VM_Assets (BusyBox init, RAM-only root, same
guest scripts and console markers) and adds the USB Wi-Fi stack: cfg80211,
mac80211, rtw89 USB drivers with their firmware, wireless-regdb,
wpa_supplicant and a busybox httpd control API.

Run through vm/build.sh; it expects linux-stable, linux-firmware-rtw89,
wireless-regdb and kmod to be installed in the container already.
"""

import argparse
import dataclasses
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zlib

ROOT_PACKAGES = [
    "busybox", "busybox-extras", "iproute2", "nftables", "tcpdump",
    "wpa_supplicant", "iw",
]

# Upstream ThruRNDIS seeds first, then the Wi-Fi stack; the USB Wi-Fi
# drivers come from vm/drivers.conf. modprobe resolves the dependency
# closure; crypto modules are requested at runtime by mac80211 and
# wpa_supplicant (CCMP/GCMP/BIP/SAE), so they are seeded explicitly.
BASE_MODULE_SEEDS = [
    "virtio_pci", "virtio_mmio", "virtio_console", "virtio_net", "af_packet",
    "xhci_hcd", "xhci_pci", "usbnet", "cdc_ether", "cdc_subset", "rndis_host",
    "nf_tables", "nf_conntrack", "nf_nat", "nft_chain_nat",
    "nft_ct", "nft_nat", "nft_masq",
    "cfg80211", "mac80211",
    "ccm", "gcm", "cmac", "ctr", "ghash_ce",
    "ecdh_generic", "aes_ce_ccm",
]

BASE_FIRMWARE_GLOBS = [
    "regulatory.db",
    "regulatory.db.p7s",
]


@dataclasses.dataclass
class Driver:
    module: str
    packages: list[str]
    files: list[str]
    # (vendor, product, reference vendor, reference product)
    new_ids: list[tuple[str, str, str, str]]


USB_ID = r"([0-9a-f]{4}):([0-9a-f]{4})"


def read_drivers(path: pathlib.Path) -> list[Driver]:
    """Parses vm/drivers.conf (format described in that file)."""
    drivers: list[Driver] = []
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        module, *fields = line.split()
        if not re.fullmatch(r"[a-z0-9_]+", module):
            fail(f"{path.name}:{number}: bad module name {module!r}")
        driver = Driver(module, [], [], [])
        for field in fields:
            key, _, value = field.partition("=")
            items = [item for item in value.split(",") if item]
            if key == "pkg" and all(re.fullmatch(r"[a-z0-9_.-]+", item) for item in items):
                driver.packages += items
            elif key == "files" and all(re.fullmatch(r"[A-Za-z0-9_./*?-]+", item) for item in items):
                driver.files += items
            elif key == "newid":
                for item in items:
                    match = re.fullmatch(f"{USB_ID}/{USB_ID}", item.lower())
                    if not match:
                        fail(f"{path.name}:{number}: newid must look like 0bda:b831/0bda:b851, got {item!r}")
                    driver.new_ids.append(match.groups())
            else:
                fail(f"{path.name}:{number}: cannot read {field!r}")
        drivers.append(driver)
    if not drivers:
        fail(f"{path.name} lists no drivers")
    return drivers

UPSTREAM_SCRIPTS = [
    "init-rndis", "init-network", "init-console", "eth0-usb0-gateway",
]
THRURNDIS_WIFI_SCRIPTS = [
    "uplink-watcher", "init-wifi", "thrurndis-wifi-config", "wlan-supervisor",
    "wpa-action", "wlan0-dhcp", "thrurndis-wifi-httpd", "usb-tx-watcher", "usb-recover",
]

INITTAB = """::sysinit:/etc/init.d/rcS
::wait:/usr/local/sbin/init-rndis
::wait:/usr/local/sbin/init-wifi
::wait:/usr/local/sbin/init-network
::respawn:/sbin/syslogd -n -O /run/thrurndis-wifi/messages -s 256 -b 1
::respawn:/usr/local/sbin/uplink-watcher
::respawn:/usr/local/sbin/wlan-supervisor
::respawn:/usr/local/sbin/usb-tx-watcher
::respawn:/usr/local/sbin/thrurndis-wifi-httpd
hvc0::respawn:/usr/local/sbin/init-console
::restart:/sbin/init
::ctrlaltdel:/bin/umount -a -r
"""


def fail(message: str) -> "NoReturn":
    print(f"build_assets: {message}", file=sys.stderr)
    sys.exit(1)


def run(command: list[str], **kwargs) -> subprocess.CompletedProcess:
    print("+", " ".join(command), flush=True)
    return subprocess.run(command, check=True, **kwargs)


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def install_root_packages(root: pathlib.Path) -> list[str]:
    run([
        "apk", "--root", str(root), "--initdb", "--arch", "aarch64",
        "--keys-dir", "/etc/apk/keys",
        "--repositories-file", "/etc/apk/repositories",
        "--no-scripts", "--no-cache", "--quiet", "add", *ROOT_PACKAGES,
    ])
    listing = run(["apk", "--root", str(root), "info", "-v"], capture_output=True, text=True)
    packages = sorted(line.strip() for line in listing.stdout.splitlines() if line.strip())
    for relative in ("lib/apk", "etc/apk", "var/cache", "usr/share/apk",
                     "usr/share/man", "usr/share/doc", "usr/include"):
        shutil.rmtree(root / relative, ignore_errors=True)
    return packages


def symlink(root: pathlib.Path, relative: str, target: str) -> None:
    path = root / relative
    if path.exists() or path.is_symlink():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(target)


def install_busybox_applets(root: pathlib.Path) -> None:
    for name, binary in (("busybox", "/bin/busybox"), ("busybox-extras", "/bin/busybox-extras")):
        manifest = root / "etc/busybox-paths.d" / name
        if not manifest.is_file() or not (root / binary.lstrip("/")).is_file():
            fail(f"{name} applet manifest or binary missing")
        for line in manifest.read_text().splitlines():
            relative = line.strip().lstrip("/")
            if relative and relative != binary.lstrip("/"):
                symlink(root, relative, binary)
    symlink(root, "usr/bin/busybox", "/bin/busybox")
    symlink(root, "usr/bin/sh", "/bin/busybox")


def add_file(root: pathlib.Path, relative: str, data: bytes, mode: int) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() or path.exists():
        path.unlink()
    path.write_bytes(data)
    path.chmod(mode)


def install_project_files(root: pathlib.Path, src: pathlib.Path, release: dict,
                          drivers: list[Driver]) -> None:
    for directory, mode in (
        ("bin", 0o755), ("sbin", 0o755), ("dev", 0o755),
        ("etc/init.d", 0o755), ("root", 0o700), ("run", 0o755),
        ("tmp", 0o1777), ("usr/local/libexec/thrurndis", 0o755),
        ("usr/local/sbin", 0o755), ("usr/local/share/thrurndis-wifi/www/cgi-bin", 0o755),
        ("var/log", 0o755),
    ):
        path = root / directory
        path.mkdir(parents=True, exist_ok=True)
        path.chmod(mode)

    scripts = src / "initramfs"
    symlink(root, "init", "/sbin/init")
    add_file(root, "etc/inittab", INITTAB.encode(), 0o644)
    add_file(root, "etc/init.d/rcS", (scripts / "rcS").read_bytes(), 0o755)
    for name in UPSTREAM_SCRIPTS + THRURNDIS_WIFI_SCRIPTS:
        add_file(root, f"usr/local/sbin/{name}", (scripts / name).read_bytes(), 0o755)
    add_file(root, "usr/local/libexec/thrurndis/port-forwarding",
             (scripts / "port-forwarding").read_bytes(), 0o644)
    add_file(root, "usr/local/share/thrurndis-wifi/www/cgi-bin/api", (scripts / "api.cgi").read_bytes(), 0o755)
    add_file(root, "etc/resolv.conf", b"", 0o644)
    # init-wifi loads these and registers the extra USB IDs.
    lines = [f"load {driver.module}" for driver in drivers]
    lines += [f"newid {driver.module} {' '.join(new_id)}" for driver in drivers for new_id in driver.new_ids]
    add_file(root, "etc/thrurndis-wifi/drivers", ("\n".join(lines) + "\n").encode(), 0o644)
    # rtw88 switches RTL8822BU/8822CU dongles to USB 3 at probe. Passed through
    # ThruRNDIS that re-enumerates the dongle on the Mac, and at SuperSpeed its
    # transfers stall (-EPIPE), so the VM keeps restarting.
    add_file(root, "etc/modprobe.d/thrurndis-wifi.conf", b"options rtw88_usb switch_usb_mode=N\n", 0o644)
    add_file(root, "etc/thrurndis-wifi-release", (json.dumps(release, indent=2) + "\n").encode(), 0o644)


def extract_linux_image(vmlinuz: pathlib.Path, destination: pathlib.Path) -> None:
    data = vmlinuz.read_bytes()
    offset = data.find(b"\x1f\x8b\x08")
    if offset < 0:
        fail(f"gzip Linux Image payload not found in {vmlinuz}")
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    image = decompressor.decompress(data[offset:]) + decompressor.flush()
    if len(image) < 1024 * 1024 or image[56:60] != b"ARM\x64":
        fail(f"extracted payload from {vmlinuz} is not an arm64 Linux Image")
    destination.write_bytes(image)
    destination.chmod(0o644)


def copy_module_closure(release: str, root: pathlib.Path, seeds: list[str]) -> list[str]:
    source_dir = pathlib.Path("/lib/modules") / release
    selected: dict[str, pathlib.Path] = {}
    for seed in seeds:
        result = subprocess.run(
            ["modprobe", "-S", release, "--show-depends", seed],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            fail(f"kernel module {seed} not found: {result.stderr.strip()}")
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "insmod":
                path = pathlib.Path(parts[1])
                selected[path.relative_to(source_dir).as_posix()] = path

    target_dir = root / "lib/modules" / release
    for relative, path in sorted(selected.items()):
        destination = target_dir / relative.removesuffix(".gz").removesuffix(".zst")
        destination.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix == ".gz":
            with gzip.open(path, "rb") as compressed, destination.open("wb") as output:
                shutil.copyfileobj(compressed, output)
        else:
            shutil.copyfile(path, destination)
        destination.chmod(0o644)
    for name in ("modules.builtin", "modules.builtin.modinfo", "modules.order"):
        if (source_dir / name).is_file():
            shutil.copyfile(source_dir / name, target_dir / name)
    run(["depmod", "-b", str(root), release])
    return sorted(path.removesuffix(".gz") for path in selected)


def copy_firmware(root: pathlib.Path, modules_root: pathlib.Path, patterns: list[str]) -> list[str]:
    """Copies the listed patterns plus every firmware file a packaged module
    declares. Files may be plain, .zst or .xz (the kernel's FW_LOADER
    decompresses them); a declared file no package provides is reported but
    does not fail the build, as drivers declare files for every chip variant."""
    source = pathlib.Path("/lib/firmware")
    copied: list[str] = []

    def copy(path: pathlib.Path) -> None:
        relative = path.relative_to(source).as_posix()
        if relative in copied:
            return
        destination = root / "lib/firmware" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        destination.chmod(0o644)
        copied.append(relative)

    for pattern in patterns:
        matches = sorted(source.glob(pattern))
        if not matches:
            fail(f"firmware pattern {pattern} matched nothing (is its pkg= in drivers.conf?)")
        for path in matches:
            copy(path)

    missing: list[str] = []
    for module in sorted(modules_root.rglob("*.ko")):
        result = run(["modinfo", "-F", "firmware", str(module)], capture_output=True, text=True)
        for name in (line.strip() for line in result.stdout.splitlines()):
            if not name:
                continue
            candidates = [source / name, source / f"{name}.zst", source / f"{name}.xz"]
            found = next((path for path in candidates if path.is_file()), None)
            if found:
                copy(found)
            else:
                missing.append(f"{module.stem}: {name}")
    for line in missing:
        print(f"build_assets: note: declared firmware not packaged ({line})", flush=True)
    return sorted(copied)


def cpio_header(inode: int, name: bytes, mode: int, size: int, nlink: int = 1,
                rdevmajor: int = 0, rdevminor: int = 0) -> bytes:
    fields = (inode, mode, 0, 0, nlink, 0, size, 0, 0, rdevmajor, rdevminor, len(name) + 1, 0)
    return ("070701" + "".join(f"{field:08x}" for field in fields)).encode()


def write_padding(handle, size: int) -> None:
    padding = (-size) % 4
    if padding:
        handle.write(b"\0" * padding)


def write_initramfs(root: pathlib.Path, destination: pathlib.Path) -> None:
    """newc cpio owned by root:root with fixed mtimes, gzip -9."""
    with tempfile.NamedTemporaryFile(delete=False) as raw:
        raw_path = pathlib.Path(raw.name)
        inode = 1
        entries = [pathlib.Path(".")]
        entries.extend(sorted((p.relative_to(root) for p in root.rglob("*")), key=lambda p: p.as_posix()))
        for relative in entries:
            path = root if relative == pathlib.Path(".") else root / relative
            name = relative.as_posix().encode()
            info = path.lstat()
            if path.is_symlink():
                data = os.readlink(path).encode()
                mode, nlink = stat.S_IFLNK | 0o777, 1
            elif path.is_dir():
                data = b""
                mode, nlink = stat.S_IFDIR | stat.S_IMODE(info.st_mode), 2
            elif path.is_file():
                data = path.read_bytes()
                mode, nlink = stat.S_IFREG | stat.S_IMODE(info.st_mode), 1
            else:
                fail(f"unsupported file in initramfs root: {relative}")
            header = cpio_header(inode, name, mode, len(data), nlink)
            inode += 1
            raw.write(header + name + b"\0")
            write_padding(raw, len(header) + len(name) + 1)
            raw.write(data)
            write_padding(raw, len(data))
        for name, major, minor, mode in (
            (b"dev/console", 5, 1, 0o600),
            (b"dev/null", 1, 3, 0o666),
            (b"dev/kmsg", 1, 11, 0o600),
        ):
            header = cpio_header(inode, name, stat.S_IFCHR | mode, 0, 1, major, minor)
            inode += 1
            raw.write(header + name + b"\0")
            write_padding(raw, len(header) + len(name) + 1)
        trailer = b"TRAILER!!!"
        header = cpio_header(inode, trailer, 0, 0)
        raw.write(header + trailer + b"\0")
        write_padding(raw, len(header) + len(trailer) + 1)
    with raw_path.open("rb") as source, destination.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, compresslevel=9, mtime=0) as compressed:
            shutil.copyfileobj(source, compressed)
    raw_path.unlink()
    destination.chmod(0o644)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--src", type=pathlib.Path, required=True)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--version", default="dev")
    args = parser.parse_args()

    releases = sorted(p.name for p in pathlib.Path("/lib/modules").iterdir())
    if len(releases) != 1:
        fail(f"expected one installed kernel, found {releases}")
    kernel_release = releases[0]

    work = pathlib.Path(tempfile.mkdtemp(prefix="thrurndis-wifi-"))
    root = work / "root"
    root.mkdir()

    drivers = read_drivers(args.src / "drivers.conf")
    release_info = {
        "name": "ThruRNDIS-Wi-Fi",
        "version": args.version,
        "kernel": kernel_release,
        "upstream": (args.src / "initramfs/UPSTREAM_COMMIT").read_text().strip(),
    }
    packages = install_root_packages(root)
    install_busybox_applets(root)
    install_project_files(root, args.src, release_info, drivers)
    modules = copy_module_closure(kernel_release, root, BASE_MODULE_SEEDS + [d.module for d in drivers])
    firmware = copy_firmware(root, root / "lib/modules" / kernel_release,
                             BASE_FIRMWARE_GLOBS + [pattern for d in drivers for pattern in d.files])

    args.out.mkdir(parents=True, exist_ok=True)
    for stale in args.out.iterdir():
        if stale.is_file():
            stale.unlink()
    # The name predates linux-stable; installed apps point ThruRNDIS at it.
    image = args.out / "Image-lts"
    # ThruRNDIS only accepts a manual asset folder whose ramdisk matches
    # initramfs-thrurndis-* and whose manifest.json has assetVersion 1.
    initramfs = args.out / "initramfs-thrurndis-wifi"
    extract_linux_image(pathlib.Path("/boot/vmlinuz-stable"), image)
    write_initramfs(root, initramfs)

    manifest = dict(assetVersion=1, schemaVersion=1, **release_info,
                    drivers=[d.module for d in drivers],
                    packages=packages, modules=modules, firmware=firmware)
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    sums = "".join(f"{sha256(p)}  {p.name}\n" for p in (image, initramfs, args.out / "manifest.json"))
    (args.out / "SHA256SUMS").write_text(sums)
    shutil.rmtree(work)

    print(f"built {image.name} ({image.stat().st_size} bytes) and "
          f"{initramfs.name} ({initramfs.stat().st_size} bytes) for {kernel_release}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
