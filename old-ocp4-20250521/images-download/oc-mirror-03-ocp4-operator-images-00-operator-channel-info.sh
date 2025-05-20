#!/bin/bash

### Assign command-line arguments
catalog_file=$1

### Function to get all versions in a channel
get_defaultchannel_for_operator() {
   lc_channel=$(cat "$catalog_file" \
        | jq -r 'select(.schema == "olm.package") | .defaultChannel')
    echo "$lc_channel"
}

get_channels_for_operator() {
   lc_channels=$(cat "$catalog_file" \
        | jq -r 'select(.schema == "olm.channel") | .name' \
        | sort -Vr -u)
    echo "$lc_channels"
}

### Function to get all versions in a channel
get_versions_for_channel() {
    local lc_channel="$1"
    local lc_versions
    local lc_versions=$(cat "$catalog_file" \
        | jq -r --arg chan "$lc_channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | .name' \
        | sort -Vr -u)
    echo "$lc_versions"
}

### Function to extract version number without prefix
get_properties_version() {
    local lc_full_version="$1"
    local lc_prop_version=$(cat "$catalog_file" \
        | jq -r --arg ver "$lc_full_version" 'select(.schema == "olm.bundle" and .name == $ver) | .properties[]? | select(.type == "olm.package") | .value.version // ""')
    echo "$lc_prop_version"
}
### Function to extract version from string
get_extract_version() {
    local lc_input="$1"
    local lc_version="${lc_input#*.}"
    echo "${lc_version#v}"
}

default_channel=$(get_defaultchannel_for_operator)

default_versions=$(get_versions_for_channel "$default_channel")

channels=$(get_channels_for_operator)
channel_count=$(echo "$channels" | wc -l)

### Display total number of channels and their versions with skipRange
echo "Total Number of Channels: $channel_count"
echo "Channel Details:"
while IFS=$'\n' read -r channel; do
    echo "  Channel: $channel"
    versions=$(cat "$catalog_file" \
        | jq -r --arg chan "$channel" 'select(.schema == "olm.channel" and .name == $chan) | .entries[] | [.name, .skipRange // "None"] | join(" (skipRange: ") + ")"' \
        | sort -Vr -u)
    echo "$versions" | while IFS=$'\n' read -r ver; do
        full_ver=$(echo "$ver" | cut -d' ' -f1)
        prop_ver=$(get_properties_version "$full_ver")
        skiprange=$(echo "$ver" | sed "s/^[^ ]* //")
        printf "%-9s %-54s %-9s %-28s %s\n" \
               "    Name: " "$full_ver" " Version: " "$prop_ver" "$skiprange"
    done
done <<< "$channels"

### Find versions in default channel
default_versions=$(get_versions_for_channel "$default_channel")

### Check for other channels with the same version list as default channel
echo ""
echo "Channels with Identical Version List to Default Channel ('$default_channel'):"
declare -A identical_channels
while IFS=$'\n' read -r channel; do
    if [[ "$channel" != "$default_channel" ]]; then
        channel_versions=$(get_versions_for_channel "$channel")
        if [[ "$channel_versions" == "$default_versions" ]]; then
            identical_channels["$channel"]=1
        fi
    fi
done <<< "$channels"

if [ ${#identical_channels[@]} -eq 0 ]; then
    echo "  None"
else
    for chan in "${!identical_channels[@]}"; do
        echo "  $chan"
    done
fi