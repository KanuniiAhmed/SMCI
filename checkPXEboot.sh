#!/bin/bash

# Function to display usage
usage() {
    echo "Usage: $0 <credential_file>"
    echo "   or: $0 <bmc_ip> <bmc_user> <bmc_pass>"
    echo "Credential file format: IP username password (one per line)"
    echo "Checks boot order (PXE first, HDD second), sets correct order if wrong, performs graceful reboot, and rechecks failed IPs after 3 minutes (except query failures)."
    exit 1
}

# Cleanup function to remove temporary files and close descriptors
cleanup() {
    [ -f "$retry_list" ] && rm -f "$retry_list"
    [ -n "$temp_retry" ] && [ -f "$temp_retry" ] && rm -f "$temp_retry"
    [ -n "$temp_input" ] && [ -f "$temp_input" ] && rm -f "$temp_input"
    exec 3>&-
    exec 4>&-
}

# Trap signals to ensure cleanup
trap cleanup EXIT INT TERM

# Check number of arguments
if [ $# -ne 1 ] && [ $# -ne 3 ]; then
    usage
fi

# Check if curl and jq are installed
if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install curl."
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install jq."
    exit 1
fi

# Create log directory with timestamp
LOG_DIR="logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR" || { echo "Error: Failed to create log directory $LOG_DIR"; exit 1; }

# Maximum number of parallel tasks
MAX_PARALLEL=5
# Maximum retry attempts for failed boot order
MAX_RETRIES=2
# Delay before retrying failed boot order checks (seconds)
RETRY_DELAY=180
# Batch size for processing IPs
BATCH_SIZE=100

# Function to check and set boot order for a single BMC
check_and_set_boot_order() {
    local bmc_ip="$1"
    local bmc_user="$2"
    local bmc_pass="$3"
    local retry_list="$4"
    local attempt="$5"
    local log_file="${LOG_DIR}/output_${bmc_ip}.log"
    local success_emoji="✅"
    local failure_emoji="❌"

    # Redirect all output to log file with a dedicated file descriptor
    exec 4>>"$log_file"
    {
        if [ "$attempt" -gt 1 ]; then
            echo "Retry attempt $((attempt - 1)) for BMC IP: $bmc_ip"
        else
            echo "Checking boot order for BMC IP: $bmc_ip"
        fi

        # Redfish API endpoints
        system_endpoint="https://${bmc_ip}/redfish/v1/Systems/1"
        boot_endpoint="${system_endpoint}/Oem/Supermicro/FixedBootOrder"
        reset_endpoint="${system_endpoint}/Actions/ComputerSystem.Reset"

        # Query current boot order
        echo "Querying current boot order..."
        current_boot=$(curl -s -k -u "${bmc_user}:${bmc_pass}" \
            -H "Content-Type: application/json" \
            -X GET \
            --max-time 10 \
            "${boot_endpoint}")

        # Check for errors in GET request
        if echo "$current_boot" | grep -q "error" || [ -z "$current_boot" ]; then
            echo "Error: Failed to query boot order."
            echo "$bmc_ip: $failure_emoji (Failed to query)" >&3
            exec 4>&-
            return 1
        fi

        # Extract FixedBootOrder array
        boot_order=$(echo "$current_boot" | jq -r '.FixedBootOrder[]' 2>/dev/null)

        # Check if boot order is empty
        if [ -z "$boot_order" ]; then
            echo "Error: No boot order entries found."
            echo "$bmc_ip: $failure_emoji (No boot entries)" >&3
            [ -n "$retry_list" ] && echo "$bmc_ip $bmc_user $bmc_pass $attempt" >> "$retry_list"
            exec 4>&-
            return 1
        fi

        # Convert boot order to an array
        readarray -t boot_array <<< "$boot_order"

        # Check if PXE is first
        first_entry="${boot_array[0]}"
        if [[ "$first_entry" != "UEFI Network:"* ]]; then
            echo "Boot order incorrect: First entry is '$first_entry', expected UEFI Network."
            incorrect_boot=true
        else
            # Check second entry if it exists and should be HDD
            if [ ${#boot_array[@]} -ge 2 ]; then
                second_entry="${boot_array[1]}"
                if [[ "$second_entry" != "UEFI Hard Disk" && "$second_entry" != "UEFI Hard Disk:"* ]]; then
                    echo "Boot order incorrect: Second entry is '$second_entry', expected UEFI Hard Disk or UEFI Hard Disk:<name>."
                    incorrect_boot=true
                else
                    incorrect_boot=false
                fi
            else
                echo "Warning: Only one boot entry (PXE) found, no HDD entry."
                incorrect_boot=true
            fi
        fi

        if [ "$incorrect_boot" = false ]; then
            echo "Boot order correct: PXE first, HDD second."
            echo "$bmc_ip: $success_emoji (Correct)" >&3
            exec 4>&-
            return 0
        fi

        # If boot order is incorrect, set the correct boot order
        echo "Boot order incorrect, setting to PXE then HDD..."

        # Extract PXE and HDD entries
        pxe_entry=$(echo "$current_boot" | jq -r '.FixedBootOrder[] | select(. | startswith("UEFI Network:"))' 2>/dev/null)
        hdd_entry=$(echo "$current_boot" | jq -r '.FixedBootOrder[] | select(. == "UEFI Hard Disk" or startswith("UEFI Hard Disk:"))' 2>/dev/null)

        # Check if PXE entry exists
        if [ -z "$pxe_entry" ]; then
            echo "Error: No PXE-capable device found in FixedBootOrder."
            echo "Please check BIOS settings to enable PXE booting."
            echo "$bmc_ip: $failure_emoji (No PXE device)" >&3
            [ -n "$retry_list" ] && echo "$bmc_ip $bmc_user $bmc_pass $attempt" >> "$retry_list"
            exec 4>&-
            return 1
        fi

        # Warn if no HDD entry
        if [ -z "$hdd_entry" ]; then
            echo "Warning: No UEFI Hard Disk entry found. Proceeding with PXE only."
        fi

        # Get other entries excluding PXE and HDD
        other_entries=$(echo "$current_boot" | jq -r --arg pxe "$pxe_entry" --arg hdd "$hdd_entry" \
            '.FixedBootOrder[] | select(. != $pxe and . != $hdd)' 2>/dev/null | jq -R . | jq -s .)

        # Construct new FixedBootOrder array
        fixed_boot_order=$(jq -n \
            --arg pxe "$pxe_entry" \
            --arg hdd "$hdd_entry" \
            --argjson others "$other_entries" \
            '[ $pxe ] + (if $hdd != "" then [$hdd] else [] end) + $others')

        # Construct boot order payload
        boot_payload=$(jq -n \
            --argjson fixed "$fixed_boot_order" \
            '{
                "FixedBootOrder": $fixed
            }')

        # Set boot order
        echo "Setting persistent boot order to PXE then HDD..."
        boot_response=$(curl -s -k -u "${bmc_user}:${bmc_pass}" \
            -H "Content-Type: application/json" \
            -X PATCH \
            -d "$boot_payload" \
            --max-time 10 \
            "${boot_endpoint}")

        # Check if the boot setting was successful
        if echo "$boot_response" | grep -q "error" || [ -z "$boot_response" ]; then
            echo "Error: Failed to set persistent boot order."
            echo "$bmc_ip: $failure_emoji (Failed to set boot order)" >&3
            [ -n "$retry_list" ] && echo "$bmc_ip $bmc_user $bmc_pass $attempt" >> "$retry_list"
            exec 4>&-
            return 1
        fi

        echo "Success: Persistent boot order set to PXE then HDD."

        # Reboot the server gracefully
        reset_payload='{
            "ResetType": "GracefulRestart"
        }'

        echo "Initiating graceful server reboot..."
        reset_response=$(curl -s -k -u "${bmc_user}:${bmc_pass}" \
            -H "Content-Type: application/json" \
            -X POST \
            -d "${reset_payload}" \
            --max-time 10 \
            "${reset_endpoint}")

        # Check if the reboot request was successful
        if echo "$reset_response" | grep -q "error" || [ -z "$reset_response" ]; then
            echo "Error: Failed to initiate graceful reboot."
            echo "$bmc_ip: $failure_emoji (Failed to reboot)" >&3
            [ -n "$retry_list" ] && echo "$bmc_ip $bmc_user $bmc_pass $attempt" >> "$retry_list"
            exec 4>&-
            return 1
        fi

        echo "Success: Graceful server reboot initiated. BIOS changes will take effect."

        # Schedule for recheck
        echo "Scheduling recheck after $RETRY_DELAY seconds."
        [ -n "$retry_list" ] && echo "$bmc_ip $bmc_user $bmc_pass $attempt" >> "$retry_list"
        echo "$bmc_ip: $failure_emoji (Incorrect, set, gracefully rebooted, scheduled for recheck)" >&3
        exec 4>&-
        return 1

    } >&4 2>&1
    exec 4>&-
}

# Export function for parallel execution
export -f check_and_set_boot_order

# File descriptor 3 for console output
exec 3>&1

# Handle single BMC case
if [ $# -eq 3 ]; then
    bmc_ip="$1"
    bmc_user="$2"
    bmc_pass="$3"
    retry_list=$(mktemp)
    attempt=1

    while [ $attempt -le $((MAX_RETRIES + 1)) ]; do
        check_and_set_boot_order "$bmc_ip" "$bmc_user" "$bmc_pass" "$retry_list" "$attempt"
        if [ $? -eq 0 ]; then
            break
        fi
        if [ -s "$retry_list" ] && [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Waiting $RETRY_DELAY seconds before retry attempt $attempt/$MAX_RETRIES..." >&3
            sleep "$RETRY_DELAY"
            echo "Processing retry attempt $attempt/$MAX_RETRIES..." >&3
            temp_retry=$(mktemp)
            cp "$retry_list" "$temp_retry" || { echo "Error: Failed to copy retry list" >&3; exit 1; }
            > "$retry_list"
            while IFS=' ' read -r ip user pass att; do
                check_and_set_boot_order "$ip" "$user" "$pass" "$retry_list" "$((att + 1))"
            done < "$temp_retry"
            rm "$temp_retry"
        fi
        ((attempt++))
    done

    rm "$retry_list"
    exec 3>&-
    echo "Boot order check, set, and graceful reboot complete for $bmc_ip. Check ${LOG_DIR}/output_${bmc_ip}.log for detailed logs."
    exit 0
fi

# Handle credential file case
cred_file="$1"
if [ ! -f "$cred_file" ]; then
    echo "Error: Credential file '$cred_file' not found."
    exit 1
fi

# Temporary file for retry list
retry_list=$(mktemp)

# Function to process a batch of BMCs
process_bmc_batch() {
    local input_file="$1"
    local attempt="$2"
    local temp_retry_list=$(mktemp)
    local task_count=0
    local batch_count=0

    while IFS=' ' read -r bmc_ip bmc_user bmc_pass retry_attempt; do
        # Skip empty lines or invalid entries
        if [ -z "$bmc_ip" ] || [ -z "$bmc_user" ] || [ -z "$bmc_pass" ]; then
            echo "Skipping invalid line: $bmc_ip $bmc_user $bmc_pass" >&3
            continue
        fi
        # Use attempt from file if provided, else use function argument
        local effective_attempt=${retry_attempt:-$attempt}

        # Run task in background
        check_and_set_boot_order "$bmc_ip" "$bmc_user" "$bmc_pass" "$temp_retry_list" "$effective_attempt" &

        # Increment task counter
        ((task_count++))
        ((batch_count++))

        # Wait if maximum parallel tasks reached
        if [ "$task_count" -ge "$MAX_PARALLEL" ]; then
            wait
            task_count=0
        fi

        # Wait and reset batch if batch size reached
        if [ "$batch_count" -ge "$BATCH_SIZE" ]; then
            wait
            task_count=0
            batch_count=0
            echo "Completed batch of $BATCH_SIZE IPs, continuing..." >&3
        fi
    done < "$input_file"

    # Wait for remaining tasks
    wait

    # Move temp retry list to main retry list
    mv "$temp_retry_list" "$retry_list" || { echo "Error: Failed to move retry list" >&3; exit 1; }
}

# Function to process all BMCs with batching
process_bmc_list() {
    local input_file="$1"
    local attempt="$2"
    process_bmc_batch "$input_file" "$attempt"
}

# Initial processing
process_bmc_list "$cred_file" 1

# Retry loop for failed boot order settings
retry_count=1
while [ -s "$retry_list" ] && [ "$retry_count" -le "$MAX_RETRIES" ]; do
    echo "Waiting $RETRY_DELAY seconds before retry attempt $retry_count/$MAX_RETRIES..." >&3
    sleep "$RETRY_DELAY"
    echo "Processing retry list (attempt $retry_count/$MAX_RETRIES)..." >&3
    temp_input=$(mktemp)
    cp "$retry_list" "$temp_input" || { echo "Error: Failed to copy retry list" >&3; exit 1; }
    > "$retry_list"
    process_bmc_list "$temp_input" $((retry_count + 1))
    rm "$temp_input"
    ((retry_count++))
done

# Clean up retry list
rm "$retry_list"

# Close file descriptor
exec 3>&-

echo "Boot order check, set, and graceful reboot complete. Check ${LOG_DIR}/output_<IP>.log files for detailed logs."
exit 0
