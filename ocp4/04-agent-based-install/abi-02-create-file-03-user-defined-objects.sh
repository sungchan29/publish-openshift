#!/bin/bash

### ---------------------------------------------------------------------------------
### Execute Custom User-Defined Objects
### ---------------------------------------------------------------------------------
### This script automates the execution of user-defined shell scripts to create
### custom manifests, which are later included in the installation.

### Enable strict mode to exit immediately if a command fails, an undefined variable is used, or a command in a pipeline fails.
set -euo pipefail

### ---------------------------------------------------------------------------------
### Load Configuration and Prepare Directories
### ---------------------------------------------------------------------------------
### Source the main configuration file to load all necessary variables and functions.
config_file="$(dirname "$(realpath "$0")")/abi-00-config-setup.sh"

if [[ ! -f "$config_file" ]]; then
    echo "ERROR: The configuration file '$config_file' could not be found. Exiting." >&2
    exit 1
fi
if ! source "$config_file"; then
    echo "ERROR: Failed to source '$config_file'. Please check file syntax or permissions." >&2
    exit 1
fi

### Validate that the required directory paths are set.
validate_non_empty "CUSTOM_CONFIG_DIR" "$CUSTOM_CONFIG_DIR"
validate_non_empty "BUTANE_BU_DIR" "$BUTANE_BU_DIR"
validate_non_empty "ADDITIONAL_MANIFEST" "$ADDITIONAL_MANIFEST"

### Create the necessary output directories for custom manifests.
echo "INFO: Creating output directories for custom manifests..."
mkdir -p "$CUSTOM_CONFIG_DIR"
mkdir -p "$BUTANE_BU_DIR"
mkdir -p "$ADDITIONAL_MANIFEST"
echo "INFO: Required directories created successfully."

### ---------------------------------------------------------------------------------
### Execute Custom Files
### ---------------------------------------------------------------------------------
### Locate the directory containing user-defined scripts.
source_dir="$(dirname "$(realpath "$0")")/abi-00-config-01-user-defined-objects"

if [[ ! -d "$source_dir" ]]; then
    echo "ERROR: The custom files directory '$source_dir' does not exist. No custom manifests will be created." >&2
    exit 1
fi

echo "INFO: Executing custom manifest creation scripts from '$source_dir'..."

### Iterate through sorted files in the source directory and execute each one.
for file_name in $(ls -1 "$source_dir" | sort -V); do
    user_defined_object_file="$source_dir/$file_name"
    
    echo "INFO: -> Executing script: $user_defined_object_file"
    
    ### Execute the script and redirect standard output and error to the parent shell.
    bash "$user_defined_object_file" 2>&1
    
    echo "INFO: -> Script '$file_name' execution complete."
done
echo "INFO: All custom scripts have been executed."

### ---------------------------------------------------------------------------------
### Display Directory Structure
### ---------------------------------------------------------------------------------
### List the contents of the generated directories for verification.
echo "--- Verifying generated files in the output directory..."
if command -v tree >/dev/null 2>&1; then
    echo "INFO: Directory structure of '$CLUSTER_NAME':"
    tree "$CLUSTER_NAME"
else
    echo "INFO: 'tree' command not found. Listing files with 'ls' instead:"
    ls -lR "$CLUSTER_NAME"
fi
echo "--- Script execution finished."