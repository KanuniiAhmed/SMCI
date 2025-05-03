#!/bin/bash

# Script to check Secure Boot status via Redfish API on Supermicro servers
# Supports: 
# 1. File input (each line: IP USERNAME PASSWORD) with parallel execution
# 2. Arguments (IP USERNAME PASSWORD) for single server
# Marks enabled, unreachable, and auth failures with ❌
# Shows summary of total IPs tested, enabled, unreachable, password incorrect, and failed connections

# Check for required tools
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo "Error: curl and jq are required. Please install them."
    exit 1
fi

# Maximum number of parallel jobs
MAX_JOBS=10

# Curl timeout settings (in seconds)
CONNECT_TIMEOUT=5
MAX_TIME=10

# Temporary file for tracking results
RESULT_LOG="/tmp/secure_boot_results_$$.log"
touch "$RESULT_LOG" 2>/dev/null || { echo "Error: Cannot write to $RESULT_LOG"; exit 1; }

# Function to check Secure Boot for a single server
check_secure_boot() {
    local BMC_IP="$1"
    local USERNAME="$2"
    local PASSWORD="$3"
    local URI="/redfish/v1/Systems/1/Bios"
    local TEMP_JSON="/tmp/bios_settings_$$_${BMC_IP//./_}.json"
    local JQ_ERROR_LOG="/tmp/jq_error_$$_${BMC_IP//./_}.log"

    # Ensure temporary file is writable
    touch "$TEMP_JSON" 2>/dev/null || { echo "Error: Cannot write to $TEMP_JSON"; return 1; }

    # Make Redfish API call to get BIOS settings with HTTP status check and timeout
    response=$(curl -s -w "%{http_code}" -k -u "$USERNAME:$PASSWORD" \
        -H "Content-Type: application/json" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        -X GET "https://$BMC_IP$URI" -o "$TEMP_JSON")

    http_status="${response: -3}"

    # Check HTTP status code
    if [ "$http_status" -eq 401 ]; then
        echo "Password incorrect ❌ ($BMC_IP)"
        echo "password_incorrect $BMC_IP" >> "$RESULT_LOG"
        rm -f "$TEMP_JSON" "$JQ_ERROR_LOG"
        return 1
    elif [ "$http_status" -ne 200 ]; then
        echo "Secure Boot: Unreachable ❌ ($BMC_IP, HTTP status $http_status)"
        echo "Response saved to $TEMP_JSON for debugging."
        echo "unreachable $BMC_IP" >> "$RESULT_LOG"
        if [ "$http_status" -eq 000 ]; then
            echo "failed_connect $BMC_IP" >> "$RESULT_LOG"
        fi
        return 1
    fi

    # Check if response file is empty
    if [ ! -s "$TEMP_JSON" ]; then
        echo "Secure Boot: Unreachable ❌ ($BMC_IP, empty response)"
        echo "Response saved to $TEMP_JSON for debugging."
        echo "unreachable $BMC_IP" >> "$RESULT_LOG"
        echo "failed_connect $BMC_IP" >> "$RESULT_LOG"
        return 1
    fi

    # Primary check: Use grep to find SecureBootEnable
    if grep -q '"SecureBootEnable":\s*false' "$TEMP_JSON"; then
        echo "Secure Boot: Disabled ✅ ($BMC_IP)"
        rm -f "$TEMP_JSON" "$JQ_ERROR_LOG"
        return 0
    elif grep -q '"SecureBootEnable":\s*true' "$TEMP_JSON"; then
        echo "Secure Boot: Enabled ❌ ($BMC_IP)"
        echo "enabled $BMC_IP" >> "$RESULT_LOG"
        rm -f "$TEMP_JSON" "$JQ_ERROR_LOG"
        return 0
    fi

    # Secondary check: Try jq if grep fails
    if ! jq -e . "$TEMP_JSON" >/dev/null 2>"$JQ_ERROR_LOG"; then
        echo "Error: Invalid JSON response from BMC at $BMC_IP."
        echo "Response saved to $TEMP_JSON for debugging."
        echo "jq error: $(cat $JQ_ERROR_LOG)"
        rm -f "$JQ_ERROR_LOG"
        return 1
    fi

    secure_boot_status=$(jq -r '.Attributes.SecureBootEnable // "NotFound"' "$TEMP_JSON" 2>>"$JQ_ERROR_LOG")
    echo "DEBUG: Raw SecureBootEnable value from jq: $secure_boot_status ($BMC_IP)" >&2

    if [ "$secure_boot_status" = "false" ]; then
        echo "Secure Boot: Disabled ✅ ($BMC_IP)"
        rm -f "$TEMP_JSON" "$JQ_ERROR_LOG"
        return 0
    elif [ "$secure_boot_status" = "true" ]; then
        echo "Secure Boot: Enabled ❌ ($BMC_IP)"
        echo "enabled $BMC_IP" >> "$RESULT_LOG"
        rm -f "$TEMP_JSON" "$JQ_ERROR_LOG"
        return 0
    else
        echo "Error: SecureBootEnable attribute not found in BIOS settings for $BMC_IP."
        echo "Full BIOS settings saved to $TEMP_JSON for review."
        echo "jq version: $(jq --version)"
        if [ -s "$JQ_ERROR_LOG" ]; then
            echo "jq error output: $(cat $JQ_ERROR_LOG)"
        fi
        rm -f "$JQ_ERROR_LOG"
        return 1
    fi
}

# Function to process a single line from the file
process_line() {
    local ip="$1"
    local username="$2"
    local password="$3"
    # Skip empty lines or lines with incorrect number of fields
    if [ -z "$ip" ] || [ -z "$username" ] || [ -z "$password" ]; then
        echo "Warning: Skipping invalid line: '$ip $username $password'"
        return
    fi
    #echo "Checking $ip..."
    check_secure_boot "$ip" "$username" "$password"
    echo "tested $ip" >> "$RESULT_LOG"
}

# Function to print summary
print_summary() {
    local total_ips=0
    local enabled_count=0
    local unreachable_count=0
    local password_incorrect_count=0
    local failed_connect_count=0

    if [ -s "$RESULT_LOG" ]; then
        total_ips=$(grep -c "tested" "$RESULT_LOG")
        enabled_count=$(grep -c "enabled" "$RESULT_LOG")
        unreachable_count=$(grep -c "unreachable" "$RESULT_LOG")
        password_incorrect_count=$(grep -c "password_incorrect" "$RESULT_LOG")
        failed_connect_count=$(grep -c "failed_connect" "$RESULT_LOG")
    fi

    echo "Summary: Tested $total_ips IPs: $enabled_count enabled, $unreachable_count unreachable, $password_incorrect_count password incorrect, $failed_connect_count failed to connect"
    rm -f "$RESULT_LOG"
}

# Export function for background execution
export -f check_secure_boot
export -f process_line
export RESULT_LOG

# Check if first argument is a file
if [ -f "$1" ]; then
    INPUT_FILE="$1"
    echo "Reading server credentials from $INPUT_FILE (parallel execution, max $MAX_JOBS jobs)"
    job_count=0
    while IFS=' ' read -r ip username password; do
        # Skip empty lines or lines with incorrect number of fields
        if [ -z "$ip" ] || [ -z "$username" ] || [ -z "$password" ]; then
            echo "Warning: Skipping invalid line in $INPUT_FILE: '$ip $username $password'"
            continue
        fi
        # Run job in background
        process_line "$ip" "$username" "$password" &
        ((job_count++))
        # Wait if maximum jobs reached
        if [ "$job_count" -ge "$MAX_JOBS" ]; then
            wait
            job_count=0
        fi
    done < "$INPUT_FILE"
    # Wait for remaining jobs
    wait
    print_summary
elif [ "$#" -eq 3 ]; then
    echo "Checking single server: $1"
    check_secure_boot "$1" "$2" "$3"
    echo "tested $1" >> "$RESULT_LOG"
    print_summary
else
    echo "Usage:"
    echo "  $0 <INPUT_FILE> (file with 'IP USERNAME PASSWORD' per line)"
    echo "  $0 <BMC_IP> <USERNAME> <PASSWORD> (single server)"
    exit 1
fi

