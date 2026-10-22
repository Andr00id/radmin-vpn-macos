#!/bin/bash
# run_macos.sh - Radmin VPN on macOS (Wine + feth pair instead of a Linux TAP)
# Usage: ./run_macos.sh [--installer /path/to/Radmin_VPN_*.exe] [--no-ui] [--update]
#                       [--no-broadcast-routes]
#
# Same pipeline as run.sh; only the host side differs:
#
#   macOS stack ← feth26 ⇄ feth5026 ← tap_bridge (BPF/NDRV) ← FIFO ← rvpnnetmp.sys ← RvControlSvc.exe
#
# macOS has no TAP device. Two fake-ethernet interfaces peered back to back act
# as one: the host gets the 26.x address on feth26, and every frame it sends
# there comes out of feth5026, where tap_bridge picks it up.
#
# Wine: any Wine >= 11 for macOS. Looked up in this order: $WINE_BIN_DIR,
# CrossOver (bottle "RadminVPN"), `wine` on PATH, Gcenx's "Wine
# Devel/Staging/Stable.app" in /Applications. All of them run x86_64 code, so
# Apple Silicon needs Rosetta 2.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# For the watchdog's self-restart. Absolute: we cd into the Radmin folder later.
SELF="$DIR/$(basename "$0")"
ORIG_ARGS=("$@")

source "$DIR/lib.sh"

# ── Wine discovery ────────────────────────────────────────────────────────────
CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
CX_BOTTLE_NAME="${CX_BOTTLE_NAME:-RadminVPN}"
USE_CROSSOVER=0

# CrossOver comes first when installed: Gcenx's Wine Devel 11.18 crashes inside
# Radmin's Inno Setup installer (32-bit SEH under wow64 + Rosetta: "Exception
# frame is not in stack limits"), CrossOver 26.1 installs it cleanly. Set
# RVPN_WINE=system to skip CrossOver anyway.
_find_wine() {
    local d app
    if [ -n "${WINE_BIN_DIR:-}" ]; then
        export PATH="$WINE_BIN_DIR:$PATH"
        return 0
    fi
    if [ "${RVPN_WINE:-}" != "system" ] && [ -x "$CX_ROOT/bin/wine" ]; then
        USE_CROSSOVER=1
        return 0
    fi
    command -v wine >/dev/null 2>&1 && return 0
    for app in "Wine Devel" "Wine Staging" "Wine Stable"; do
        for d in "/Applications/$app.app" "$HOME/Applications/$app.app"; do
            if [ -x "$d/Contents/Resources/wine/bin/wine" ]; then
                export PATH="$d/Contents/Resources/wine/bin:$PATH"
                return 0
            fi
        done
    done
    if [ -x "$CX_ROOT/bin/wine" ]; then
        USE_CROSSOVER=1
        return 0
    fi
    return 1
}

_find_wine || die "Wine not found. Install a Wine >= 11 build for macOS, e.g. from
    https://github.com/Gcenx/macOS_Wine_builds/releases (Wine Devel.app → /Applications)
  or point WINE_BIN_DIR at a directory containing wine and wineserver."

if [ "$USE_CROSSOVER" -eq 1 ]; then
    # CrossOver's `wine` is a wrapper that picks the prefix from CX_BOTTLE;
    # its wineserver is the real binary and wants WINEPREFIX instead.
    export CX_BOTTLE="$CX_BOTTLE_NAME"
    export WINEPREFIX="$HOME/Library/Application Support/CrossOver/Bottles/$CX_BOTTLE_NAME"
    wine()       { "$CX_ROOT/bin/wine" "$@"; }
    wineserver() { "$CX_ROOT/bin/wineserver" "$@"; }
    # The wrapper's --version prints CrossOver's own version; the loader has Wine's.
    wine_version_str() { "$CX_ROOT/bin/wineloader" --version 2>/dev/null | head -n1; }
else
    export WINEPREFIX="${WINEPREFIX:-$DIR/wineprefix}"
fi
wineboot() { wine wineboot "$@"; }

# lib.sh's version parsing uses GNU sed's \+, which BSD sed does not have.
wine_major() { wine_version_str | sed -nE 's/^wine-([0-9]+).*/\1/p'; }

# The SO_REUSEPORT shim lib.sh preloads on Linux is not needed here: wineserver
# sets SO_REUSEPORT itself under __APPLE__ (see src/rvpn_reuseport.c).
boot_wineserver() { wineserver -p; }

# `timeout` is GNU coreutils and perl's `exec` would bypass the wine() shell
# function CrossOver needs, so run the command in the background and kill it
# when the time is up — the whole tree, since a function runs in a subshell
# whose children (CrossOver's wrapper, wineloader) would otherwise keep a
# $(...) around us waiting on its pipe. The killer's output goes to /dev/null
# for the same reason.
_kill_tree() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do _kill_tree "$c"; done
    kill "$1" 2>/dev/null || true
}
_timeout() {
    local s="$1" p k rc=0; shift
    "$@" & p=$!
    ( sleep "$s"; _kill_tree "$p" ) >/dev/null 2>&1 & k=$!
    wait "$p" || rc=$?
    kill "$k" 2>/dev/null || true
    return "$rc"
}

export WINEDEBUG=-all
RADMIN="$WINEPREFIX/drive_c/Program Files (x86)/Radmin VPN"
BUILD_DIR="${BUILD_DIR:-$DIR/build}"
TAP_DEV="feth26"
TAP_PEER="feth5026"
CMD_FILE="/tmp/radmin_netsh_cmd"
LOG="$WINEPREFIX/drive_c/ProgramData/Famatech/Radmin VPN/service.log"
MAC_FILE="$WINEPREFIX/radmin_mac"
RELAY_PID=""
BRIDGE_PID=""
SUDO_KEEPALIVE_PID=""
WATCHDOG_PID=""
RESTART_REQUESTED=0
RVPN_RESTARTS="${RVPN_RESTARTS:-0}"
MAX_RESTARTS=3
# User-owned (not /tmp): macos_guard.sh reads it as root after we exit.
STATE_DIR="$HOME/Library/Caches/radmin-vpn-macos"
ROUTES_STATE="$STATE_DIR/routes.state"
NO_UI=0
RETINA=1          # render the GUI at native Retina resolution (--no-retina: Wine's 1x, upscaled)
SAVED_ROUTES=""   # "dest iface" lines to put back on exit

# adapter_hook.dll matches the host interface by this name (Wine passes the
# Unix environment through to the service).
export RVPN_TAP_NAME="$TAP_DEV"

INSTALLER=""
INSTALLER_EXPLICIT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --installer)
            [ $# -ge 2 ] || die "--installer needs a path to Radmin_VPN_*.exe"
            INSTALLER="$2"; INSTALLER_EXPLICIT=1; shift ;;
        --installer=*) INSTALLER="${1#*=}"; INSTALLER_EXPLICIT=1 ;;
        --no-ui) NO_UI=1 ;;
        --no-retina) RETINA=0 ;;
        --no-broadcast-routes) NO_BCAST_ROUTES=1 ;;
        --update) DO_UPDATE=1 ;;
        *) warn "ignoring unknown option $1" ;;
    esac
    shift
done
DO_UPDATE="${DO_UPDATE:-0}"
NO_BCAST_ROUTES="${NO_BCAST_ROUTES:-0}"

INSTALLER_URL="${RADMIN_INSTALLER_URL:-$(radmin_installer_url)}"
DOWNLOAD_DIR="${RADMIN_DATA_DIR:-$HOME/Library/Application Support/radmin-vpn-macos}"

ensure_installer() {
    [ -n "$INSTALLER" ] && [ -f "$INSTALLER" ] && return 0
    local name d
    name="$(radmin_installer_name)"
    for d in "$DIR" "$BUILD_DIR" "$DOWNLOAD_DIR"; do
        [ -f "$d/$name" ] && { INSTALLER="$d/$name"; return 0; }
    done
    if [ "$DO_UPDATE" -eq 0 ]; then
        for d in "$DIR" "$BUILD_DIR"; do
            INSTALLER=$(find "$d" -maxdepth 1 -name 'Radmin_VPN_*.exe' -print -quit 2>/dev/null || true)
            [ -n "$INSTALLER" ] && return 0
        done
    fi
    mkdir -p "$DOWNLOAD_DIR"
    INSTALLER="$DOWNLOAD_DIR/$name"
    say "Downloading Radmin VPN $RADMIN_VERSION..."
    curl -fL -o "$INSTALLER" "$INSTALLER_URL" 2>/dev/null \
        || { rm -f "$INSTALLER"; die "download failed"; }
}
if [ "$DO_UPDATE" -eq 1 ] && [ -z "$INSTALLER_EXPLICIT" ]; then
    INSTALLER=""
fi

# ── Routes ────────────────────────────────────────────────────────────────────
# macOS keeps one unscoped route per destination, so "append" as on Linux is not
# possible: we move the route to the feth and remember where it was. A route
# that did not exist before is recorded with iface "-" and deleted on exit.
# SAVED_ROUTES is mirrored to $ROUTES_STATE for macos_guard.sh, which restores
# it as root if we die without being able to (no tty, no sudo ticket).
# Interface of the route for exactly <kind> <dest>, or nothing. `route get` on
# a network's own address can answer "default" (it does for the cloning
# 224.0.0.0/4), so for a network ask about its first host and check that the
# match is that network.
_route_exact_iface() {   # _route_exact_iface <-host|-net> <dest[/len]>
    local kind="$1" net="${2%/*}" probe="${2%/*}"
    [ "$kind" = "-net" ] && probe="${net%.*}.$(( ${net##*.} + 1 ))"
    route -n get "$probe" 2>/dev/null | awk -v d="$net" '
        /destination:/ { dst = $2 } /interface:/ { ifc = $2 }
        END { if (dst == d) print ifc }'
}

_save_routes_state() {
    mkdir -p "$STATE_DIR"
    printf '%s' "$SAVED_ROUTES" > "$ROUTES_STATE"
}

steal_route() {   # steal_route <-host|-net> <dest>
    local kind="$1" dest="$2" orig
    orig=$(_route_exact_iface "$kind" "$dest")
    [ "$orig" = "$TAP_DEV" ] && return 0
    if [ -n "$orig" ]; then
        # Record first, so a crash between here and the change is undone too.
        SAVED_ROUTES+="$kind $dest $orig"$'\n'; _save_routes_state
        sudo route -n change "$kind" "$dest" -interface "$TAP_DEV" >/dev/null 2>&1 || true
        # `route change` can report success yet leave a cloning route such as
        # 224.0.0.0/4 on its interface: check, and replace it if it stuck.
        if [ "$(_route_exact_iface "$kind" "$dest")" != "$TAP_DEV" ]; then
            sudo route -n delete "$kind" "$dest" >/dev/null 2>&1 || true
            sudo route -n add "$kind" "$dest" -interface "$TAP_DEV" >/dev/null 2>&1 || true
        fi
    else
        SAVED_ROUTES+="$kind $dest -"$'\n'; _save_routes_state
        sudo route -n add "$kind" "$dest" -interface "$TAP_DEV" >/dev/null 2>&1 || true
    fi
    [ "$(_route_exact_iface "$kind" "$dest")" = "$TAP_DEV" ]
}

restore_routes() {   # must run before the feth is destroyed
    local kind dest iface ok=1
    sudo -n true 2>/dev/null || ok=0
    if [ "$ok" -eq 1 ]; then
        while read -r kind dest iface; do
            [ -n "$dest" ] || continue
            # delete + add rather than change: change can silently not apply.
            sudo -n route -n delete "$kind" "$dest" >/dev/null 2>&1 || true
            if [ "$iface" != "-" ]; then
                sudo -n route -n add "$kind" "$dest" -interface "$iface" >/dev/null 2>&1 || ok=0
            fi
        done <<< "$SAVED_ROUTES"
    fi
    SAVED_ROUTES=""
    # Without sudo, leave the state file: macos_guard.sh restores from it.
    [ "$ok" -eq 1 ] && rm -f "$ROUTES_STATE"
    return 0
}

# ── netsh relay ───────────────────────────────────────────────────────────────
# netsh.exe (src/netsh_wrapper.c) writes Linux `ip` command lines. Rather than
# feed them to a root shell, match the four shapes it can produce and run the
# ifconfig equivalent; anything else is dropped.
_cidr_mask() {
    local n="$1" m=() i
    for i in 0 1 2 3; do
        if [ "$n" -ge 8 ]; then m+=(255); n=$((n - 8))
        else m+=($(( 256 - (1 << (8 - n)) ))); n=0; fi
    done
    local IFS=.; echo "${m[*]}"
}

relay_one() {
    local cmd="$1" ip4='([0-9]{1,3}\.){3}[0-9]{1,3}'
    # Groups: 1 = address, 2 = last repeated octet of ip4, 3 = prefix length.
    if [[ "$cmd" =~ ^ip\ addr\ add\ ($ip4)/([0-9]{1,2})\  ]]; then
        sudo -n ifconfig "$TAP_DEV" inet "${BASH_REMATCH[1]}" \
            netmask "$(_cidr_mask "${BASH_REMATCH[3]}")" up
    elif [[ "$cmd" =~ ^ip\ -6\ addr\ add\ ([0-9a-fA-F:]+)/128\  ]]; then
        sudo -n ifconfig "$TAP_DEV" inet6 "${BASH_REMATCH[1]}" prefixlen 128 alias
    elif [[ "$cmd" =~ ^ip\ link\ set\ [a-z0-9]+\ up$ ]]; then
        sudo -n ifconfig "$TAP_DEV" up
    elif [[ "$cmd" =~ ^ip\ addr\ flush\  ]]; then
        local a
        for a in $(ifconfig "$TAP_DEV" | awk '$1 == "inet" {print $2}'); do
            sudo -n ifconfig "$TAP_DEV" inet "$a" delete
        done
    else
        echo "relay: dropped unrecognised command: $cmd" >> /tmp/radmin_relay.log
    fi
}

# ── Teardown ──────────────────────────────────────────────────────────────────
destroy_feth() {   # -n: never hang on a password prompt with no tty
    sudo -n ifconfig "$TAP_DEV" destroy 2>/dev/null || true
    sudo -n ifconfig "$TAP_PEER" destroy 2>/dev/null || true
}

HAVE_SUDO=0   # cleanup only touches root state once sudo was primed

cleanup() {
    # Best effort, every step: after the Terminal window closes the first echo
    # fails with EIO, and under set -e that silently skipped all the rest.
    set +e
    # A dying service during teardown must not look like a crash to restart.
    trap '' USR1
    [ -n "$WATCHDOG_PID" ] && kill "$WATCHDOG_PID" 2>/dev/null || true
    echo
    say "Closing Radmin VPN..."
    wineserver -k 2>/dev/null || true
    [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
    if [ "$HAVE_SUDO" -eq 1 ]; then
        # Bridge first, so it isn't left reading a destroyed interface.
        sudo -n pkill -x tap_bridge 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x tap_bridge >/dev/null || break
            sleep 0.2
        done
        restore_routes
        destroy_feth
    fi
    rm -f "$CMD_FILE" "${CMD_FILE}.proc" /tmp/rvpn_b2d /tmp/rvpn_d2b \
          /tmp/rvpn_d2b_high /tmp/rvpn_d2b_low /tmp/rvpn_mac
    if [ "$RESTART_REQUESTED" -eq 1 ]; then
        export RVPN_RESTARTS=$((RVPN_RESTARTS + 1))
        say "Restarting Radmin VPN (attempt $RVPN_RESTARTS of $MAX_RESTARTS)..."
        # Same PID, so the keepalive keeps serving us and the guardian keeps
        # waiting; both see the fresh session.
        exec "$SELF" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
    fi
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

# The watchdog signals USR1 when the bridge or the service is gone: tear
# everything down and start over (cleanup re-execs us), a few times at most.
on_crash() {
    # Only crashes in quick succession count towards the limit.
    if [ -n "${SESSION_START:-}" ] && [ $(( $(date +%s) - SESSION_START )) -gt 600 ]; then
        RVPN_RESTARTS=0
    fi
    if [ "$RVPN_RESTARTS" -ge "$MAX_RESTARTS" ]; then
        warn "VPN failed $RVPN_RESTARTS times in a row — giving up. Logs: /tmp/radmin_bridge.log, /tmp/radmin_service.log"
        exit 1
    fi
    warn "$(cat "$STATE_DIR/crash_reason" 2>/dev/null || echo 'VPN component died') — restarting the VPN"
    RESTART_REQUESTED=1
    exit 1
}
trap on_crash USR1

dump_diagnostics_macos() {
    echo ""
    warn "$1"
    echo ""
    dump_log "driver"  /tmp/radmin_driver.log
    dump_log "bridge"  /tmp/radmin_bridge.log
    dump_log "relay"   /tmp/radmin_relay.log
    dump_log "service (wine)" /tmp/radmin_service.log
    dump_log "service (Radmin)" "$LOG" utf16
    dump_log "hook"    "$WINEPREFIX/drive_c/radmin_hook_debug.log"
    echo "--- ifconfig $TAP_DEV ---"
    ifconfig "$TAP_DEV" 2>&1 | sed 's/^/  /'
    echo "--- routes ---"
    netstat -rn -f inet 2>/dev/null | grep -E "^(default|26|224|255)" | sed 's/^/  /'
    echo ""
}

say "Radmin VPN for macOS"

# ── Prerequisites ─────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "this launcher is for macOS; use ./run.sh on Linux"
if [ "$(uname -m)" = "arm64" ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
    die "Rosetta 2 is not installed (Wine runs x86_64 code). Install it with:
    softwareupdate --install-rosetta --agree-to-license"
fi
for f in tap_bridge rvpnnetmp.sys adapter_hook.dll rvpn_launcher.exe netsh.exe netsh64.exe drvinst.exe; do
    [ -f "$BUILD_DIR/$f" ] || die "missing $BUILD_DIR/$f — run 'make -f Makefile.macos' first"
done
command -v python3 >/dev/null || die "python3 not found (xcode-select --install)"

WINE_MAJOR=$(wine_major || echo 0)
if ! [ "${WINE_MAJOR:-0}" -ge 11 ] 2>/dev/null; then
    die "Wine $(wine_version_str || echo '?') too old or not runnable — requires Wine >= 11.0"
fi
if [ "$USE_CROSSOVER" -eq 1 ]; then
    say "Wine: $(wine_version_str) (CrossOver, bottle $CX_BOTTLE_NAME)"
else
    say "Wine: $(wine_version_str)"
fi

sudo -v || die "sudo is required for the feth interfaces, BPF and routes"
HAVE_SUDO=1
# The relay and cleanup need sudo long after the 5-minute ticket would expire.
# `kill -0 $$`: stop with us even if we die without running cleanup.
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!; disown

# Root-side teardown that survives us (see macos_guard.sh). One per launch: a
# watchdog restart re-execs with the same PID, which the guardian keeps
# waiting on.
if [ -z "${RVPN_GUARD_STARTED:-}" ]; then
    mkdir -p "$STATE_DIR"
    if [ "$USE_CROSSOVER" -eq 1 ]; then _ws="$CX_ROOT/bin/wineserver"; else _ws=$(command -v wineserver || true); fi
    sudo -b /bin/bash "$DIR/macos_guard.sh" $$ "$ROUTES_STATE" "$TAP_DEV" "$TAP_PEER" \
        "$_ws" "$WINEPREFIX" \
        </dev/null >/dev/null 2>&1 || warn "could not start macos_guard.sh — cleanup needs this terminal open"
    export RVPN_GUARD_STARTED=1
fi
# A previous run that died before cleanup (and before its guardian could act)
# leaves stolen routes behind: put them back now.
if [ -s "$ROUTES_STATE" ] && [ "$RVPN_RESTARTS" -eq 0 ]; then
    SAVED_ROUTES=$(cat "$ROUTES_STATE")$'\n'
    say "Restoring routes left by an earlier run..."
    restore_routes
fi

# ── 1. Quiet the prefix ───────────────────────────────────────────────────────
pkill -f "RvControlSvc|RvRvpnGui|rvpn_launcher" 2>/dev/null || true
sleep 0.3
wineserver -k 2>/dev/null || true
scrub_ndis_driver

# ── 2. Install / update Radmin ────────────────────────────────────────────────
install_radmin() {
    ensure_installer
    [ -n "$INSTALLER" ] && [ -f "$INSTALLER" ] || die "installer not found"
    if ! verify_installer "$INSTALLER"; then
        case "$INSTALLER" in
            "$DOWNLOAD_DIR"/*)
                rm -f -- "$INSTALLER"
                die "installer failed verification; cached copy removed — re-run to download it again" ;;
            *)
                die "installer failed verification — refusing to run it" ;;
        esac
    fi
    if [ "$USE_CROSSOVER" -eq 1 ] && [ ! -f "$WINEPREFIX/cxbottle.conf" ]; then
        say "Creating CrossOver bottle $CX_BOTTLE_NAME..."
        "$CX_ROOT/bin/cxbottle" --bottle "$CX_BOTTLE_NAME" --create --template win10_64 \
            --description "Radmin VPN (radmin-vpn-linux macOS port)" >/dev/null
    fi
    mkdir -p "$WINEPREFIX"
    wineboot --init >/dev/null 2>&1 || true
    wineserver -k 2>/dev/null || true
    say "Running installer..."
    wine "$INSTALLER" /VERYSILENT /NORESTART >/dev/null 2>&1 || true
    say "Waiting for installer to finish..."
    for _ in $(seq 1 60); do
        sleep 0.5
        [ -f "$RADMIN/RvControlSvc.exe" ] && break
    done
    [ -f "$RADMIN/RvControlSvc.exe" ] || die "installation failed"
    wineserver -k 2>/dev/null || true
    scrub_ndis_driver
    wine reg add "HKLM\\SYSTEM\\CurrentControlSet\\Services\\RvControlSvc" /v Start /t REG_DWORD /d 4 /f > /dev/null 2>&1 || true
    wineserver -k 2>/dev/null || true
}

INSTALLED_VERSION="$(radmin_installed_version)"
if [ ! -f "$RADMIN/RvControlSvc.exe" ]; then
    say "Installing Radmin VPN $RADMIN_VERSION (first run — this takes a moment)..."
    install_radmin
    good "Radmin VPN $(radmin_installed_version || echo "$RADMIN_VERSION") installed"
elif [ "$DO_UPDATE" -eq 1 ]; then
    if [ -n "$INSTALLED_VERSION" ] && ! version_gt "$RADMIN_VERSION" "$INSTALLED_VERSION"; then
        good "Radmin VPN $INSTALLED_VERSION is already current — nothing to update"
    else
        say "Updating Radmin VPN ${INSTALLED_VERSION:-?} → $RADMIN_VERSION (prefix and RID are kept)..."
        install_radmin
        good "Radmin VPN updated"
    fi
elif [ -n "$INSTALLED_VERSION" ] && version_gt "$RADMIN_VERSION" "$INSTALLED_VERSION"; then
    warn "Radmin VPN $INSTALLED_VERSION installed, $RADMIN_VERSION validated — run './run_macos.sh --update'"
fi

install_components

# ── 3. Adapter MAC ────────────────────────────────────────────────────────────
if [ -f "$MAC_FILE" ]; then
    ADAPTER_MAC=$(cat "$MAC_FILE")
else
    ADAPTER_MAC=$(printf '02:%02x:%02x:%02x:%02x:%02x' \
        $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))
    echo "$ADAPTER_MAC" > "$MAC_FILE"
    good "Generated adapter MAC: $ADAPTER_MAC"
fi
printf '%b' "$(echo "$ADAPTER_MAC" | sed 's/://g; s/../\\x&/g')" > /tmp/rvpn_mac

# ── 4. feth pair ──────────────────────────────────────────────────────────────
say "Creating feth pair $TAP_DEV ⇄ $TAP_PEER..."
destroy_feth
sudo ifconfig "$TAP_PEER" create     || die "cannot create $TAP_PEER"
sudo ifconfig "$TAP_DEV" create      || die "cannot create $TAP_DEV"
sudo ifconfig "$TAP_DEV" lladdr "$ADAPTER_MAC"
sudo ifconfig "$TAP_DEV" peer "$TAP_PEER" || die "cannot peer $TAP_DEV with $TAP_PEER"
sudo ifconfig "$TAP_PEER" mtu 1500 up
sudo ifconfig "$TAP_DEV" mtu 1500 up
good "$TAP_DEV up (MAC=$ADAPTER_MAC)"

# ── 5. Bridge ─────────────────────────────────────────────────────────────────
say "Starting tap_bridge..."
sudo pkill -x tap_bridge 2>/dev/null || true
rm -f /tmp/rvpn_b2d /tmp/rvpn_d2b /tmp/rvpn_d2b_high /tmp/rvpn_d2b_low
sudo "$BUILD_DIR/tap_bridge" "$TAP_DEV" "$TAP_PEER" > /tmp/radmin_bridge.log 2>&1 &
BRIDGE_PID=$!
for _ in $(seq 1 20); do
    [ -p /tmp/rvpn_b2d ] && [ -p /tmp/rvpn_d2b_low ] && break
    sleep 0.1
done
if [ ! -p /tmp/rvpn_b2d ] || [ ! -p /tmp/rvpn_d2b_low ]; then
    cat /tmp/radmin_bridge.log >&2
    die "tap_bridge failed to create FIFOs"
fi
good "tap_bridge running (pid=$BRIDGE_PID)"

# ── 6. Registry ───────────────────────────────────────────────────────────────
say "Detecting adapter GUID..."
TAP_GUID=$(_timeout 20 wine wmic path Win32_NetworkAdapter get Name,GUID 2>/dev/null \
    | grep "$TAP_DEV" | awk '{print $1}' | tr -d '\r' || true)
if [ -z "$TAP_GUID" ]; then
    h=$(printf '%s\n' "$ADAPTER_MAC" | sed 's/://g' | md5 -q)
    TAP_GUID="{${h:0:8}-${h:8:4}-4${h:12:3}-${h:16:4}-${h:20:12}}"
fi
good "Adapter GUID: $TAP_GUID"

say "Configuring registry..."
{
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0099" /v NetCfgInstanceId /t REG_SZ /d "$TAP_GUID" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\0099" /v MatchingDeviceId /t REG_SZ /d "${TAP_GUID}\\RvNetMP60" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network\{4d36e972-e325-11ce-bfc1-08002be10318}\\${TAP_GUID}\Connection" /v Name /t REG_SZ /d "Radmin VPN" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Control\Network\{4d36e972-e325-11ce-bfc1-08002be10318}\\${TAP_GUID}\Connection" /v PnpInstanceID /t REG_SZ /d "ROOT\NET\0099" /f
wine reg add "HKLM\Software\Wow6432Node\Famatech\RadminVPN\1.0\Firewall" /v AdapterId /t REG_SZ /d "$TAP_GUID" /f
wine reg add "HKLM\SOFTWARE\Famatech\RadminVPN\1.0\Registration" /f
wine reg add "HKCU\Software\Wine\DllOverrides" /v winemenubuilder.exe /t REG_SZ /d "" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v DisplayName /t REG_SZ /d "Radmin VPN TAP Bridge" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v ImagePath /t REG_EXPAND_SZ /d "C:\windows\system32\drivers\rvpnnetmp.sys" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v Start /t REG_DWORD /d 2 /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v Type /t REG_DWORD /d 1 /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v Group /t REG_SZ /d "NDIS" /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\rvpnnetmp" /v ErrorControl /t REG_DWORD /d 0 /f
wine reg add "HKLM\SYSTEM\CurrentControlSet\Services\RvControlSvc" /v Start /t REG_DWORD /d 4 /f || true
} > /dev/null 2>&1
rm -f /tmp/radmin_driver.log

# ── GUI rendering ─────────────────────────────────────────────────────────────
# Radmin's Qt GUI asks for "MS Shell Dlg 2", i.e. Tahoma. Wine resolves that to
# its own stand-in tahoma.ttf (revision 0.001, ~1000 glyphs, odd shapes). macOS
# ships Microsoft's real Tahoma 5.x; a copy in the prefix's Fonts dir wins
# because Wine keeps the higher-revision face when two share a name.
for _f in "Tahoma.ttf:tahoma.ttf" "Tahoma Bold.ttf:tahomabd.ttf"; do
    _src="/System/Library/Fonts/Supplemental/${_f%%:*}"
    [ -f "$_src" ] && cp -f "$_src" "$WINEPREFIX/drive_c/windows/Fonts/${_f##*:}" 2>/dev/null || true
done
# Retina: let the Mac driver expose real pixels and tell Windows apps the
# screen is 192 DPI; Qt then scales itself by 2 (QT_AUTO_SCREEN_SCALE_FACTOR
# in start_gui) instead of macOS blowing up a 1x bitmap.
if [ "$RETINA" -eq 1 ]; then _retina=y; _dpi=192; else _retina=n; _dpi=96; fi
{
wine reg add "HKCU\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d "$_retina" /f
wine reg add "HKCU\\Control Panel\\Desktop" /v LogPixels /t REG_DWORD /d "$_dpi" /f
wine reg add "HKLM\\System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts" /v LogPixels /t REG_DWORD /d "$_dpi" /f
} > /dev/null 2>&1

wineserver -k 2>/dev/null || true
boot_wineserver
good "Registry configured"

# ── 7. netsh relay ────────────────────────────────────────────────────────────
rm -f "$CMD_FILE" "${CMD_FILE}.proc" /tmp/radmin_relay.log
(
    while kill -0 $$ 2>/dev/null; do   # never outlive the launcher
        if [ -f "$CMD_FILE" ]; then
            mv "$CMD_FILE" "${CMD_FILE}.proc" 2>/dev/null || continue
            while IFS= read -r line; do
                line=$(printf '%s' "$line" | tr -d '\r')
                # One netsh call can chain two commands with "; ".
                IFS=';' read -ra parts <<< "$line"
                for p in "${parts[@]}"; do
                    p="${p# }"; p="${p% 2>/dev/null}"; p="${p% }"
                    [ -n "$p" ] && relay_one "$p" 2>>/tmp/radmin_relay.log
                done
            done < "${CMD_FILE}.proc"
            rm -f "${CMD_FILE}.proc"
        fi
        sleep 0.1
    done
) &
RELAY_PID=$!; disown

# ── 8. Service ────────────────────────────────────────────────────────────────
rm -f "$LOG" "$WINEPREFIX/drive_c/radmin_driver.log" "$WINEPREFIX/drive_c/radmin_hook_debug.log"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}netsh.exe=n"

say "Starting Radmin VPN service..."
cd "$RADMIN"
(
    export WINEDEBUG="${RVPN_SVC_WINEDEBUG:--all}" WINE_LARGE_ADDRESS_AWARE=1
    # exec bypasses shell functions, so name CrossOver's wrapper explicitly.
    # Absolute paths: CrossOver's wrapper does not resolve a bare exe name
    # against the current directory.
    if [ "$USE_CROSSOVER" -eq 1 ]; then
        exec "$CX_ROOT/bin/wine" "$RADMIN/rvpn_launcher.exe" /run
    fi
    exec wine "$RADMIN/rvpn_launcher.exe" /run
) > /tmp/radmin_service.log 2>&1 &

say "Waiting for service to become ready..."
SERVICE_START=$(date +%s)
vpn_ip=""
for _ in $(seq 1 120); do
    sleep 0.5
    if [ -f "$LOG" ]; then
        log_txt=$(iconv -f UTF-16LE -t UTF-8 "$LOG" 2>/dev/null || true)
        if printf '%s' "$log_txt" | grep -qE 'Service version: *1\.4'; then
            die "Radmin VPN 1.4 is not supported — run './run_macos.sh --update'"
        fi
        vpn_ip=$(printf '%s' "$log_txt" | python3 -c "
import sys, re
lines = sys.stdin.read().strip().split('\n')
if any('adapter ready' in l for l in lines):
    for l in reversed(lines):
        if 'Registered as' in l or ('IP:' in l and '0.0.0.0' not in l):
            m = re.search(r'26\.\d+\.\d+\.\d+', l)
            if m: print(m.group()); break
" 2>/dev/null)
        [ -n "$vpn_ip" ] && break
    fi
    # CrossOver's perl wrapper takes seconds to get RvControlSvc on its feet,
    # so only call it dead after a grace period.
    pgrep -f RvControlSvc >/dev/null || [ $(( $(date +%s) - SERVICE_START )) -lt 20 ] || {
        dump_diagnostics_macos "Service started then died (waited $(( $(date +%s) - SERVICE_START ))s)"
        die "service exited"
    }
done

if [ -z "$vpn_ip" ]; then
    dump_diagnostics_macos "Service alive but never became ready (timed out after $(( $(date +%s) - SERVICE_START ))s)"
    die "Service never reported ready — see diagnostics above."
fi
good "Adapter ready — VPN IP: $vpn_ip"

# ── 9. Address and routes ─────────────────────────────────────────────────────
sudo ifconfig "$TAP_DEV" inet "$vpn_ip" netmask 255.0.0.0 up 2>/dev/null || true
steal_route -net 26.0.0.0/8 || warn "could not route 26.0.0.0/8 to $TAP_DEV"
good "Route: 26.0.0.0/8 → $TAP_DEV"
# Minecraft Java "Open to LAN" group, as on Linux (issue #17).
steal_route -host 224.0.2.60 || true
if [ "$NO_BCAST_ROUTES" = "0" ]; then
    # LAN-game discovery. Moves these off your Wi-Fi until exit; Bonjour and
    # AirDrop pick their interface explicitly and are not affected.
    steal_route -host 255.255.255.255 && good "Route: broadcast → $TAP_DEV" \
        || warn "could not move the broadcast route to $TAP_DEV"
    steal_route -net 224.0.0.0/4 && good "Route: multicast → $TAP_DEV (--no-broadcast-routes to skip both)" \
        || warn "could not move the multicast route to $TAP_DEV"
fi

# ── Watchdog ──────────────────────────────────────────────────────────────────
# If the bridge or the service dies, Radmin can keep showing peers online while
# nothing passes. Notice it and have on_crash restart the whole VPN.
SESSION_START=$(date +%s)
rm -f "$STATE_DIR/crash_reason"
(
    while kill -0 $$ 2>/dev/null; do
        sleep 3
        reason=""
        pgrep -x tap_bridge >/dev/null || reason="tap_bridge stopped (see /tmp/radmin_bridge.log)"
        pgrep -f 'RvControlSvc.exe' >/dev/null || reason="Radmin service stopped (see /tmp/radmin_service.log)"
        if [ -n "$reason" ]; then
            echo "$reason" > "$STATE_DIR/crash_reason"
            kill -USR1 $$ 2>/dev/null
            break
        fi
    done
) &
WATCHDOG_PID=$!; disown

# ── 10. GUI ───────────────────────────────────────────────────────────────────
GUI_PID=""
start_gui() {
    # Qt Quick's default distance-field text turns blurry under Wine; native
    # glyph rasterisation keeps it crisp. Wine passes these to the Qt process.
    (
        export QML_DISABLE_DISTANCEFIELD=1
        [ "$RETINA" -eq 1 ] && export QT_AUTO_SCREEN_SCALE_FACTOR=1
        WINEDEBUG="${RVPN_GUI_WINEDEBUG:--all}" wine "$RADMIN/RvRvpnGui.exe"
    ) > /tmp/radmin_gui.log 2>&1 &
    GUI_PID=$!
}
if [ "$NO_UI" -eq 0 ]; then
    say "Starting GUI..."
    start_gui
else
    say "--no-ui: GUI not launched (service runs headless)"
fi

good "Radmin VPN running — close the GUI or press Ctrl+C to stop."

GUI_RESTARTED=0
while [ -n "$GUI_PID" ]; do
    _gui_rc=0
    wait "$GUI_PID" || _gui_rc=$?
    [ "$_gui_rc" -eq 0 ] && break
    if [ "$GUI_RESTARTED" -eq 0 ]; then
        warn "GUI exited abnormally (code $_gui_rc) — VPN stays up, restarting the GUI once"
        GUI_RESTARTED=1
        start_gui
    else
        warn "GUI crashed again (code $_gui_rc) — continuing headless, VPN still up. Ctrl+C to stop."
        GUI_PID=""
    fi
done
if [ -z "$GUI_PID" ]; then
    # Headless: idle until Ctrl+C or the watchdog. `wait` on a short-lived
    # sleep keeps us interruptible by its USR1.
    while true; do sleep 60 & wait $! || true; done
fi
