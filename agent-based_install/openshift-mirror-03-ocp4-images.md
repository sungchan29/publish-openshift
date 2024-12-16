

```markdown
이 스크립트는 OpenShift의 ImageSet 설정 파일을 자동으로 생성하여 특정 경로와 버전을 설정하는 과정을 관리합니다.
다음은 스크립트의 주요 기능입니다:

  1. 초기화:
     OCP_UPDATE_PATH, OCP4_IMAGESET_CONFIG_FILE, LOCAL_PATH와 같은 변수들을 초기화합니다.
  2. OCP_UPDATE_PATH 값 추출:
     download-openshift-tools-images.sh 파일에서 OCP_UPDATE_PATH 값을 앞의 공백을 허용하며 추출합니다.
  3. ImageSet 설정 파일 생성:
     * 기존 설정 파일이 있으면 삭제한 후 ocp4-imageset-config.yaml이라는 이름의 새로운 설정 파일을 생성합니다.
     * LOCAL_PATH 값에 따라 저장 경로를 설정합니다.
  4. OpenShift 버전 처리:
     * OCP_UPDATE_PATH 값을 -- 구분자로 나누어 버전 배열을 만듭니다.
     * 각 버전에 대해 주요(minor) 및 패치 버전을 추출합니다.
     * 주요(minor) 버전에 대해 최솟값 및 최댓값 패치 버전을 설정합니다.
  5. 결과를 설정 파일에 기록:
     각 주요 버전에 대해 최소, 최대 패치 버전을 설정 파일에 작성합니다.
```

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

```markdown
이 스크립트는 다음 작업을 수행합니다:

  1. 초기화:
       oc-mirror 명령의 최대 재시도 횟수를 정의하고, 설정 변수들을 초기화합니다.
  2. 로그 기록:
       스크립트 시작 시간을 ocp_mirror_history.log에 기록합니다.
  3. 사전 검사:
       oc-mirror 및 ocp-imageset-config.yaml 파일이 존재하는지 확인합니다.
  4. 경로 추출:
       ocp-imageset-config.yaml의 path 필드에 따라 LOCAL_PATH를 설정하고, LOCAL_PATH의 마지막 부분을 NAMESPACE로 정의합니다.
  5. 설정 값 가져오기:
       grep과 sed를 사용하여 download-openshift-tools-images.sh에서 OCP_UPDATE_PATH 값을 추출하고, LOCAL_PATH 및 OCP_UPDATE_PATH 값이 설정되었는지 확인합니다.
  6. 이전 파일 정리:
       NAMESPACE와 OCP_UPDATE_PATH에 관련된 기존 tar 파일을 삭제합니다.
  7. 미러링 프로세스:
       최대 MAX_ATTEMPTS 횟수만큼 oc-mirror 명령을 실행하며, 각 시도와 재시도를 상세히 기록하고 필요시 재시도합니다.
       설정된 시도 횟수 이후에도 성공하지 못한 경우 세 번째 시도부터는 오류가 있어도 계속 진행합니다.
  8. 결과 처리:
       성공적인 결과가 감지되면 결과 파일을 이동하고 완료를 로그로 남기며, 그렇지 않을 경우 최대 재시도 후 실패를 기록하고 종료합니다.

주요 기능:
  * 포괄적인 로그 기록: 각 단계가 타임스탬프와 함께 기록되어 문제 해결에 도움을 줍니다.
  * 재시도 메커니즘: 최대 시도 횟수까지 재시도하며, 나중의 시도에서는 오류가 있어도 계속 진행할 수 있습니다.
  * 유연한 경로 처리: 앞에 공백이 있어도 OCP_UPDATE_PATH를 추출할 수 있도록 설계하여 경로 처리가 견고합니다.
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