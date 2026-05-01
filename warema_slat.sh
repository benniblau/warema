#!/bin/bash

# WAREMA Slat Control Shell Script
# Controls slat rotation via direct API calls to WMS WebControl Pro
# Usage: ./warema_slat.sh <percentage|raw|get|status|stop|impulse|devices> [options]
# Requires: curl, bc, grep, sed (standard Unix tools only)

set -euo pipefail

# Configuration with defaults (can be overridden by .env file)
WAREMA_HOST="${WAREMA_HOST:-10.10.1.229}"
DEVICE_ID="${DEVICE_ID:-57789}"
ACTION_ID="${ACTION_ID:-6}"
STOP_ACTION_ID="${STOP_ACTION_ID:-16}"
IMPULSE_ACTION_ID="${IMPULSE_ACTION_ID:-23}"
TIMEOUT="${TIMEOUT:-10}"

# Slat rotation range: 0% maps to SLAT_MIN_RAW, 100% maps to SLAT_MAX_RAW
# Tune these via .env if the physical endpoints differ from the defaults.
# Device reports actual position from WMS radio; use `raw` + `status` to calibrate.
SLAT_MIN_RAW="${SLAT_MIN_RAW:--45}"
SLAT_MAX_RAW="${SLAT_MAX_RAW:-90}"

# State file: last-sent position (used as fallback when live status unavailable)
STATE_FILE="${STATE_FILE:-/tmp/warema_${DEVICE_ID}_state}"

# DrivingCause IDs — what triggered the last movement
# 0=None 1=Sun 2=Dusk/Dawn 3=Wind 4=Rain 5=Ice 6=Temp 7=Time 8=Scene
# 9=ControlMode 10=Manual 11=Safety 12=Contact 13=Central 999=Unknown
SAFETY_CAUSES="${SAFETY_CAUSES:-3 4 5 11}"   # Wind, Rain, Ice, Safety

show_help() {
    cat << EOF
WAREMA Slat Control Script

Usage: $0 <command> [options]

Commands:
  <percentage>        Set slat angle (0-100; 0=closed, 100=open)
  raw <value>         Send raw rotation value directly (-127 to 127, for calibration)
  get                 Get current position (live if available, otherwise cached)
  status              Show full device status: position, trigger cause, health
  stop                Stop current movement
  impulse up|down     Jog one step up (open) or down (close)
  devices             List all registered devices and actions

Options:
  -h, --help          Show this help
  -v, --verbose       Enable verbose output
  -d, --device ID     Device ID (default: $DEVICE_ID)
  -H, --host HOST     WAREMA host (default: $WAREMA_HOST)
  -s, --silent        Silent mode (default for set operations)
  --force             Override safety hold (ignore Rain/Wind/Ice driving cause)

Slat range (tunable via SLAT_MIN_RAW / SLAT_MAX_RAW in .env):
  0%   = fully closed (raw: $SLAT_MIN_RAW)
  100% = fully open   (raw: $SLAT_MAX_RAW)

DrivingCause safety: set operations are blocked when the last trigger was
Rain (4), Wind (3), Ice (5), or Safety (11). Use --force to override.

Note: getStatus returns live data when the WMS gateway has fresh radio
status from the device; otherwise falls back to the last cached value.
EOF
}

log_info() {
    if [[ "${SILENT:-1}" != "1" ]]; then echo "INFO: $*" >&2; fi
}

log_error() {
    if [[ "${SILENT:-1}" != "1" ]]; then echo "ERROR: $*" >&2; fi
}

log_verbose() {
    if [[ "${VERBOSE:-0}" == "1" && "${SILENT:-1}" != "1" ]]; then echo "VERBOSE: $*" >&2; fi
}

load_env() {
    local env_file="${1:-.env}"
    [[ ! -f "$env_file" ]] && return 0
    log_verbose "Loading configuration from $env_file"
    while IFS='=' read -r key value; do
        [[ $key =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs | sed 's/^["'\'']//' | sed 's/["'\'']$//')
        [[ -n "$key" && -n "$value" ]] && export "$key"="$value" && log_verbose "Loaded: $key=$value"
    done < "$env_file"
}

percentage_to_raw() {
    local percentage="$1"
    if [[ ! "$percentage" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Invalid percentage: $percentage (must be a number)"
        return 1
    fi
    (( $(echo "$percentage < 0" | bc -l) )) && percentage=0
    (( $(echo "$percentage > 100" | bc -l) )) && percentage=100

    local range
    range=$(echo "$SLAT_MAX_RAW - $SLAT_MIN_RAW" | bc)
    local raw_value
    raw_value=$(echo "scale=2; ($percentage / 100.0) * $range + $SLAT_MIN_RAW" | bc -l)
    raw_value=$(printf "%.0f" "$raw_value")
    (( raw_value < -127 )) && raw_value=-127
    (( raw_value > 127 )) && raw_value=127
    echo "$raw_value"
}

raw_to_percentage() {
    local raw_value="$1"
    if [[ ! "$raw_value" =~ ^-?[0-9]+$ ]]; then
        log_error "Invalid raw value: $raw_value"
        return 1
    fi
    (( raw_value < -127 )) && raw_value=-127
    (( raw_value > 127 )) && raw_value=127

    local range
    range=$(echo "$SLAT_MAX_RAW - $SLAT_MIN_RAW" | bc)
    local percentage
    percentage=$(echo "scale=10; ($raw_value - $SLAT_MIN_RAW) * (100.0 / $range)" | bc -l)
    percentage=$(printf "%.1f" "$percentage")
    (( $(echo "$percentage < 0" | bc -l) )) && percentage="0.0"
    (( $(echo "$percentage > 100" | bc -l) )) && percentage="100.0"
    echo "$percentage"
}

driving_cause_name() {
    case "$1" in
        0) echo "None" ;;
        1) echo "Sun" ;;
        2) echo "Dusk/Dawn" ;;
        3) echo "Wind" ;;
        4) echo "Rain" ;;
        5) echo "Ice" ;;
        6) echo "Temperature" ;;
        7) echo "SwitchingTime" ;;
        8) echo "Scene" ;;
        9) echo "ControlMode" ;;
        10) echo "Manual" ;;
        11) echo "Safety" ;;
        12) echo "Contact" ;;
        13) echo "CentralCommand" ;;
        999) echo "Unknown" ;;
        *) echo "Unknown($1)" ;;
    esac
}

# Returns JSON string from getStatus, or empty string on failure.
fetch_device_status() {
    curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"getStatus\",
            \"source\": 2,
            \"responseType\": 1,
            \"destinations\": [$DEVICE_ID]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo ""
}

# Returns the raw rotation value from the live status, or empty string.
get_live_rotation() {
    local status_json
    status_json=$(fetch_device_status)
    if [[ -z "$status_json" ]] || echo "$status_json" | grep -q '"errors"'; then
        echo ""
        return
    fi
    # Extract rotation for our specific actionId from compact JSON
    echo "$status_json" | tr -d '\n' | \
        grep -o "\"actionId\":${ACTION_ID},\"value\":{\"rotation\":[^}]*}" | \
        sed 's/.*"rotation"://' | tr -d '}' | head -1
}

# Returns (rotation, drivingCause, heartbeatError, blocking) from status, one per line.
get_full_status() {
    local status_json
    status_json=$(fetch_device_status)
    if [[ -z "$status_json" ]] || echo "$status_json" | grep -q '"errors"'; then
        echo ""
        return
    fi
    local flat
    flat=$(echo "$status_json" | tr -d '\n')

    local rotation
    rotation=$(echo "$flat" | \
        grep -o "\"actionId\":${ACTION_ID},\"value\":{\"rotation\":[^}]*}" | \
        sed 's/.*"rotation"://' | tr -d '}' | head -1)

    local driving_cause
    driving_cause=$(echo "$flat" | \
        grep -o '"drivingCause":[0-9]*' | head -1 | sed 's/"drivingCause"://')

    local heartbeat_err
    heartbeat_err=$(echo "$flat" | \
        grep -o '"heartbeatError":[^,}]*' | head -1 | sed 's/"heartbeatError"://')

    local blocking_val
    blocking_val=$(echo "$flat" | \
        grep -o '"blocking":[^,}]*' | head -1 | sed 's/"blocking"://')

    if [[ -z "$rotation" || -z "$driving_cause" ]]; then
        echo ""
        return
    fi
    printf '%s\n%s\n%s\n%s\n' "$rotation" "$driving_cause" "$heartbeat_err" "$blocking_val"
}

save_state() {
    echo "$1" > "$STATE_FILE"
}

get_cached_state() {
    [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""
}

# Check if the last drivingCause is a safety override (Rain, Wind, Ice, Safety).
# Returns 0 (blocked) or 1 (clear).
check_safety_hold() {
    local status_lines
    status_lines=$(get_full_status)
    if [[ -z "$status_lines" ]]; then
        log_verbose "Could not read live status; skipping safety check"
        return 1
    fi
    local driving_cause
    driving_cause=$(echo "$status_lines" | sed -n '2p')
    for safe_id in $SAFETY_CAUSES; do
        if [[ "$driving_cause" == "$safe_id" ]]; then
            return 0
        fi
    done
    return 1
}

send_rotation() {
    local raw_value="$1"
    log_verbose "Sending rotation raw=$raw_value to device $DEVICE_ID"
    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"action\",
            \"source\": 2,
            \"responseType\": 0,
            \"actions\": [{
                \"destinationId\": $DEVICE_ID,
                \"actionId\": $ACTION_ID,
                \"parameters\": {\"rotation\": $raw_value}
            }]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "No response from $WAREMA_HOST"
        return 1
    fi
    if ! echo "$response" | grep -q '"command":"action"'; then
        log_error "Unexpected response: $response"
        return 1
    fi
    log_verbose "Response: $response"
}

send_stop() {
    log_verbose "Sending stop to device $DEVICE_ID"
    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"action\",
            \"source\": 2,
            \"responseType\": 0,
            \"actions\": [{
                \"destinationId\": $DEVICE_ID,
                \"actionId\": $STOP_ACTION_ID,
                \"parameters\": {}
            }]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "No response from $WAREMA_HOST"
        return 1
    fi
    if ! echo "$response" | grep -q '"command":"action"'; then
        log_error "Unexpected response: $response"
        return 1
    fi
    log_verbose "Response: $response"
}

send_impulse() {
    local direction="$1"  # 0=Up(open), 1=Down(close)
    log_verbose "Sending impulse $direction to device $DEVICE_ID"
    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"action\",
            \"source\": 2,
            \"responseType\": 0,
            \"actions\": [{
                \"destinationId\": $DEVICE_ID,
                \"actionId\": $IMPULSE_ACTION_ID,
                \"parameters\": {\"impulse\": $direction}
            }]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "No response from $WAREMA_HOST"
        return 1
    fi
    if ! echo "$response" | grep -q '"command":"action"'; then
        log_error "Unexpected response: $response"
        return 1
    fi
    log_verbose "Response: $response"
}

cmd_get() {
    local rotation
    rotation=$(get_live_rotation)
    if [[ -n "$rotation" ]]; then
        local pct
        pct=$(raw_to_percentage "$rotation")
        printf "%.0f\n" "$pct"
        return
    fi
    log_verbose "Live status unavailable; using cached state"
    local cached
    cached=$(get_cached_state)
    if [[ -n "$cached" ]]; then
        echo "$cached"
    else
        log_error "No position data available (live status failed, no cache)"
        exit 1
    fi
}

cmd_status() {
    local status_lines
    status_lines=$(get_full_status)
    if [[ -z "$status_lines" ]]; then
        log_verbose "Live status unavailable; showing cached state only"
        local cached
        cached=$(get_cached_state)
        echo "position: ${cached:-unknown}% (cached)"
        echo "drivingCause: unknown (status unavailable)"
        return
    fi
    local rotation driving_cause heartbeat_err blocking pct cause_name
    rotation=$(echo "$status_lines" | sed -n '1p')
    driving_cause=$(echo "$status_lines" | sed -n '2p')
    heartbeat_err=$(echo "$status_lines" | sed -n '3p')
    blocking=$(echo "$status_lines" | sed -n '4p')
    pct=$(raw_to_percentage "$rotation")
    cause_name=$(driving_cause_name "$driving_cause")
    echo "position: $(printf '%.0f' "$pct")% (raw: $rotation)"
    echo "drivingCause: $driving_cause ($cause_name)"
    echo "heartbeatError: $heartbeat_err"
    echo "blocking: $blocking"
    save_state "$(printf '%.0f' "$pct")"
}

cmd_set() {
    local percentage="$1"
    local force="${2:-0}"

    if [[ "$force" != "1" ]] && check_safety_hold; then
        local status_lines
        status_lines=$(get_full_status)
        local driving_cause
        driving_cause=$(echo "$status_lines" | sed -n '2p')
        local cause_name
        cause_name=$(driving_cause_name "$driving_cause")
        log_error "Blocked: device is under $cause_name safety hold (drivingCause=$driving_cause). Use --force to override."
        exit 1
    fi

    local raw_value
    raw_value=$(percentage_to_raw "$percentage") || exit 1
    log_verbose "Converted $percentage% → raw $raw_value"
    if send_rotation "$raw_value"; then
        save_state "$(printf "%.0f" "$percentage")"
        log_info "Set to $percentage% (raw: $raw_value)"
    else
        exit 1
    fi
}

cmd_raw() {
    local raw_arg="$1"
    local force="${2:-0}"
    local clamped_raw="$raw_arg"
    (( clamped_raw < -127 )) && clamped_raw=-127
    (( clamped_raw > 127 )) && clamped_raw=127

    if [[ "$force" != "1" ]] && check_safety_hold; then
        local status_lines
        status_lines=$(get_full_status)
        local driving_cause
        driving_cause=$(echo "$status_lines" | sed -n '2p')
        local cause_name
        cause_name=$(driving_cause_name "$driving_cause")
        log_error "Blocked: device is under $cause_name safety hold. Use --force to override."
        exit 1
    fi

    log_verbose "Sending raw value: $clamped_raw"
    if send_rotation "$clamped_raw"; then
        local pct
        pct=$(raw_to_percentage "$clamped_raw")
        save_state "$(printf "%.0f" "$pct")"
        log_info "Raw $clamped_raw sent (~${pct}%)"
    else
        exit 1
    fi
}

get_all_devices() {
    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d '{"protocolVersion":"1.0","command":"getConfiguration","source":2}' \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "Failed to get configuration from $WAREMA_HOST"
        exit 1
    fi
    echo "WAREMA Device Configuration (host: $WAREMA_HOST)"
    echo ""
    if command -v jq >/dev/null 2>&1; then
        echo "$response" | jq .
    else
        echo "$response"
    fi
}

main() {
    local action=""
    local silent=1
    local force=0
    local raw_arg=""
    local impulse_dir=""

    load_env

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)    show_help; exit 0 ;;
            -v|--verbose) silent=0; export VERBOSE=1; export SILENT=0; shift ;;
            -s|--silent)  silent=1; export SILENT=1; shift ;;
            --force)      force=1; shift ;;
            -d|--device)  DEVICE_ID="$2"; shift 2 ;;
            -H|--host)    WAREMA_HOST="$2"; shift 2 ;;
            get|stop|devices|status) action="$1"; shift ;;
            raw)
                action="raw"
                shift
                if [[ $# -eq 0 || ! "$1" =~ ^-?[0-9]+$ ]]; then
                    log_error "'raw' requires an integer value (-127 to 127)"
                    exit 1
                fi
                raw_arg="$1"; shift
                ;;
            impulse)
                action="impulse"
                shift
                if [[ $# -eq 0 ]]; then
                    log_error "'impulse' requires up or down"
                    exit 1
                fi
                case "$1" in
                    up)   impulse_dir=0 ;;
                    down) impulse_dir=1 ;;
                    *)    log_error "impulse direction must be 'up' or 'down'"; exit 1 ;;
                esac
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Use --help for usage information" >&2
                exit 1
                ;;
            *)
                if [[ -z "$action" ]]; then
                    action="$1"
                else
                    log_error "Too many arguments"
                    exit 1
                fi
                shift
                ;;
        esac
    done

    export SILENT=${silent}

    if [[ -z "$action" ]]; then
        log_error "Action argument is required"
        echo "Use --help for usage information" >&2
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then log_error "curl is required"; exit 1; fi
    if ! command -v bc >/dev/null 2>&1; then log_error "bc is required"; exit 1; fi

    case "$action" in
        get)
            cmd_get
            ;;
        status)
            cmd_status
            ;;
        stop)
            if send_stop; then
                log_info "Stopped"
            else
                exit 1
            fi
            ;;
        impulse)
            if send_impulse "$impulse_dir"; then
                local dir_name="up"
                [[ "$impulse_dir" == "1" ]] && dir_name="down"
                log_info "Impulse $dir_name sent"
            else
                exit 1
            fi
            ;;
        devices)
            get_all_devices
            ;;
        raw)
            cmd_raw "$raw_arg" "$force"
            ;;
        *)
            cmd_set "$action" "$force"
            ;;
    esac
}

main "$@"
