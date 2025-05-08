
```bash

vi openshift-mirror-03-ocp4-images-stage1.sh

```

```bash
#!/bin/bash

# Source the config.sh file
if [[ -f $(dirname "$0")/openshift-mirror-01-config-preparation.sh ]]; then
    source "$(dirname "$0")/openshift-mirror-01-config-preparation.sh"
else
    echo "ERROR: Cannot access '$(dirname "$0")/openshift-mirror-01-config-preparation.sh'. File or directory does not exist. Exiting..."
    exit 1
fi
#############################
### Variable Override Section

#############################
# Define the variable name to check; if not, exit with an error
if [[ -z "${OCP_UPDATE_PATH}" ]]; then
    echo "ERROR: OCP_UPDATE_PATH variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${DOWNLOAD_DIRECTORY}" ]]; then
    echo "ERROR: DOWNLOAD_DIRECTORY variable is empty. Exiting..."
    exit 1
fi
if [[ -z "${OCP4_IMAGESET_CONFIG_FILE}" ]]; then
    echo "ERROR: OCP4_IMAGESET_CONFIG_FILE variable is empty. Exiting..."
    exit 1
fi

OCP_UPDATE_PATH=$(echo "$OCP_UPDATE_PATH" | sed 's/--/|/g')

# Split OCP_UPDATE_PATH into an array by '|'
IFS='|' read -r -a versions <<< "$OCP_UPDATE_PATH"

unset min_versions
unset max_versions

declare -A min_versions
declare -A max_versions
declare -A prefixes

# Process each version
for version in "${versions[@]}"; do
    # Initialize prefix as 'stable' by default
    prefix="stable"

    # Check if the version is an EUS version
    if [[ "$version" == eus-* ]]; then
        version=${version#eus-}  # Remove 'eus-' prefix for processing
        prefix="eus"
    fi
    # Split into major.minor and patch
    major_minor=$(echo "$version" | cut -d '.' -f 1,2)
    patch=$(echo "$version" | cut -d '.' -f 3)

    # Skip if major_minor or patch is empty
    if [[ -z "$major_minor" ]] || [[ -z "$patch" ]]; then
        continue
    fi
cat <<EOF > ${OCP4_IMAGESET_CONFIG_FILE%.*}-v${version}.yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
storageConfig:
  local:
    path: ./ocp4
mirror:
  platform:
    channels:
    - name: ${prefix}-${major_minor}
      minVersion: '$major_minor.$patch'
      maxVersion: '$major_minor.$patch'
EOF
done
```

```bash

sh openshift-mirror-03-ocp4-images-stage1.sh

```


```bash

vi openshift-mirror-03-ocp4-images-stage2.sh

```

```bash
#!/bin/bash

# Source the config.sh file
if [[ -f $(dirname "$0")/openshift-mirror-01-config-preparation.sh ]]; then
    source "$(dirname "$0")/openshift-mirror-01-config-preparation.sh"
else
    OC_MIRROR_HISTORY="oc-mirror_history.log"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")]"                                                                                    >> $OC_MIRROR_HISTORY
    echo "ERROR: Cannot access '$(dirname "$0")/openshift-mirror-01-config-preparation.sh'. File does not exist. Exiting..." >> $OC_MIRROR_HISTORY
    exit 1
fi
#############################
### Variable Override Section

#############################
if [[ -z "$OC_MIRROR_HISTORY" ]]; then
    OC_MIRROR_HISTORY="oc-mirror_history.log"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")]"                                                                                    >> $OC_MIRROR_HISTORY
    echo "ERROR: OC_MIRROR_HISTORY variable is empty. Exiting..."                                                            >> $OC_MIRROR_HISTORY
    exit 1
fi
# Log script start time
echo "[$(date +"%Y-%m-%d %H:%M:%S")]"                                                                                        >> $OC_MIRROR_HISTORY
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script started"                                                                         >> $OC_MIRROR_HISTORY

if [[ -z "$OCP_UPDATE_PATH" ]]; then
    echo "ERROR: OCP_UPDATE_PATH variable is empty. Exiting..."                                                              >> $OC_MIRROR_HISTORY
    exit 1
fi
if [[ -z "$DOWNLOAD_DIRECTORY" ]]; then
    echo "ERROR: DOWNLOAD_DIRECTORY variable is empty. Exiting..."                                                           >> $OC_MIRROR_HISTORY
    exit 1
fi
if [[ -z "$OCP4_IMAGESET_CONFIG_FILE" ]]; then
    echo "ERROR: OCP4_IMAGESET_CONFIG_FILE variable is empty. Exiting..."                                                    >> $OC_MIRROR_HISTORY
    exit 1
fi
if [[ ! -f ./oc-mirror ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Cannot access './oc-mirror'. File does not exist. Exiting..."                >> $OC_MIRROR_HISTORY
    exit 1
fi

OCP_UPDATE_PATH=$(echo "$OCP_UPDATE_PATH" | sed 's/--/|/g')

# Split OCP_UPDATE_PATH into an array by '|'
IFS='|' read -r -a versions <<< "$OCP_UPDATE_PATH"

unset min_versions
unset max_versions

declare -A min_versions
declare -A max_versions
declare -A prefixes

echo "[$(date +"%Y-%m-%d %H:%M:%S")] OCP_UPDATE_PATH: $OCP_UPDATE_PATH"                                                      >> $OC_MIRROR_HISTORY
echo "[$(date +"%Y-%m-%d %H:%M:%S")] DOWNLOAD_DIRECTORY: $DOWNLOAD_DIRECTORY"                                                >> $OC_MIRROR_HISTORY

if [[ -f .oc-mirror.log ]]; then
    rm -f .oc-mirror.log
fi

if [[ ! -d $DOWNLOAD_DIRECTORY ]]; then
    mkdir -p $DOWNLOAD_DIRECTORY
fi

# Process each version
for version in "${versions[@]}"; do
    # Initialize prefix as 'stable' by default
    prefix="stable"

    # Check if the version is an EUS version
    if [[ "$version" == eus-* ]]; then
        version=${version#eus-}  # Remove 'eus-' prefix for processing
        prefix="eus"
    fi
    # Split into major.minor and patch
    major_minor=$(echo "$version" | cut -d '.' -f 1,2)
    patch=$(echo "$version" | cut -d '.' -f 3)

    # Skip if major_minor or patch is empty
    if [[ -z "$major_minor" ]] || [[ -z "$patch" ]]; then
        continue
    fi

    imageset_config_file="${OCP4_IMAGESET_CONFIG_FILE%.*}-v${version}.yaml"
    local_path=$(grep -oP '(?<=path:\s).+' "$imageset_config_file")
    namespace=$(echo $local_path | awk -F "/" '{print $NF}')

    if [[ ! -f $imageset_config_file ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] $imageset_config_file file does not exist."                                     >> $OC_MIRROR_HISTORY
        continue
    fi

    echo "[$(date +"%Y-%m-%d %H:%M:%S")] imageset-config.yaml : $imageset_config_file"                                       >> $OC_MIRROR_HISTORY
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] local_path: $local_path"                                                            >> $OC_MIRROR_HISTORY

    # Check local_path and OCP_UPDATE_PATH
    if [[ -z "$local_path" ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: local_path variable is empty."                                           >> $OC_MIRROR_HISTORY
        exit 1
    fi

    if [[ -d $local_path ]]; then
        rm -Rf $local_path
    fi
    mkdir -p $local_path

    attempt=0
    max_attempts=5
    oc_mirror_result=""
    while [[ -z "$oc_mirror_result" && $attempt -lt $max_attempts ]]; do
        ((attempt++))
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] Attempt #$attempt"                                                              >> $OC_MIRROR_HISTORY

        oc_mirror_path="file://${local_path}"

        if [[ $attempt -lt 3 ]]; then
            ./oc-mirror --config=./$imageset_config_file ${oc_mirror_path}
        else
            ./oc-mirror --config=./$imageset_config_file ${oc_mirror_path} --continue-on-error
        fi

        oc_mirror_result=$(tail -10 .oc-mirror.log | grep "${namespace}/mirror_seq")

        if [[ -n "$oc_mirror_result" ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] oc-mirror command completed."                                               >> $OC_MIRROR_HISTORY
            archive_file=$(echo "$oc_mirror_result" | awk '{print $NF}')
            archive_file_name=$(basename "$archive_file")

            if [[ -f  ${DOWNLOAD_DIRECTORY}/${namespace}-v${version}_${archive_file_name} ]]; then
                rm -f ${DOWNLOAD_DIRECTORY}/${namespace}-v${version}_${archive_file_name}
            fi

            if [[ -f "$archive_file" ]]; then
                mv $archive_file ${DOWNLOAD_DIRECTORY}/${namespace}-v${version}_${archive_file_name}
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] File has been successfully moved."                                      >> $OC_MIRROR_HISTORY
            else
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] Archive file not found at $archive_file"                                >> $OC_MIRROR_HISTORY
            fi
        else
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] No valid result found, retrying..."                                         >> $OC_MIRROR_HISTORY
        fi
    done

    if [[ -z "$oc_mirror_result" ]]; then
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to mirror after $max_attempts attempts."                          >> $OC_MIRROR_HISTORY
    fi
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] Finished."                                                                          >> $OC_MIRROR_HISTORY
done
```

```bash

nohup sh openshift-mirror-03-ocp4-images-stage2.sh > /dev/null 2>&1 &

```
