#!/bin/bash

# Check if expected BIOS version and input file are provided
if [ $# -ne 2 ]; then
  echo "Usage: $0 <expected_bios_version> <input_file>"
  echo "Input file format: IP USERNAME PASSWORD"
  exit 1
fi

EXPECTED_BIOS="$1"
INPUT_FILE="$2"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file '$INPUT_FILE' not found"
  exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "Error: jq is not installed. Please install jq to parse JSON."
  exit 1
fi

# Check if parallel is installed
if ! command -v parallel &> /dev/null; then
  echo "Error: parallel is not installed. Please install GNU parallel."
  exit 1
fi

# Check ulimit -n (open file descriptors)
FILE_LIMIT=$(ulimit -n)
if [ "$FILE_LIMIT" -lt 2048 ]; then
  echo "Warning: ulimit -n is $FILE_LIMIT, which may be too low for parallel execution."
  echo "Consider increasing it with 'ulimit -n 4096' or contact your system administrator."
fi

# Function to normalize strings (extract version number, convert to lowercase)
normalize_string() {
  # Extract version number (e.g., "3.5" from "BIOS Date: 04/23/2025 Ver 3.5" or "3.5")
  echo "$1" | grep -o '[0-9.]\+$' | tr '[:upper:]' '[:lower:]'
}

# Function to process a single BMC
process_bmc() {
  BMC_IP="$1"
  USERNAME="$2"
  PASSWORD="$3"
  EXPECTED_BIOS="$4"

  # Check for empty fields
  if [ -z "$BMC_IP" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    result="Error: Invalid input (IP: $BMC_IP, USERNAME: $USERNAME)"
    echo "$result"
    return
  fi

  # Redfish API endpoint for system information
  URL="https://${BMC_IP}/redfish/v1/Systems/1"

  # Send GET request, capture response body
  response_body=$(curl --insecure --user "${USERNAME}:${PASSWORD}" --max-time 15 "$URL" 2>/dev/null)

  # Capture HTTP status code separately
  http_status=$(curl --silent --insecure --user "${USERNAME}:${PASSWORD}" --max-time 15 --output /dev/null -w "%{http_code}" "$URL" 2>/dev/null)

  # Check for connection failure (no response or invalid response)
  if [ -z "$response_body" ]; then
    result="Error: Failed to connect to BMC at $BMC_IP or no response received"
    echo "$result" >> unreachable.txt
    echo "$result"
    return
  fi

  # Check for authentication failure (HTTP 401)
  if [ "$http_status" = "401" ]; then
    result="❗ Password incorrect for $BMC_IP"
    echo "$result" >> incorrect_password.txt
    echo "$result"
    return
  fi

  # Check for other HTTP errors
  if [ "$http_status" != "200" ]; then
    result="Error: HTTP status $http_status for $BMC_IP"
    echo "$result"
    return
  fi

  # Extract BIOS version using jq, trying multiple possible fields
  bios_version=$(echo "$response_body" | jq -r '.BiosVersion // .Bios.Version // .FirmwareVersion // "Not found"')

  # Check if BIOS version was found
  if [ "$bios_version" = "Not found" ]; then
    result="Error: BIOS version not found for $BMC_IP"
    echo "$result"
    return
  fi

  # Normalize both the retrieved and expected BIOS versions for comparison
  normalized_bios_version=$(normalize_string "$bios_version")
  normalized_expected_bios=$(normalize_string "$EXPECTED_BIOS")

  # Compare normalized BIOS versions
  if [ "$normalized_bios_version" = "$normalized_expected_bios" ]; then
    result="✅ $BMC_IP: BIOS Version: $bios_version"
    echo "$result" >> correct_bios.txt
    echo "$result"
  else
    result="❌ $BMC_IP: BIOS Version: $bios_version"
    echo "$result" >> wrong_bios.txt
    echo "$result"
  fi
}

# Export functions and variables for parallel
export -f process_bmc normalize_string
export EXPECTED_BIOS

# Initialize output files
> correct_bios.txt
> wrong_bios.txt
> incorrect_password.txt
> unreachable.txt

# Process input file in parallel with immediate output
awk '!/^ *#/ && NF {print $0}' "$INPUT_FILE" | parallel --colsep ' ' --line-buffer --jobs 5 process_bmc {1} {2} {3} "$EXPECTED_BIOS"

# Notify user about output files
echo "Results saved to: correct_bios.txt, wrong_bios.txt, incorrect_password.txt, unreachable.txt"
