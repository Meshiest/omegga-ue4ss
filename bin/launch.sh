#!/usr/bin/env bash
# omegga runs this as `launch.sh <game command...>` (the doc.json launch wrapper).
#
# Starts the game under UE4SS when the plugin prepared data/UE4SS for exactly
# this binary (path, size, mtime in the ready marker), and without it otherwise:
# a Steam update between preparing and launching, a missing runtime or an
# unresolved signature must never stop the server from starting.
#
# Either way it adds Brickadia's crash reporter switch, so crashes of a modded
# server don't reach Brickadia's crash collector.
set -euo pipefail

dir=${OMEGGA_UE4SS_DIR:?set by the omegga-ue4ss launch env}
game=${1:?usage: launch.sh <game command...>}

is_elf=false
identity=
if [[ "$(head -c 4 "$game" | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]]; then
  is_elf=true
  real=$(readlink -f "$game")
  identity="$real $(stat -Lc '%s %Y' "$real")"
fi

# build-cl is "<identity>\n<changelist>", written by the plugin for one binary;
# the switch only works with that binary's changelist
crash_args=()
if [[ -n $identity && -f $dir/build-cl && "$(head -n 1 "$dir/build-cl")" == "$identity" ]]; then
  crash_args=("-AllowCustomArchivesAndDisableCrashReporterForVersion=CL$(sed -n 2p "$dir/build-cl")")
else
  echo "omegga-ue4ss: changelist of $game unknown; crash reports may be uploaded" >&2
fi

# skip <reason> <game command...>
skip() {
  echo "omegga-ue4ss: $1; starting without UE4SS" >&2
  shift
  exec "$@" "${crash_args[@]}"
}

if [[ ! -f $dir/ready || ! -x $dir/run_ue4ss.sh || ! -f $dir/libUE4SS.so ]]; then
  skip "data/UE4SS is not prepared" "$@"
fi

# a launcher script (non-Steam installs) isn't the game ELF run_ue4ss.sh needs
if ! $is_elf; then
  skip "$game is not the game binary" "$@"
fi

if [[ "$(cat "$dir/ready")" != "$identity" ]]; then
  skip "the game binary changed since data/UE4SS was prepared" "$@"
fi

export UE4SS_CRASH_LOG_DIR=${UE4SS_CRASH_LOG_DIR:-$dir/crashes}
mkdir -p "$UE4SS_CRASH_LOG_DIR"
exec "$dir/run_ue4ss.sh" "$@" "${crash_args[@]}"
