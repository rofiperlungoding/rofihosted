#!/data/data/com.termux/files/usr/bin/sh
set -e
cd ~/rofihosted-src
git fetch --quiet origin main
git reset --hard origin/main 2>&1 | tail -2
rsync -a --delete --exclude='.zig-cache/' --exclude='zig-out/' ~/rofihosted-src/zig/hp-server/ ~/zig/hp-server/
echo synced
pkill -9 -f 'zig build' 2>/dev/null || true
pkill -9 -f rebuild.sh 2>/dev/null || true
sleep 1
nohup ~/rebuild.sh > ~/build-tenancy.log 2>&1 &
echo "bg_pid=$!"
