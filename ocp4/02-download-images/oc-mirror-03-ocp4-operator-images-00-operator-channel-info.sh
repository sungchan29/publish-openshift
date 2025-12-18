#!/bin/bash

### ---------------------------------------------------------------------------------
### Generate Operator Lifecycle Manager (OLM) Catalog Analysis
### ---------------------------------------------------------------------------------
### This script analyzes an OLM catalog file to provide a detailed, human-readable
### summary of its packages, channels, and versions.
### It is primarily called by the 'gen-imageset-config' script.

### Enable strict mode for safer script execution.
set -euo pipefail

### Assign the first command-line argument (the catalog file path) to a variable.
catalog_file="$1"

### ---------------------------------------------------------------------------------
### Helper Functions (Unified jq/yq wrapper)
### ---------------------------------------------------------------------------------

### Retrieves the default channel.
get_defaultchannel_for_operator() {
    local f="$catalog_file"
    if [[ "$f" =~ \.ya?ml$ ]]; then
        yq -r 'select(.schema == "olm.package") | .defaultChannel // ""' "$f" 2>/dev/null || echo ""
    else
        jq -r 'select(.schema == "olm.package") | .defaultChannel // ""' "$f" 2>/dev/null || echo ""
    fi
}

### Retrieves a sorted list of all channel names.
### Filters out nulls, empty strings, and YAML document separators (---).
get_channels_for_operator() {
    local f="$catalog_file"
    if [[ "$f" =~ \.ya?ml$ ]]; then
        yq -r 'select(.schema == "olm.channel" and .name != null) | .name' "$f" 2>/dev/null | grep -v "^---$" | sort -Vr -u || echo ""
    else
        jq -r 'select(.schema == "olm.channel") | .name // ""' "$f" 2>/dev/null | sort -Vr -u || echo ""
    fi
}

### Retrieves a sorted list of all bundle names (versions) for a specific channel.
### Returns raw data in format: "BUNDLE_NAME|SKIP_RANGE" to be parsed by bash.
get_raw_entries_for_channel() {
    local lc_channel="$1"
    local f="$catalog_file"

    if [[ "$f" =~ \.ya?ml$ ]]; then
        ### yq: Select entries with names, output as "name|skipRange"
        yq -r "select(.schema == \"olm.channel\" and .name == \"$lc_channel\") | .entries[] | select(.name) | .name + \"|\" + (.skipRange // \"None\")" "$f" 2>/dev/null | sort -Vr -u
    else
        ### jq: Same logic
        jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | select(.name) | .name + "|" + (.skipRange // "None")' "$f" 2>/dev/null | sort -Vr -u
    fi
}

### Extracts the human-readable package version (e.g., "1.2.3") from properties.
get_properties_version() {
    local lc_full_version="$1"
    local f="$catalog_file"

    if [[ "$f" =~ \.ya?ml$ ]]; then
         yq -r "select(.schema == \"olm.bundle\" and .name == \"$lc_full_version\") | .properties[]? | select(.type == \"olm.package\") | .value.version // \"\"" "$f" 2>/dev/null | head -n 1
    else
         jq -r --arg ver "$lc_full_version" 'select(.schema == "olm.bundle" and .name == $ver) | .properties[]? | select(.type == "olm.package") | .value.version // ""' "$f" 2>/dev/null | head -n 1
    fi
}

### ---------------------------------------------------------------------------------
### Main Logic for Analysis
### ---------------------------------------------------------------------------------

### Validate that the provided catalog file exists and is readable.
if [[ ! -f "$catalog_file" ]]; then
    echo "[ERROR] Catalog file '$catalog_file' not found."
    exit 1
fi

### Get the default channel and all available channels.
default_channel=$(get_defaultchannel_for_operator)
channels=$(get_channels_for_operator)
channel_count=$(echo "$channels" | grep -c . || true)

### Display a detailed summary.
echo "Total Number of Channels Found: $channel_count"
echo "--- Channel Details ---"

while IFS=$'\n' read -r channel; do
    ### Strict filtering for empty or separator channels
    if [[ -z "$channel" || "$channel" == "---" ]]; then continue; fi

    echo "  Channel: $channel"

    ### Process versions using raw data format (Name|SkipRange) to avoid parsing errors
    raw_entries=$(get_raw_entries_for_channel "$channel")

    if [[ -z "$raw_entries" ]]; then
        echo "           (No versions found)"
        continue
    fi

    echo "$raw_entries" | while IFS='|' read -r full_ver skiprange; do
        if [[ -z "$full_ver" ]]; then continue; fi

        prop_ver=$(get_properties_version "$full_ver")

        ### Formatting skipRange for display
        display_skip=""
        if [[ "$skiprange" != "None" ]]; then
            display_skip="(skipRange: $skiprange)"
        fi

        ### Pretty print details using printf for alignment
        printf "%-9s %-54s %-9s %-20s %s\n" \
               "           Name: " "$full_ver" " Version: " "$prop_ver" "$display_skip"
    done
done <<< "$channels"

### Find channels identical to default.
echo ""
echo "--- Channels Identical to Default ('$default_channel') ---"

### Get raw entries for comparison to ensure accuracy
default_versions_raw=$(get_raw_entries_for_channel "$default_channel")
declare -A identical_channels
identical_channels=()

while IFS=$'\n' read -r channel; do
    if [[ -z "$channel" || "$channel" == "---" ]]; then continue; fi

    if [[ "$channel" != "$default_channel" ]]; then
        channel_versions_raw=$(get_raw_entries_for_channel "$channel")
        if [[ "$channel_versions_raw" == "$default_versions_raw" ]]; then
            identical_channels["$channel"]=1
        fi
    fi
done <<< "$channels"

if [[ ${#identical_channels[@]} -eq 0 ]]; then
    echo "  None"
else
    for chan in "${!identical_channels[@]}"; do
        echo "  $chan"
    done
fi