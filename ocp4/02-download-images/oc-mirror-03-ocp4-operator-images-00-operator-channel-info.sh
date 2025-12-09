#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Operator Lifecycle Manager (OLM) Catalog
### ---------------------------------------------------------------------------------
### This script analyzes an OLM catalog file to provide a detailed, human-readable
### summary of its packages, channels, and versions.

### Enable strict mode for safer script execution.
set -euo pipefail

### Assign the first command-line argument (the catalog file path) to a variable.
catalog_file="$1"

### ---------------------------------------------------------------------------------
### Load Configuration and Prerequisites
### ---------------------------------------------------------------------------------
### Source the configuration script.
get_defaultchannel_for_operator() {
   local lc_channel
   lc_channel=$(cat "$catalog_file" \
        | jq -r 'select(.schema == "olm.package") | .defaultChannel')
    echo "$lc_channel"
}

### Retrieves a sorted list of all channel names defined in the catalog.
get_channels_for_operator() {
   local lc_channels
   lc_channels=$(cat "$catalog_file" \
        | jq -r 'select(.schema == "olm.channel") | .name' \
        | sort -Vr -u)
    echo "$lc_channels"
}

### Retrieves a sorted list of all bundle names (versions) for a specific channel.
get_versions_for_channel() {
    local lc_channel="$1"
    local lc_versions
    lc_versions=$(cat "$catalog_file" \
        | jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name' \
        | sort -Vr -u)
    echo "$lc_versions"
}

### Extracts the human-readable package version (e.g., "1.2.3") from a specific bundle's properties.
get_properties_version() {
    local lc_full_version="$1"
    local lc_prop_version
    lc_prop_version=$(cat "$catalog_file" \
        | jq -r --arg ver "$lc_full_version" 'select(.schema == "olm.bundle" and .name == $ver) | .properties[]? | select(.type == "olm.package") | .value.version // ""')
    echo "$lc_prop_version"
}

### Extracts the version number from a bundle name string (e.g., "operator.v1.2.3" -> "1.2.3").
get_extract_version() {
    local lc_input="$1"
    local lc_version="${lc_input#*.}"
    echo "${lc_version#v}"
}

### ---------------------------------------------------------------------------------
### Main Logic for Analysis
### ---------------------------------------------------------------------------------
### Validate that the provided catalog file exists and is readable.
if [[ ! -f "$catalog_file" ]]; then
    printf "%-8s%-80s\n" "[ERROR]" "Catalog file '$catalog_file' not found. Exiting..."
    exit 1
fi

### Get the default channel and all available channels.
default_channel=$(get_defaultchannel_for_operator)
channels=$(get_channels_for_operator)
channel_count=$(echo "$channels" | wc -l)

### Display a detailed summary of all channels and their associated bundles.
printf "%-8s%-80s\n" "[INFO]" "Total Number of Channels Found: $channel_count"
printf "%-8s%-80s\n" "[INFO]" "--- Channel Details ---"
while IFS=$'\n' read -r channel; do
    printf "%-8s%-80s\n" "[INFO]" "  Channel: $channel"
    versions=$(cat "$catalog_file" \
        | jq -r --arg chan "$channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | [.name, .skipRange // "None"] | join(" (skipRange: ") + ")"' \
        | sort -Vr -u)
    echo "$versions" | while IFS=$'\n' read -r ver; do
        full_ver=$(echo "$ver" | cut -d' ' -f1)
        prop_ver=$(get_properties_version "$full_ver")
        skiprange=$(echo "$ver" | sed "s/^[^ ]* //")
        printf "%-9s %-54s %-9s %-28s %s\n" \
               "           Name: " "$full_ver" " Version: " "$prop_ver" "$skiprange"
    done
done <<< "$channels"

### Find and display channels that have the exact same version list as the default channel.
echo ""
printf "%-8s%-80s\n" "[INFO]" "--- Channels with an Identical Version List to Default ('$default_channel') ---"
default_versions=$(get_versions_for_channel "$default_channel")
declare -A identical_channels
identical_channels=()
while IFS=$'\n' read -r channel; do
    if [[ "$channel" != "$default_channel" ]]; then
        channel_versions=$(get_versions_for_channel "$channel")
        if [[ "$channel_versions" == "$default_versions" ]]; then
            identical_channels["$channel"]=1
        fi
    fi
done <<< "$channels"

if [[ ${#identical_channels[@]} -eq 0 ]]; then
    printf "%-8s%-80s\n" "[INFO]" "  None"
else
    for chan in "${!identical_channels[@]}"; do
        printf "%-8s%-80s\n" "[INFO]" "  $chan"
    done
fi