#!/data/data/com.termux/files/usr/bin/sh
set -e

ZIG_VER="0.14.0"
ZIG_URL="https://ziglang.org/download/${ZIG_VER}/zig-linux-aarch64-${ZIG_VER}.tar.xz"

echo "[zig] downloading ${ZIG_VER} aarch64..."
cd ~
rm -rf ~/.local/zig zig.tar.xz
mkdir -p ~/.local
curl -L --fail --progress-bar -o zig.tar.xz "$ZIG_URL"

echo "[zig] extracting..."
tar -xf zig.tar.xz
mv "zig-linux-aarch64-${ZIG_VER}" ~/.local/zig
rm zig.tar.xz

# Symlink
ln -sf ~/.local/zig/zig $PREFIX/bin/zig

echo "[zig] verify:"
zig version
echo "[zig] installed at ~/.local/zig"
