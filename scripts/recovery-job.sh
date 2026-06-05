#!/data/data/com.termux/files/usr/bin/sh
# Recovery job: re-runs ~/.termux/boot/01-server.sh if the recovery chain is
# missing. Idempotent (boot script itself checks pgrep before respawning).
#
# Self-rescheduling design: Android JobScheduler has a hard 15-min floor for
# periodic jobs. To get sub-15-min polling, we register a ONE-SHOT job that
# re-schedules itself after a controlled delay. Effective interval ~60s.
#
# IMPORTANT: One-shot rescheduled jobs have NO minimum interval enforced by
# Android. Without a sleep before the re-register, the job fires instantly
# (busy-loop ~1s per cycle, drains battery). We sleep 60s before re-register.
#
# Acts as fallback when Termux:Boot fails to fire automatically (Sharp Aquos
# OEM kill behavior, or any other reason the standard boot chain doesn't
# kick in).
#
# Initial registration:
#   bash ~/recovery-job.sh --register
#
# Verify:
#   termux-job-scheduler --pending
#
# Cancel all jobs:
#   termux-job-scheduler --cancel-all

LOG=~/logs/recovery-job.log
mkdir -p ~/logs
RESCHEDULE_AFTER_SEC=60

reschedule() {
  termux-job-scheduler --script "$HOME/recovery-job.sh" \
    --persisted true --charging true --network any 2>&1 | head -1 >> "$LOG"
}

# --register mode: just schedule the next one-shot tick and exit.
if [ "${1:-}" = "--register" ]; then
  reschedule
  echo "[recovery-job $(date)] initial registration" >> "$LOG"
  exit 0
fi

# Normal tick.
echo "[recovery-job $(date)] tick" >> "$LOG"

# If hp-server or cloudflared are dead, run the boot script.
# The boot script itself is idempotent (checks pgrep before each spawn) so
# running it when partially up is safe.
if ! pgrep -f 'zig-out/bin/hp-server' >/dev/null 2>&1 || ! pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1; then
  echo "[recovery-job $(date)] services missing, re-running boot script" >> "$LOG"
  bash ~/.termux/boot/01-server.sh
else
  echo "[recovery-job $(date)] services healthy" >> "$LOG"
fi

# Self-reschedule with throttle. Sleep first, then register the next job.
# Android fires it ~immediately once we register since constraints are
# satisfied (charging+network always true on phone-on-charger).
sleep "$RESCHEDULE_AFTER_SEC"
reschedule
