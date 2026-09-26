#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

zig build -Doptimize=Debug
# zig build -Doptimize=ReleaseFast

rm -rf build/
mkdir -p build/iso_root/boot build/iso_root/system build/iso_root/EFI/BOOT

cp zig-out/bin/kernel.elf build/iso_root/boot/kernel.elf
cp limine.conf build/iso_root/boot/limine.conf

cp zig-out/bin/hello.elf build/iso_root/system/hello.elf

# Limine's pre-built boot stages, from the `limine` package installed
# in the container at /opt/limine (binary branch).
cp /opt/limine/limine-bios.sys build/iso_root/boot/
cp /opt/limine/limine-bios-cd.bin build/iso_root/boot/
cp /opt/limine/limine-uefi-cd.bin build/iso_root/boot/
cp /opt/limine/BOOTX64.EFI build/iso_root/EFI/BOOT/
cp /opt/limine/BOOTIA32.EFI build/iso_root/EFI/BOOT/

xorriso -as mkisofs -R -r -J -b boot/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot boot/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    build/iso_root -o build/marble.iso

# Installs the BIOS stage-1 loader into the ISO's boot sector so it
# also boots on legacy BIOS, not just UEFI.
limine bios-install build/marble.iso

echo "-> build/marble.iso"
