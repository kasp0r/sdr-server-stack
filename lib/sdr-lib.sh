#!/usr/bin/env bash
# sdr-lib.sh — shared helpers for the SDR server toolset.
# This file is sourced by the `sdr` CLI; it is not meant to be run directly.

# ---------------------------------------------------------------------------
# Colour / formatting
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
# The lib lives in lib/ directly under the repo root (where sdr.conf lives).
SCRIPT_DIR="$(cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")" && pwd)"
CONF_FILE="${SDR_CONF:-$SCRIPT_DIR/sdr.conf}"

if [ "$(id -u)" = "0" ]; then
  PID_DIR="${SDR_PID_DIR:-/run/sdr-server}"
  LOG_DIR="${SDR_LOG_DIR:-/var/log/sdr-server}"
else
  PID_DIR="${SDR_PID_DIR:-${XDG_RUNTIME_DIR:-/tmp}/sdr-server}"
  LOG_DIR="${SDR_LOG_DIR:-$HOME/.local/state/sdr-server}"
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Defaults (overridable from the config file).
LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
DEFAULT_SAMPLE_RATE="${DEFAULT_SAMPLE_RATE:-2048000}"
DEFAULT_GAIN="${DEFAULT_GAIN:-0}"
SERVERS="${SERVERS:-}"

sdr_load_config() {
  if [ ! -f "$CONF_FILE" ]; then
    echo "error: config file not found: $CONF_FILE" >&2
    echo "       copy sdr.conf.example to that path and edit it." >&2
    return 1
  fi
  # shellcheck disable=SC1090
  . "$CONF_FILE"
  LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
  DEFAULT_SAMPLE_RATE="${DEFAULT_SAMPLE_RATE:-2048000}"
  DEFAULT_GAIN="${DEFAULT_GAIN:-0}"
}

# sdr_cfg NAME KEY  -> value of SDR_<NAME>_<KEY> (empty if unset)
sdr_cfg() {
  local var="SDR_${1}_${2}"
  echo "${!var:-}"
}

sdr_cfg_default() { # sdr_cfg_default NAME KEY DEFAULT
  local v
  v="$(sdr_cfg "$1" "$2")"
  [ -n "$v" ] && { echo "$v"; return; }
  echo "$3"
}

# ---------------------------------------------------------------------------
# Physical device inventory (via sysfs, no special privileges needed)
# ---------------------------------------------------------------------------
# A dongle is considered "in use" when libusb has claimed its interface
# (interface driver == usbfs). A free dongle has no interface driver bound.
declare -A SDR_PATH SDR_BUSNUM SDR_DEVNUM SDR_PRODUCT SDR_MANUFACTURER
declare -A SDR_STATE SDR_SYMLINK
SDR_SERIALS=()

# sdr_device_state DEVPATH -> free | in-use | kernel | unknown
sdr_device_state() {
  local dev="$1" devname if drv state="free"
  devname="$(basename "$dev")"
  for if in "$dev"/"$devname":*/; do
    [ -d "$if" ] || continue
    drv="$(readlink "$if/driver" 2>/dev/null)"
    [ -n "$drv" ] || continue
    case "$(basename "$drv")" in
      usbfs)                          state="in-use"; break ;;
      dvb_usb_rtl28xxu|dvb_usb_v2)    state="kernel";  break ;;
      *)                              state="unknown"; break ;;
    esac
  done
  echo "$state"
}

# sdr_symlink_for SERIAL -> /dev/rtl_sdr_* friendly name (or empty)
sdr_symlink_for() {
  local serial="$1" busnum devnum lnk tgt devnode
  busnum="${SDR_BUSNUM[$serial]}"; devnum="${SDR_DEVNUM[$serial]}"
  devnode="$(printf '/dev/bus/usb/%03d/%03d' "$busnum" "$devnum")"
  for lnk in /dev/rtl_sdr_*; do
    [ -L "$lnk" ] || continue
    tgt="$(readlink -f "$lnk")"
    [ "$tgt" = "$devnode" ] && { basename "$lnk"; return 0; }
  done
  echo ""
}

sdr_scan() {
  SDR_SERIALS=()
  local dev d serial product man busnum devnum
  for dev in /sys/bus/usb/devices/*/; do
    [ -f "$dev/idVendor" ] || continue
    [ "$(cat "$dev/idVendor" 2>/dev/null)" = "0bda" ] || continue
    [ "$(cat "$dev/idProduct" 2>/dev/null)" = "2838" ] || continue
    serial="$(cat "$dev/serial" 2>/dev/null)"
    [ -n "$serial" ] || continue
    d="$(basename "$dev")"
    product="$(cat "$dev/product" 2>/dev/null)"
    man="$(cat "$dev/manufacturer" 2>/dev/null)"
    busnum="$(cat "$dev/busnum" 2>/dev/null)"
    devnum="$(cat "$dev/devnum" 2>/dev/null)"
    SDR_PATH[$serial]="$d"
    SDR_BUSNUM[$serial]="$busnum"
    SDR_DEVNUM[$serial]="$devnum"
    SDR_PRODUCT[$serial]="$product"
    SDR_MANUFACTURER[$serial]="$man"
    SDR_SYMLINK[$serial]="$(sdr_symlink_for "$serial")"
    SDR_STATE[$serial]="$(sdr_device_state "$dev")"
    SDR_SERIALS+=("$serial")
  done
}

# sdr_state_of SERIAL -> free | in-use | kernel | unknown | missing
sdr_state_of() {
  local serial="$1" dev
  dev="/sys/bus/usb/devices/${SDR_PATH[$serial]:-__none__}"
  [ -d "$dev" ] || { echo "missing"; return 0; }
  sdr_device_state "$dev"
}

# sdr_device_process SERIAL -> "name (pid)" of a process referencing the serial
sdr_device_process() {
  local serial="$1" p cmd pid name
  for p in /proc/[0-9]*/cmdline; do
    [ -r "$p" ] || continue
    cmd="$(tr '\0' ' ' < "$p" 2>/dev/null)"
    case "$cmd" in
      *"$serial"*)
        pid="${p#/proc/}"; pid="${pid%/cmdline}"
        name="$(cat "/proc/$pid/comm" 2>/dev/null)"
        echo "${name:-?} ($pid)"
        return 0
        ;;
    esac
  done
  echo ""
}

# ---------------------------------------------------------------------------
# Server (rtl_tcp instance) helpers
# ---------------------------------------------------------------------------
sdr_pidfile()  { echo "$PID_DIR/$1.pid"; }
sdr_logfile()  { echo "$LOG_DIR/$1.log"; }

sdr_server_pid() {
  local pid
  pid="$(cat "$(sdr_pidfile "$1")" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  echo "$pid"
}

sdr_server_running() {
  local pid
  pid="$(sdr_server_pid "$1")" || return 1
  kill -0 "$pid" 2>/dev/null
}

sdr_port_in_use() {
  ss -tlnH "sport = :$1" 2>/dev/null | grep -q .
}

# Build the rtl_tcp argv for a server into the global array CMD.
sdr_build_cmd() {
  local name="$1" serial port addr gain rate freq ppm bias ds extra
  serial="$(sdr_cfg "$name" SERIAL)"
  port="$(sdr_cfg "$name" PORT)"
  addr="$LISTEN_ADDRESS"
  gain="$(sdr_cfg "$name" GAIN)";      [ -z "$gain" ] && gain="$DEFAULT_GAIN"
  rate="$(sdr_cfg "$name" SAMPLE_RATE)"; [ -z "$rate" ] && rate="$DEFAULT_SAMPLE_RATE"
  freq="$(sdr_cfg "$name" FREQUENCY)"
  ppm="$(sdr_cfg "$name" PPM)"
  bias="$(sdr_cfg "$name" BIAS_TEE)"
  ds="$(sdr_cfg "$name" DIRECT_SAMPLING)"
  extra="$(sdr_cfg "$name" EXTRA_ARGS)"

  CMD=(rtl_tcp -d "$serial" -a "$addr" -p "$port")
  [ -n "$freq" ] && CMD+=(-f "$freq")
  [ -n "$gain" ] && [ "$gain" != "0" ] && CMD+=(-g "$gain")
  [ -n "$rate" ] && CMD+=(-s "$rate")
  [ -n "$ppm" ] && [ "$ppm" != "0" ] && CMD+=(-P "$ppm")
  [ "$bias" = "1" ] && CMD+=(-T)
  [ -n "$ds" ] && [ "$ds" != "0" ] && CMD+=(-D "$ds")
  if [ -n "$extra" ]; then
    # shellcheck disable=SC2206
    CMD+=($extra)
  fi
}

sdr_cmd_string() { # sdr_cmd_string NAME -> printable command
  sdr_build_cmd "$1"
  local out="" a
  for a in "${CMD[@]}"; do
    out+="$(printf '%q ' "$a")"
  done
  echo "${out% }"
}

# Validate that NAME is a configured server. Prints nothing, sets exit status.
sdr_valid_server() {
  local name
  for name in $SERVERS; do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

sdr_servers_list() { # expand "all" or comma/space list into SERVER_TARGETS[]
  SERVER_TARGETS=()
  local arg="$1" name
  if [ -z "$arg" ] || [ "$arg" = "all" ]; then
    for name in $SERVERS; do SERVER_TARGETS+=("$name"); done
  else
    IFS=', ' read -r -a SERVER_TARGETS <<< "$arg"
  fi
}
