## OpenShift Operator 이미지 준비
```markdown
[참고]
  - How to use the oc-mirror plug-in to mirror operators?
      https://access.redhat.com/solutions/6994677
  - How to customize the catalog name and tags of Operators mirrored to the mirror registry using the oc mirror plugin?
      https://access.redhat.com/solutions/7016714
  - oc-mirror removes operator images from mirror registry that are not referenced in the channel anymore
      https://access.redhat.com/solutions/7015441
  - The latest versions of oc-mirror do not rebuild the Catalog in RHOCP 4
      https://access.redhat.com/solutions/7077106
  - What to do when encountering "manifest unknown error: unable to retrieve source image " while using oc-mirror?
      https://access.redhat.com/solutions/7032017
```

```markdown
이 세 개의 스크립트는 OpenShift Operator Lifecycle Manager (OLM)에서 선택한 레지스트리 이미지를 특정 환경으로 미러링하는 프로세스를 자동화합니다.

스크립트 설명 및 분석
  1. 첫 번째 스크립트: openshift-operator-image-mirror-1.sh
    * 목적: OCP_UPDATE_PATH와 OLM_OPERATORS 변수에 따라 OLM operator 목록을 생성합니다.
    * 작동 방식:
      OCP_UPDATE_PATH가 설정되어 있지 않은 경우 파일에서 값을 읽어옵니다.
      OLM_OPERATORS에서 설정한 운영자 그룹별로 카탈로그 이름을 추출해 각 운영자에 대한 목록을 파일로 저장합니다.
    * 출력: olm-<catalog>-v<version>.txt 파일을 생성하여 각 카탈로그와 버전별로 운영자 목록을 저장합니다.
  2. 두 번째 스크립트: openshift-operator-image-mirror-2.sh
    * 목적: 첫 번째 스크립트의 결과를 바탕으로 ImageSetConfiguration 파일을 생성합니다.
    * 작동 방식:
      - 첫 번째 스크립트의 출력 파일을 읽고, 미리 설정된 운영자 필터(예: SELECT_REDHAT_OPERATORS)에 따라 목록을 필터링합니다.
      - 운영자 목록을 olm-<catalog>-imageset-config.yaml 파일로 작성하여 ImageSetConfiguration 형식에 맞추어 YAML 파일을 생성합니다.
    * 출력: 필터링된 운영자 목록 파일과 olm-<catalog>-imageset-config.yaml 설정 파일을 생성합니다.
  3. 세 번째 스크립트: openshift-operator-image-mirror-3.sh
    * 목적: 생성된 ImageSetConfiguration 파일을 사용해 실제로 이미지를 미러링하고 오류 발생 시 재시도합니다.
    * 작동 방식:
      - local_path와 img_tags를 추출해 경로와 태그를 확인하고, 각 경로에 대해 미러링 작업을 시작합니다.
      - 최대 7회 oc-mirror 명령을 실행하여 미러링을 시도합니다.
      - 4회 실패 후에는 --continue-on-error를 추가하여 실행합니다.
      - 성공 시 로그에 결과를 기록하고 파일을 이동합니다.
    * 출력: 미러링 작업의 성공 및 실패 로그와 미러링된 파일을 지정된 경로에 저장합니다.
```

### 1.레지스트리 로그인 설정

```bash

podman login registry.redhat.io

```

```bash

if [[ -f ~/Downloads/ocp/pull-secret.txt ]]; then
    cat ~/Downloads/ocp/pull-secret.txt
    cat ~/Downloads/ocp/pull-secret.txt | jq . > $XDG_RUNTIME_DIR/containers/auth.json
    echo ""
fi
cat $XDG_RUNTIME_DIR/containers/auth.json

```

### 2. Imageset Config 파일 생성을 위한 Shell Script 작성

```bash

if [[ ! -d ${HOME}/Downloads/ocp/mirror_workspace ]]; then
    mkdir -p ~/Downloads/ocp/mirror_workspace
fi
cd ~/Downloads/ocp/mirror_workspace

vi openshift-mirror-04-ocp4-operator-images-stage1.sh

```

```bash
#!/bin/bash

# Source the config.sh file
if [[ -f $(dirname "$0")/openshift-mirror-01-config-preparation.sh ]]; then
    source "$(dirname "$0")/openshift-mirror-01-config-preparation.sh"
else
    OC_MIRROR_HISTORY="oc-mirror_history.log"
    echo "ERROR: Cannot access '$(dirname "$0")/openshift-mirror-01-config-preparation.sh'. File or directory does not exist. Exiting..." >> $OC_MIRROR_HISTORY
    exit 1
fi
#####################
### Variable Override Section

#####################
if [[ -z "$OC_MIRROR_HISTORY" ]]; then
    OC_MIRROR_HISTORY="oc-mirror_history.log"
    echo "ERROR: OC_MIRROR_HISTORY variable is empty. Exiting..."                                                                         >> $OC_MIRROR_HISTORY
    exit 1
fi
# Log script start time
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script started"                                                                                      >> $OC_MIRROR_HISTORY

# Define the variable name to check; if not, exit with an error
if [[ -z "${OCP_UPDATE_PATH}" ]]; then
    echo "ERROR: OCP_UPDATE_PATH variable is empty. Exiting..."                                                                           >> $OC_MIRROR_HISTORY
    exit 1
fi
if [[ -z "${DOWNLOAD_DIRECTORY}" ]]; then
    echo "ERROR: DOWNLOAD_DIRECTORY variable is empty. Exiting..."                                                                        >> $OC_MIRROR_HISTORY
    exit 1
fi
if [[ ! -d "$DOWNLOAD_DIRECTORY" ]]; then
    mkdir -p "$DOWNLOAD_DIRECTORY" || { echo "Error: Failed to create directory. Exiting..." >> $OC_MIRROR_HISTORY; exit 1; }
fi
if [[ -z "$OLM_OPERATORS" ]]; then
    echo "ERROR: OLM_OPERATORS variable is empty. Exiting..."                                                                             >> $OC_MIRROR_HISTORY
    exit 1
fi
if [[ ! -f ./oc-mirror ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Cannot access './oc-mirror'. File or directory does not exist. Exiting..."                >> $OC_MIRROR_HISTORY
    exit 1
fi

find . -type f -name "ocp4-olm-*.txt"  -exec rm -f {} +
find . -type f -name "ocp4-olm-*.yaml" -exec rm -f {} +

for version in $(echo "$OCP_UPDATE_PATH" | sed 's/--/\n/g' | awk -F '.' '{print $1"."$2}' | sort -u); do
    for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g'); do
        ./oc-mirror list operators --catalog=registry.redhat.io/redhat/${catalog}-operator-index:v${version} |tee ocp4-olm-${catalog}-v${version}.txt
    done
done
```

```bash

nohup sh openshift-mirror-04-ocp4-operator-images-stage1.sh > /dev/null 2>&1 &

```

### 3. ImageSetConfiguration 파일 생성

```bash

vi openshift-mirror-04-ocp4-operator-images-stage2.sh

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
#####################
### Variable Override Section

#####################
PREVIOUS_SHELL_SCRIPT_FILE="${PREVIOUS_SHELL_SCRIPT_FILE:-openshift-operator-image-mirror-1.sh}"
if [[ -f "${PREVIOUS_SHELL_SCRIPT_FILE}" ]]; then
    # Extract the OLM_OPERATORS value, allowing for leading spaces
    OLM_OPERATORS=${OLM_OPERATORS:-$(grep -Eo '^\s*OLM_OPERATORS=.*' $PREVIOUS_SHELL_SCRIPT_FILE | sed 's/.*=//' | tr -d '"')}
fi

if [[ -z "$OLM_OPERATORS" ]]; then
    echo "ERROR: OLM_OPERATORS variable is empty. Exiting..." 
    exit 1
fi

find . -type f -name "ocp4-olm-*-edit.txt" -exec rm -f {} +
find . -type f -name "ocp4-olm-*.yaml"     -exec rm -f {} +

for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g'); do
    filename=""
    select_operators=""
    ocp4_olm_imageset_config_file=""

    if [[ "redhat" = "$catalog" ]]; then
        if [[ -z "$OCP4_OLM_RH_IMAGESET_CONFIG_FILE" ]]; then
            echo "ERROR: OCP4_OLM_RH_IMAGESET_CONFIG_FILE variable is empty. Exiting..."
            exit 1
        fi
        filename="${OCP4_OLM_RH_IMAGESET_CONFIG_FILE%.*}-v${version}"
        select_operators="$SELECT_REDHAT_OPERATORS"
        ocp4_olm_imageset_config_file="$OCP4_OLM_RH_IMAGESET_CONFIG_FILE"
    fi
    if [[ "certified" = "$catalog" ]]; then
        if [[ -z "$OCP4_OLM_CT_IMAGESET_CONFIG_FILE" ]]; then
            echo "ERROR: OCP4_OLM_CT_IMAGESET_CONFIG_FILE variable is empty. Exiting..."
            exit 1
        fi
        filename="${OCP4_OLM_CT_IMAGESET_CONFIG_FILE%.*}-v${version}"
        select_operators="$SELECT_CERTIFIED_OPERATORS"
        ocp4_olm_imageset_config_file="$OCP4_OLM_CT_IMAGESET_CONFIG_FILE"
    fi
    if [[ "community" = "$catalog" ]]; then
        if [[ -z "$OCP4_OLM_CM_IMAGESET_CONFIG_FILE" ]]; then
            echo "ERROR: OCP4_OLM_CM_IMAGESET_CONFIG_FILE variable is empty. Exiting..."
            exit 1
        fi
        filename="${OCP4_OLM_CM_IMAGESET_CONFIG_FILE%.*}-v${version}"
        select_operators="$SELECT_COMMUNITY_OPERATORS"
        ocp4_olm_imageset_config_file="$OCP4_OLM_CM_IMAGESET_CONFIG_FILE"
    fi

cat <<EOF > ${ocp4_olm_imageset_config_file}
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
storageConfig:
  local:
    path: ./olm-${catalog}
mirror:
  operators:
EOF
    for version in $(echo "$OCP_UPDATE_PATH" | sed 's/--/\n/g' | awk -F '.' '{print $1"."$2}' | sort -u); do
        cat ocp4-olm-${catalog}-v${version}.txt | egrep -e "${select_operators}" | grep -v candidates |tee ocp4-olm-${catalog}-v${version}-edit.txt
cat <<EOF >> ${ocp4_olm_imageset_config_file}
  - catalog: registry.redhat.io/redhat/${catalog}-operator-index:v${version}
    packages:
$(cat ocp4-olm-${catalog}-v${version}-edit.txt |awk '{ print "    - name: " $1 "\n      channels:\n      - name: " $NF }')
EOF
    done
done
```

```bash

sh openshift-mirror-04-ocp4-operator-images-stage2.sh

```

### 4. ImageSetConfiguration 파일 확인 및 수정

### 5. 오퍼레이터 이미지 미러링 Shell Script 작성

```bash

vi openshift-mirror-04-ocp4-operator-images-stage3.sh

```

```bash
#!/bin/bash

# Source the config.sh file
if [[ -f $(dirname "$0")/openshift-mirror-01-config-preparation.sh ]]; then
    source "$(dirname "$0")/openshift-mirror-01-config-preparation.sh"
else
    OC_MIRROR_HISTORY="oc-mirror_history.log"
    echo "ERROR: Cannot access '$(dirname "$0")/openshift-mirror-01-config-preparation.sh'. File or directory does not exist. Exiting..." >> $OC_MIRROR_HISTORY
    exit 1
fi
#####################
### Variable Override Section

#####################
if [[ -z "$OC_MIRROR_HISTORY" ]]; then
    OC_MIRROR_HISTORY="oc-mirror_history.log"
    echo "ERROR: OC_MIRROR_HISTORY variable is empty. Exiting..."                                                                         >> $OC_MIRROR_HISTORY
    exit 1
fi
# Log script start time
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Script started"                                                                                      >> $OC_MIRROR_HISTORY

if [[ ! -f ./oc-mirror ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Cannot access './oc-mirror'. File or directory does not exist. Exiting..."                >> $OC_MIRROR_HISTORY
    exit 1
fi

# Check if directory variables are set
if [[ -z "${DOWNLOAD_DIRECTORY}" || -z "${OCP_UPDATE_PATH}" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Please set both DOWNLOAD_DIRECTORY and OCP_UPDATE_PATH variables."                        >> $OC_MIRROR_HISTORY
    exit 1
fi
if [[ -d $DOWNLOAD_DIRECTORY ]]; then
    olm_mirror_images="$(find "${DOWNLOAD_DIRECTORY}" -type f -name "olm-*-v${OCP_UPDATE_PATH}_mirror_seq*")"
    for olm_mirror_image_file in $olm_mirror_images; do
        if [[ -f $olm_mirror_image_file ]]; then
            rm -f $olm_mirror_image_file
        fi
    done
else
    mkdir -p $DOWNLOAD_DIRECTORY
fi

for catalog in $(echo "$OLM_OPERATORS" | sed 's/--/\n/g'); do
    imageset_config_file=ocp4-olm-${catalog}-imageset-config.yaml

    if [[ -f $imageset_config_file ]]; then
        local_path=$(grep -oP '(?<=path:\s).+' "$imageset_config_file")
        namespace=$(echo $local_path | awk -F "/" '{print $NF}')

        # Check local_path and img_tags
        if [[ -z "${local_path}" ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: local_path variable is empty."                                                    >> $OC_MIRROR_HISTORY
            exit 1
        fi

        echo "[$(date +"%Y-%m-%d %H:%M:%S")]"                                                                                             >> $OC_MIRROR_HISTORY
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] imageset-config: $imageset_config_file"                                                      >> $OC_MIRROR_HISTORY
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] OCP_UPDATE_PATH: $OCP_UPDATE_PATH"                                                           >> $OC_MIRROR_HISTORY
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] local_path: $local_path"                                                                     >> $OC_MIRROR_HISTORY

        if [[ -d $local_path ]]; then
            rm -Rf $local_path
        fi
        # Create local_path
        mkdir -p ${local_path} 
        if [[ ! -d "$local_path" ]]; then
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Directory $local_path does not exist."                                            >> $OC_MIRROR_HISTORY
            exit 1
        fi

        attempt=0
        max_attempts=7
        oc_mirror_result=""

        while [[ -z "$oc_mirror_result" && $attempt -lt $max_attempts ]]; do
            ((attempt++))
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] Attempt #$attempt"                                                                       >> $OC_MIRROR_HISTORY

            oc_mirror_path="file://${local_path}"

            if [[ $attempt -lt 5 ]]; then
                ./oc-mirror --config=./${imageset_config_file} ${oc_mirror_path}
            else
                ./oc-mirror --config=./${imageset_config_file} ${oc_mirror_path} --continue-on-error
            fi

            oc_mirror_result=$(tail -10 .oc-mirror.log | grep "${namespace}/mirror_seq")

            if [[ -n "$oc_mirror_result" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] oc-mirror command completed."                                                        >> $OC_MIRROR_HISTORY
                archive_file=$(echo "$oc_mirror_result" | awk '{print $NF}')
                archive_file_name=$(basename "$archive_file")

                if [[ -f ${DOWNLOAD_DIRECTORY}/${namespace}-v${OCP_UPDATE_PATH}_${archive_file_name} ]]; then
                    rm -f ${DOWNLOAD_DIRECTORY}/${namespace}-v${OCP_UPDATE_PATH}_${archive_file_name}
                fi

                if [[ -f "$archive_file" ]]; then
                    mv $archive_file ${DOWNLOAD_DIRECTORY}/${namespace}-v${OCP_UPDATE_PATH}_${archive_file_name}
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] File has been successfully moved."                                               >> $OC_MIRROR_HISTORY
                else
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $archive_file file not found"                                                    >> $OC_MIRROR_HISTORY
                fi
            else
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] No valid result found, retrying..."                                                  >> $OC_MIRROR_HISTORY
            fi
        done
    else
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] $imageset_config_file file not found"                                                        >> $OC_MIRROR_HISTORY
    fi
done

if [[ -z "$oc_mirror_result" ]]; then
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] ERROR: Failed to mirror after $max_attempts attempts."                                           >> $OC_MIRROR_HISTORY
fi
echo "[$(date +"%Y-%m-%d %H:%M:%S")] Finished."                                                                                           >> $OC_MIRROR_HISTORY
```

```bash

nohup sh openshift-mirror-04-ocp4-operator-images-stage3.sh > /dev/null 2>&1 &

```