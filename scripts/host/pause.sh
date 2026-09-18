#!/bin/bash
# Pause the demo between parts so the operator can narrate.
#
# Host-only, deliberately. The Mac's terminal is the one place a TTY reliably
# exists: `multipass exec` has no pty flag and gets stdin only when its caller
# had one, and the Part 8 scripts capture 50_login.sh's output with $( ... ),
# so a prompt printed inside the VM could be swallowed rather than shown.
# Called from the Taskfile's internal _pause task, between demo steps.
#
# Usage: pause.sh <next-label> [resume-task]
set -euo pipefail

next="${1:-the next step}"
resume="${2:-}"

# Anything but PAUSE=1 runs straight through — CI, scripted runs, and
# `PAUSE=0 task demo` for the old uninterrupted behaviour.
[[ "${PAUSE:-1}" == "1" ]] || exit 0

# No controlling terminal (a pipe, a CI runner): never block. The brace group
# is what keeps bash's own "no such device" complaint off the transcript —
# `exec 3</dev/tty 2>/dev/null` opens fd 3 before stderr is redirected.
if ! { exec 3</dev/tty; } 2>/dev/null; then exit 0; fi

if [[ -t 1 ]]; then
  bold=$'\033[1m'; dim=$'\033[2m'; reset=$'\033[0m'
else
  bold=''; dim=''; reset=''
fi

printf '\n%s%s%s\n' "${dim}" "────────────────────────────────────────────────────────────" "${reset}"
printf '%snext:%s %s\n' "${bold}" "${reset}" "${next}"
printf '%s  ⏎ continue · q quit%s ' "${dim}" "${reset}"

reply=''
# EOF or a read error continues rather than aborting: stopping is an explicit
# choice, never an accident of how the terminal was wired up.
read -r reply <&3 || true
exec 3<&-
printf '\n'

case "${reply}" in
  q|Q|quit)
    if [[ -n "${resume}" ]]; then
      printf 'Stopped. Resume with: task %s\n' "${resume}" >&2
    else
      printf 'Stopped.\n' >&2
    fi
    exit 1
    ;;
esac
