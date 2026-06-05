set -e
cd "$HOME/rofihosted-src"
git fetch --quiet origin main
git reset --hard origin/main >/dev/null
echo "SRC_HEAD=$(git log -1 --oneline)"
rsync -a --delete --exclude='.zig-cache/' --exclude='zig-out/' "$HOME/rofihosted-src/zig/hp-server/" "$HOME/zig/hp-server/" >/dev/null
echo "SYNCED"
echo "fonts=$(ls -1 "$HOME/zig/hp-server/src/templates/fonts/"*.woff2 2>/dev/null | wc -l) woff2"
grep -q "handleStatus" "$HOME/zig/hp-server/src/main.zig" && echo "main=UPDATED" || echo "main=OLD"
grep -q "SF Pro Display" "$HOME/zig/hp-server/src/templates/theme.css" && echo "theme=UPDATED" || echo "theme=OLD"
