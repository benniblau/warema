#!/bin/bash

# WAREMA Slat Control Shell Script
# Sets slat device percentage using direct API calls
# Usage: ./warema_set_percent.sh <percentage>

set -euo pipefail

# Configuration with defaults (can be overridden by .env file)
WAREMA_HOST="${WAREMA_HOST:-10.10.1.229}"
DEVICE_ID="${DEVICE_ID:-57789}"        # Lamaxa wenden device ID
ACTION_ID="${ACTION_ID:-6}"            # SlatRotate action ID
STOP_ACTION_ID="${STOP_ACTION_ID:-16}" # ManualCommand Stop action ID
TIMEOUT="${TIMEOUT:-10}"


# Help function
show_help() {
    cat << EOF
WAREMA Slat Control Script

Usage: $0 <percentage|get|stop|devices> [options]

Arguments:
  percentage          Percentage value (0-100) to set slat position
                     0 = fully closed, 100 = fully open
  get                 Get current percentage (returns integer only)
  stop                Stop current rotation/movement
  devices             List all registered devices with full details

Options:
  -h, --help         Show this help message
  -v, --verbose      Enable verbose output (ignored in get mode)
  -d, --device ID    Device ID (default: $DEVICE_ID)
  -H, --host HOST    WAREMA host (default: $WAREMA_HOST)
  -s, --silent       Silent mode - no output (default for set operations)

Examples:
  $0 50              # Set slats to 50% open (silent)
  $0 get             # Get current percentage (returns integer only)
  $0 stop            # Stop current rotation/movement
  $0 devices         # List all devices
  $0 75 --verbose    # Set to 75% with verbose output

Conversion:
  0% = fully closed (raw: -45)
  50% = half open (raw: 22)
  100% = fully open (raw: 90)
EOF
}

# Logging functions
log_info() {
    if [[ "${SILENT:-1}" != "1" ]]; then
        echo "INFO: $*" >&2
    fi
}

log_error() {
    if [[ "${SILENT:-1}" != "1" ]]; then
        echo "ERROR: $*" >&2
    fi
}

log_verbose() {
    if [[ "${VERBOSE:-0}" == "1" && "${SILENT:-1}" != "1" ]]; then
        echo "VERBOSE: $*" >&2
    fi
}

# Load configuration from .env file
load_env() {
    local env_file="${1:-.env}"

    if [[ -f "$env_file" ]]; then
        log_verbose "Loading configuration from $env_file"

        # Read .env file and export variables
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ $key =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue

            # Remove leading/trailing whitespace and quotes
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs | sed 's/^["'\'']//' | sed 's/["'\'']$//')

            # Export the variable
            if [[ -n "$key" && -n "$value" ]]; then
                export "$key"="$value"
                log_verbose "Loaded: $key=$value"
            fi
        done < "$env_file"

    else
        log_verbose "No .env file found, using default values"
    fi
}

# Convert percentage to raw WAREMA value
percentage_to_raw() {
    local percentage="$1"

    # Validate input (allow integers and decimals, including negative numbers for clamping)
    if [[ ! "$percentage" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Invalid percentage: $percentage (must be a number)"
        return 1
    fi

    # Clamp to valid range (0-100%)
    if (( $(echo "$percentage < 0" | bc -l) )); then
        percentage=0
    elif (( $(echo "$percentage > 100" | bc -l) )); then
        percentage=100
    fi

    # Convert: raw_value = (percentage × 1.35) - 45
    # This gives us the range: 0% -> -45, 100% -> 90 (total range of 135 units)
    local raw_value
    raw_value=$(echo "scale=2; ($percentage * 1.35) - 45" | bc -l)

    # Round to nearest integer
    raw_value=$(printf "%.0f" "$raw_value")

    # Ensure we stay within WAREMA device limits (-127 to 127)
    if (( raw_value < -127 )); then
        raw_value=-127
    elif (( raw_value > 127 )); then
        raw_value=127
    fi

    echo "$raw_value"
}

# Convert raw value back to percentage for verification
raw_to_percentage() {
    local raw_value="$1"

    # Validate input (should be integer)
    if [[ ! "$raw_value" =~ ^-?[0-9]+$ ]]; then
        log_error "Invalid raw value: $raw_value"
        return 1
    fi

    # Clamp to valid raw range (-127 to 127)
    if (( raw_value < -127 )); then
        raw_value=-127
    elif (( raw_value > 127 )); then
        raw_value=127
    fi

    # Convert: percentage = (raw_value + 45) × (100/135)
    # This gives us: -45 -> 0%, 90 -> 100%
    local percentage
    percentage=$(echo "scale=10; ($raw_value + 45) * (100.0 / 135.0)" | bc -l)
    # Round to 1 decimal place for display
    percentage=$(printf "%.1f" "$percentage")

    # Clamp result to valid percentage range (0-100%)
    if (( $(echo "$percentage < 0" | bc -l) )); then
        percentage="0.0"
    elif (( $(echo "$percentage > 100" | bc -l) )); then
        percentage="100.0"
    fi

    echo "$percentage"
}

# Test connection to WAREMA host
test_connection() {
    log_verbose "Testing connection to $WAREMA_HOST"

    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d '{
            "protocolVersion": "1.0",
            "command": "ping",
            "source": 2
        }' \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "Failed to connect to WAREMA host $WAREMA_HOST"
        return 1
    fi

    # Check if response contains success status
    if echo "$response" | grep -q '"status":0'; then
        log_verbose "Connection successful"
        return 0
    else
        log_error "WAREMA host responded with error: $response"
        return 1
    fi
}

# Get current device status
get_device_status() {
    log_verbose "Getting current device status"

    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"getStatus\",
            \"source\": 2,
            \"destinations\": [$DEVICE_ID]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "Failed to get device status"
        return 1
    fi

    log_verbose "Device status response: $response"
    echo "$response"
}

# Set device rotation
set_rotation() {
    local raw_value="$1"

    log_verbose "Setting device rotation to raw value: $raw_value"

    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"action\",
            \"source\": 2,
            \"responseType\": 1,
            \"actions\": [{
                \"destinationId\": $DEVICE_ID,
                \"actionId\": $ACTION_ID,
                \"parameters\": {
                    \"rotation\": $raw_value
                }
            }]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "Failed to set device rotation"
        return 1
    fi

    log_verbose "Rotation response: $response"

    # Check for success
    if echo "$response" | grep -q '"command":"action"'; then
        return 0
    else
        log_error "Device rotation failed: $response"
        return 1
    fi
}

# Stop device rotation/movement
stop_rotation() {
    log_verbose "Stopping device rotation/movement"

    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"action\",
            \"source\": 2,
            \"responseType\": 1,
            \"actions\": [{
                \"destinationId\": $DEVICE_ID,
                \"actionId\": $STOP_ACTION_ID,
                \"parameters\": {}
            }]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]]; then
        log_error "Failed to stop device rotation"
        return 1
    fi

    log_verbose "Stop response: $response"

    # Check for success
    if echo "$response" | grep -q '"command":"action"'; then
        return 0
    else
        log_error "Device stop failed: $response"
        return 1
    fi
}

# Extract current rotation from status response
extract_current_rotation() {
    local status_response="$1"

    # Extract rotation value using grep and sed
    local rotation
    rotation=$(echo "$status_response" | \
        grep -o '"actionId":'$ACTION_ID'[^}]*"rotation":[^,}]*' | \
        sed 's/.*"rotation":\s*\([^,}]*\).*/\1/' | \
        head -1)

    if [[ -n "$rotation" && "$rotation" =~ ^-?[0-9]+$ ]]; then
        echo "$rotation"
    else
        echo "unknown"
    fi
}

# Get current percentage (for get command)
get_current_percentage() {
    # Test connection silently
    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d '{
            "protocolVersion": "1.0",
            "command": "ping",
            "source": 2
        }' \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$response" ]] || ! echo "$response" | grep -q '"status":0'; then
        exit 1
    fi

    # Get device status
    local status_response
    status_response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d "{
            \"protocolVersion\": \"1.0\",
            \"command\": \"getStatus\",
            \"source\": 2,
            \"destinations\": [$DEVICE_ID]
        }" \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$status_response" ]]; then
        exit 1
    fi

    # Extract current rotation
    local current_raw
    current_raw=$(extract_current_rotation "$status_response")

    if [[ "$current_raw" == "unknown" ]]; then
        exit 1
    fi

    # Convert to percentage and round to integer
    local percentage
    percentage=$(raw_to_percentage "$current_raw")

    # Round to nearest integer
    local rounded_percentage
    rounded_percentage=$(printf "%.0f" "$percentage")

    echo "$rounded_percentage"
}



# Get all registered devices with simple information
get_all_devices() {
    log_verbose "Retrieving all registered devices"

    # Test connection first
    local ping_response
    ping_response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d '{
            "protocolVersion": "1.0",
            "command": "ping",
            "source": 2
        }' \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$ping_response" ]] || ! echo "$ping_response" | grep -q '"status":0'; then
        if [[ "${SILENT:-1}" != "1" ]]; then
            echo "ERROR: Failed to connect to WAREMA host $WAREMA_HOST" >&2
        fi
        exit 1
    fi

    # Get system configuration
    local config_response
    config_response=$(curl -s --max-time "$TIMEOUT" \
        -H "Content-Type: application/json" \
        -d '{
            "protocolVersion": "1.0",
            "command": "getConfiguration",
            "source": 2
        }' \
        "http://$WAREMA_HOST/commonCommand" 2>/dev/null || echo "")

    if [[ -z "$config_response" ]]; then
        if [[ "${SILENT:-1}" != "1" ]]; then
            echo "ERROR: Failed to get system configuration" >&2
        fi
        exit 1
    fi

    log_verbose "System configuration retrieved"

    # Simple output - just show the raw JSON response
    echo "WAREMA Device Configuration:"
    echo "Host: $WAREMA_HOST"
    echo ""
    echo "$config_response"
}


# Main function
main() {
    local action=""
    local verbose=0
    local silent=1  # Silent by default

    # Load environment configuration
    load_env

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                verbose=1
                silent=0
                export VERBOSE=1
                export SILENT=0
                shift
                ;;
            -s|--silent)
                silent=1
                export SILENT=1
                shift
                ;;
            -d|--device)
                DEVICE_ID="$2"
                shift 2
                ;;
            -H|--host)
                WAREMA_HOST="$2"
                shift 2
                ;;
            get)
                action="get"
                shift
                ;;
            stop)
                action="stop"
                shift
                ;;
            devices)
                action="devices"
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
                    echo "Use --help for usage information" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Set silent mode by default
    export SILENT=${silent}

    # Check if action is provided
    if [[ -z "$action" ]]; then
        log_error "Action argument is required (percentage or 'get')"
        echo "Use --help for usage information" >&2
        exit 1
    fi

    # Handle get command
    if [[ "$action" == "get" ]]; then
        get_current_percentage
        exit 0
    fi

    # Handle stop command
    if [[ "$action" == "stop" ]]; then
        # Test connection first
        if ! test_connection; then
            exit 1
        fi

        if stop_rotation; then
            log_info "✓ Device rotation stopped successfully"
        else
            exit 1
        fi
        exit 0
    fi

    # Handle devices command
    if [[ "$action" == "devices" ]]; then
        get_all_devices
        exit 0
    fi

    # For set operations, action should be a percentage
    local percentage="$action"

    # Check dependencies
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required but not installed"
        exit 1
    fi

    if ! command -v bc >/dev/null 2>&1; then
        log_error "bc is required but not installed"
        exit 1
    fi

    log_info "Setting device $DEVICE_ID to $percentage% on host $WAREMA_HOST"

    # Test connection
    if ! test_connection; then
        exit 1
    fi

    # Convert percentage to raw value
    local raw_value
    raw_value=$(percentage_to_raw "$percentage")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    log_verbose "Converted $percentage% to raw value: $raw_value"

    # Get current status before change
    if [[ "$verbose" == "1" ]]; then
        local current_status
        current_status=$(get_device_status)
        if [[ $? -eq 0 ]]; then
            local current_raw
            current_raw=$(extract_current_rotation "$current_status")
            if [[ "$current_raw" != "unknown" ]]; then
                local current_percentage
                current_percentage=$(raw_to_percentage "$current_raw")
                log_info "Current position: $current_percentage% (raw: $current_raw)"
            fi
        fi
    fi

    # Set the rotation
    if ! set_rotation "$raw_value"; then
        exit 1
    fi

    log_info "✓ Rotation command sent successfully"

    # In silent mode, we're done. In verbose mode, check final status
    if [[ "${VERBOSE:-0}" == "1" ]]; then
        # Wait a moment for device to respond
        sleep 2

        # Get updated status
        log_verbose "Checking updated device status"
        local final_status
        final_status=$(get_device_status)
        if [[ $? -eq 0 ]]; then
            local final_raw
            final_raw=$(extract_current_rotation "$final_status")
            if [[ "$final_raw" != "unknown" ]]; then
                local final_percentage
                final_percentage=$(raw_to_percentage "$final_raw")
                log_info "✓ Device updated to: $final_percentage% (raw: $final_raw)"

                # Check if we got close to the requested value
                local diff
                diff=$(echo "scale=1; $final_percentage - $percentage" | bc -l)
                if (( $(echo "${diff#-} > 5" | bc -l) )); then
                    log_error "Warning: Large difference between requested ($percentage%) and actual ($final_percentage%)"
                fi
            else
                log_info "✓ Command completed (status check failed)"
            fi
        else
            log_info "✓ Command completed (unable to verify final status)"
        fi
    fi
}

# Run main function with all arguments
main "$@"