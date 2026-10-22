#!/bin/bash
# macos_guard.sh - root-side teardown for run_macos.sh, run under sudo.
# Usage: sudo macos_guard.sh <launcher-pid> <routes-state-file> <tap-dev> <tap-peer>
#
# run_macos.sh undoes its own changes on exit, but only while it can still use
# sudo: close the Terminal window and the EXIT trap runs with no tty and no
# usable sudo ticket, leaving the feth pair up and Wi-Fi's broadcast/multicast
# routes pointing at it. This guardian is started (as root) once at launch,
# waits for the launcher to go away however it goes, then stops the bridge,
# puts the routes back from the state file and destroys the feth pair. Every
# step is idempotent, so it is harmless after a clean exit.
#
# The state file belongs to the user, so each line is validated before root
# acts on it; anything that is not "<-host|-net> <IPv4[/len]> <iface|->" is
# ignored.
set -u

PARENT="${1:-}" STATE="${2:-}" TAP_DEV="${3:-}" TAP_PEER="${4:-}"
[[ "$PARENT" =~ ^[0-9]+$ ]] || exit 1
[[ "$TAP_DEV" =~ ^feth[0-9]+$ && "$TAP_PEER" =~ ^feth[0-9]+$ ]] || exit 1

while kill -0 "$PARENT" 2>/dev/null; do
    sleep 1
done

pkill -x tap_bridge 2>/dev/null

ip4='[0-9]{1,3}(\.[0-9]{1,3}){3}'
if [ -n "$STATE" ] && [ -f "$STATE" ] && [ ! -L "$STATE" ]; then
    while read -r kind dest iface; do
        [[ "$kind" == "-host" || "$kind" == "-net" ]] || continue
        [[ "$dest" =~ ^${ip4}(/[0-9]{1,2})?$ ]] || continue
        [[ "$iface" == "-" || "$iface" =~ ^[a-z]+[0-9]+$ ]] || continue
        route -n delete "$kind" "$dest" >/dev/null 2>&1
        [ "$iface" != "-" ] && route -n add "$kind" "$dest" -interface "$iface" >/dev/null 2>&1
    done < "$STATE"
    rm -f "$STATE"
fi

ifconfig "$TAP_DEV" destroy 2>/dev/null
ifconfig "$TAP_PEER" destroy 2>/dev/null
exit 0
