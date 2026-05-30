#!/data/data/com.termux/files/usr/bin/sh
# Recovery job: re-runs ~/.termux/boot/01-server.sh if the recovery chain is
# missing. Idempotent (boot script itself checks pgrep before respawning).
# Triggered every 15 min by termux-job-scheduler. Acts as fallback when
# Termux:Boot fails to fire automatically (Sharp Aquos OEM kill behavior,
# or any other reason the standard boot chain doesn't kick in).
#
# Register via:
#   termux-job-scheduler --script ~/recovery-job.sh \
#     --period-ms 900000 --persisted true
#
# Verify:
#   termux-job-scheduler --pending
#
# Cancel all jobs:
#   termux-job-scheduler --cancel-all

LOG=~/logs/recovery-job.log
mkdir -p ~/logs
echo "[recovery-job $(date)] tick" >> "$LOG"

# If hp-server is dead OR cloudflared is dead, run the boot script.
# The boot script itself is idempotent (checks pgrep before each spawn) so
# running it when partially up is safe.
if ! pgrep -f 'hp-server$' >/dev/null 2>&1 || ! pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1; then
  echo "[recovery-job $(date)] services missing, re-running boot script" >> "$LOG"
  bash ~/.termux/boot/01-server.sh
else
  echo "[recovery-job $(date)] services healthy" >> "$LOG"
fi
