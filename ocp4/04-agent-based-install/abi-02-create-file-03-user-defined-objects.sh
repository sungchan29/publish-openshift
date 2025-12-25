#!/bin/bash

### ---------------------------------------------------------------------------------
### Execute Custom User-Defined Objects
### ---------------------------------------------------------------------------------
### This script executes a series of user-defined shell scripts to generate
### custom manifests for the cluster installation.

### Enable strict mode for safer script execution.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"
if [[ ! -f "$config_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Configuration file '$config_file' not found. Exiting..."
    exit 1
fi
source "$config_file"

### ---------------------------------------------------------------------------------
### Validate Environment and Setup
### ---------------------------------------------------------------------------------
### Validate that critical environment variables from the config are set.
printf "%-8s%-80s\n" "[INFO]" "=== Validating prerequisites ==="
validate_non_empty "CUSTOM_CONFIG_DIR" "$CUSTOM_CONFIG_DIR"
validate_non_empty "BUTANE_BU_DIR" "$BUTANE_BU_DIR"
validate_non_empty "ADDITIONAL_MANIFEST" "$ADDITIONAL_MANIFEST"

### Create the necessary output directories for custom manifests.
printf "%-8s%-80s\n" "[INFO]" "=== Preparing output directories for custom manifests. ==="
mkdir -p "$CUSTOM_CONFIG_DIR"
mkdir -p "$BUTANE_BU_DIR"
mkdir -p "$ADDITIONAL_MANIFEST"

### ---------------------------------------------------------------------------------
### Execute Custom Files
### ---------------------------------------------------------------------------------
printf "%-8s%-80s\n" "[INFO]" "=== Executing user-defined scripts for custom objects ==="
### Locate the directory containing user-defined scripts to be executed.
source_dir="$(dirname "$(realpath "$0")")/abi-00-config-01-user-defined-objects"
if [[ ! -d "$source_dir" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "    The custom scripts directory '$source_dir' not found. Exiting..."
    exit 1
fi

### Create 'skip' directory for unused scripts if it doesn't exist.
mkdir -p "$source_dir/skip"

### Iterate through sorted files in the source directory and execute each one.
### [Modified] Added '-type f' to ignore directories like 'skip' and '-name "*.sh"' for safety.
for file_path in $(find "$source_dir" -mindepth 1 -maxdepth 1 -type f -name "*.sh" -print0 | sort -zV | tr '\0' '\n'); do
    printf "%-8s%-80s\n" "[INFO]" "--- $(basename "$file_path") ..."
    ### Execute the script, redirecting its output to the parent shell.
    bash "$file_path" 2>&1
done

### ---------------------------------------------------------------------------------
### Display Directory Structure
### ---------------------------------------------------------------------------------
### List the contents of the generated directories for verification.
echo ""
printf "%-8s%-80s\n" "[INFO]" "=== Verifying generated custom manifests ==="
printf "%-8s%-80s\n" "[INFO]" "--- Displaying directory structure for '$CLUSTER_NAME':"
if command -v tree >/dev/null 2>&1; then
    tree "$CLUSTER_NAME"
else
    printf "%-8s%-80s\n" "[INFO]" "    'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "$CLUSTER_NAME"
fi
echo ""