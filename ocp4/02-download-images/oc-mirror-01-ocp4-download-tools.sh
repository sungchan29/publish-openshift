#!/bin/bash

### ---------------------------------------------------------------------------------
### Download OpenShift Client Tools
### ---------------------------------------------------------------------------------
### This script downloads and prepares essential OpenShift client tools ('oc',
### 'oc-mirror', 'butane', 'yq') required for the disconnected installation workflow.
### It relies on 'oc-mirror-00-config-setup.sh' for configuration variables.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### 1. Load Configuration
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Loading Configuration ==="

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
CONFIG_FILE="$SCRIPT_DIR/oc-mirror-00-config-setup.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

### Source the configuration file
source "$CONFIG_FILE"
printf "%-8s%-80s\n" "[INFO]" "    Configuration loaded from: $(basename "$CONFIG_FILE")"

### ---------------------------------------------------------------------------------
### 2. Environment Validation
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Validating Environment ==="

### Check critical variables from config
if [[ -z "${WORK_DIR:-}" || -z "${TOOL_DIR:-}" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    Required variables (WORK_DIR, TOOL_DIR) are not set in config." >&2
    exit 1
fi

### Run version extraction to ensure OCP_VERSIONS is valid
printf "%-8s%-80s\n" "[INFO]" "    Verifying OpenShift Versions..."
extract_ocp_versions

if [[ ${#OCP_VERSION_ARRAY[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    No valid OCP versions found. Check 'OCP_VERSIONS' in config." >&2
    exit 1
fi

printf "%-8s%-80s\n" "[INFO]" "    Target OCP Version found: $OCP_TARGET_VERSION"
printf "%-8s%-80s\n" "[INFO]" "    Environment validation passed."

### ---------------------------------------------------------------------------------
### 3. Display Download Plan
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Download Plan ==="
printf "%-8s%-80s\n" "[INFO]" "    Tools will be downloaded to: $TOOL_DIR"

print_plan() {
    local name="$1"
    local url="$2"
    if [[ -n "$url" ]]; then
        printf "%-8s%-80s\n" "[INFO]" "    - $name"
    fi
}

print_plan "Butane Config Tool"        "$BUTANE_DOWNLOAD_URL"
print_plan "yq YAML Processor"         "$YQ_DOWNLOAD_URL"
print_plan "OpenShift Client (RHEL8)"  "${OPENSHIFT_CLIENT_RHEL8_TAR:-}"
print_plan "OpenShift Client (RHEL9)"  "${OPENSHIFT_CLIENT_RHEL9_TAR:-}"
print_plan "oc-mirror (RHEL8)"         "${OC_MIRROR_RHEL8_TAR:-}"
print_plan "oc-mirror (RHEL9)"         "${OC_MIRROR_RHEL9_TAR:-}"
print_plan "Pipelines CLI"             "${PIPELINES_CLI_DOWNLOAD_URL:-}"

### ---------------------------------------------------------------------------------
### 4. Execute Downloads
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Starting Downloads ==="

### Create Tool Directory
if [[ ! -d "$TOOL_DIR" ]]; then
    mkdir -p "$TOOL_DIR"
    printf "%-8s%-80s\n" "[INFO]" "    Created directory: $TOOL_DIR"
else
    printf "%-8s%-80s\n" "[INFO]" "    Directory exists: $TOOL_DIR"
fi

### Internal function to handle curl download logic with consistent formatting
download_file() {
    local url="$1"
    local filename
    filename=$(basename "$url")
    local target_path="$TOOL_DIR/$filename"

    if [[ -z "$url" ]]; then return; fi

    printf "%-8s%-80s\n" "[INFO]" "    > Downloading: $filename..."

    ### curl options: -f (fail), -s (silent), -L (location/redirect), -o (output)
    ### capture http_code to provide better error messages
    http_code=$(curl -sL -w "%{http_code}" -o "$target_path" "$url")

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "302" ]]; then
         printf "%-8s%-80s\n" "[INFO]" "        -> Saved to: $target_path"
    else
        printf "%-8s%-80s\n" "[ERROR]" "        -> Failed to download $filename. HTTP Code: $http_code" >&2
        ### Remove empty/error file
        rm -f "$target_path"
        exit 1
    fi
}

### Run Downloads
download_file "$BUTANE_DOWNLOAD_URL"
download_file "$YQ_DOWNLOAD_URL"

if [[ -n "${OPENSHIFT_CLIENT_RHEL8_TAR:-}" ]]; then
    download_file "${OPENSHIFT_CLIENT_DOWNLOAD_URL}/$OPENSHIFT_CLIENT_RHEL8_TAR"
fi
if [[ -n "${OPENSHIFT_CLIENT_RHEL9_TAR:-}" ]]; then
    download_file "${OPENSHIFT_CLIENT_DOWNLOAD_URL}/$OPENSHIFT_CLIENT_RHEL9_TAR"
fi
if [[ -n "${OC_MIRROR_RHEL8_TAR:-}" ]]; then
    download_file "${OC_MIRROR_DOWNLOAD_URL}/$OC_MIRROR_RHEL8_TAR"
fi
if [[ -n "${OC_MIRROR_RHEL9_TAR:-}" ]]; then
    download_file "${OC_MIRROR_DOWNLOAD_URL}/$OC_MIRROR_RHEL9_TAR"
fi
if [[ -n "${PIPELINES_CLI_DOWNLOAD_URL:-}" ]]; then
    download_file "$PIPELINES_CLI_DOWNLOAD_URL"
fi

printf "%-8s%-80s\n" "[INFO]" "    All downloads completed."

### ---------------------------------------------------------------------------------
### 5. Install oc-mirror
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Installing 'oc-mirror' Binary ==="

### Detect OS Version
printf "%-8s%-80s\n" "[INFO]" "    Detecting Host OS Version..."
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    ### Extract major version only (e.g. 8.6 -> 8, 9.2 -> 9)
    HOST_RHEL_MAJOR="${VERSION_ID%%.*}"
    printf "%-8s%-80s\n" "[INFO]" "        -> Detected RHEL Major Version: $HOST_RHEL_MAJOR"
else
    printf "%-8s%-80s\n" "[ERROR]" "    Cannot detect OS version (/etc/os-release missing)." >&2
    exit 1
fi

### Select Tarball based on RHEL version
TARGET_TAR=""
if [[ "$HOST_RHEL_MAJOR" == "8" ]]; then
    TARGET_TAR="$TOOL_DIR/$OC_MIRROR_RHEL8_TAR"
elif [[ "$HOST_RHEL_MAJOR" == "9" ]]; then
    TARGET_TAR="$TOOL_DIR/$OC_MIRROR_RHEL9_TAR"
else
    printf "%-8s%-80s\n" "[ERROR]" "    Unsupported RHEL version: $HOST_RHEL_MAJOR (Only 8 or 9 supported)." >&2
    exit 1
fi

### Extract Logic
if [[ -f "$TARGET_TAR" ]]; then
    printf "%-8s%-80s\n" "[INFO]" "    Extracting $(basename "$TARGET_TAR")..."

    ### Remove existing binary to ensure clean extraction
    rm -f ./oc-mirror

    ### Extract to current directory
    if tar xf "$TARGET_TAR" -C "$PWD" oc-mirror; then
        chmod +x ./oc-mirror
        printf "%-8s%-80s\n" "[INFO]" "        -> Extracted to: ./oc-mirror"

        ### Verify
        printf "%-8s%-80s\n" "[INFO]" "    oc-mirror is ready. Checking version..."
        ./oc-mirror --v2 version --output=yaml
        ./oc-mirror --v2 --version
    else
        printf "%-8s%-80s\n" "[ERROR]" "    Failed to extract tarball." >&2
        exit 1
    fi
else
    printf "%-8s%-80s\n" "[ERROR]" "    Target tarball not found: $TARGET_TAR" >&2
    exit 1
fi

### ---------------------------------------------------------------------------------
### 6. Install yq
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Installing 'yq' Binary ==="

### Determine source filename dynamically from URL
YQ_SOURCE_NAME=$(basename "$YQ_DOWNLOAD_URL")
YQ_SOURCE_PATH="$TOOL_DIR/$YQ_SOURCE_NAME"
YQ_TARGET_PATH="$TOOL_DIR/yq"

### Check if source file exists (First run)
if [[ -f "$YQ_SOURCE_PATH" ]]; then
    mv "$YQ_SOURCE_PATH" "$YQ_TARGET_PATH"
    printf "%-8s%-80s\n" "[INFO]" "    Renamed '$YQ_SOURCE_NAME' to 'yq'."
elif [[ ! -f "$YQ_TARGET_PATH" ]]; then
    ### Error if neither source nor target exists
    printf "%-8s%-80s\n" "[ERROR]" "    yq binary not found at '$YQ_SOURCE_PATH'. Download failed?" >&2
fi

### Configure permissions and copy to working directory
if [[ -f "$YQ_TARGET_PATH" ]]; then
    chmod +x "$YQ_TARGET_PATH"

    ### Copy to current directory for easy access
    cp -f "$YQ_TARGET_PATH" ./yq

    printf "%-8s%-80s\n" "[INFO]" "        -> Copied to current directory (yq)."

    ### Verify functionality
    YQ_VERSION_OUT=$(./yq --version 2>&1)
    printf "%-8s%-80s\n" "[INFO]" "    yq is ready. Version: $YQ_VERSION_OUT"
else
    printf "%-8s%-80s\n" "[ERROR]" "    Failed to install yq." >&2
fi

### ---------------------------------------------------------------------------------
### 7. Summary
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Setup Complete ==="
printf "%-8s%-80s\n" "[INFO]" "    Tool Directory ($TOOL_DIR) contents:"
ls -lh "$TOOL_DIR"  | grep -v "^total" || true
echo ""