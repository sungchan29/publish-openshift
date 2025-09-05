#!/bin/bash

### Enable strict mode
set -euo pipefail

### Source the configuration file and validate its existence
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    echo "[ERROR] Cannot access '$config_file'. File or directory does not exist. Exiting..."
    exit 1
fi
if ! source "$config_file"; then
    echo "[ERROR] Failed to source '$config_file'. Check file syntax or permissions. Exiting..."
    exit 1
fi

### Validate required variables
validate_non_empty "CUSTOM_CONFIG_DIR" "$CUSTOM_CONFIG_DIR"
validate_non_empty "BUTANE_BU_DIR" "$BUTANE_BU_DIR"
validate_non_empty "ADDITIONAL_MANIFEST" "$ADDITIONAL_MANIFEST"

mkdir -p "$CUSTOM_CONFIG_DIR"
mkdir -p "$BUTANE_BU_DIR"
mkdir -p "$ADDITIONAL_MANIFEST"

### Execute custom files
source_dir="$(dirname "$(realpath "$0")")/abi-00-config-01-user-defined-objects"
if [[ ! -d "$source_dir" ]]; then
    echo "[ERROR] Custom files directory '$source_dir' does not exist. Exiting..."
    exit 1
fi

echo "[INFO] Executing custom files from '$source_dir'"
echo ""
for file_name in $(ls -1 "$source_dir" | sort -V); do
    user_defined_object_file="$source_dir/$file_name"

    echo -n "[INFO] Executing $user_defined_object_file"
    bash "$user_defined_object_file" 2>&1
    echo ""
done

### List directory structure
if command -v tree >/dev/null 2>&1; then
    echo "[INFO] Directory structure of '$CLUSTER_NAME':"
    tree "$CLUSTER_NAME"
else
    echo "[INFO] 'tree' command not found, listing files with ls:"
    ls -lR "$CLUSTER_NAME"
fi