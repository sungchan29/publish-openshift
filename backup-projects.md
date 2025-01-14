## OpenShift 클러스터에서 사용자가 생성한 Project 백업

#### OpenShift 클러스터 시스템 클러스터 및 리소스 제외 하는 방법
다음과 같은 변수를 설정하여 namespace와 resource를 제외 시킬 수 있음
* KEY_WORD_EXCLUDE_NAMESPACES
* KEY_WORD_EXCLUDE_API_RESOURCES

#### json 파일 생성시 항목 제거 하는 방법
* json 파일 생성시 다음과 같은 방법을 사용하여 항목을 삭제 할 수 있음.

* 본 가이드에서 사용하는 방법
```text
jq 'del(.status)'
```

* 옵션 추가 예시
```text
jq 'del(.metadata.uid,
        .metadata.selfLink,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.generation,
        .status)'
```

#### 프로젝트 복구 방법

* 예시
  ```text

  PROJECT_NAME="sso"
  oc get pv |grep "${PROJECT_NAME}"
  
  oc delete pv [pv] [pv] ... 

  cd [BACKUP_PROJECTS_DIR]/[PROJECT_NAME]
  
  ls -1 ./ |sort |xargs --no-run-if-empty -I {} oc create -f {}
  
  ```

#### 백업 shell script 설명
* oc, jq CLI를 사용
* oc logout을 먼저 수행하고 oc login 수행
* PVC시 백업시 사용하던 PV도 백업
* --debug 모드 사용하여 검증 후 사용 권고
* 프로젝트 생성시 기본 생성되는 리소스도 백업 받음
* LINE_BREAK_INTERVAL은 프로젝트 백업을 직접 수행 할 때 api resource 하나당 .으로 표시(--debug, --silent 모드에서는 사용 안 함)



```bash
#!/bin/bash

PROJ_BACKUP_BASE_DIR="backup-ocp-projects/$(date +\%Y-\%m-\%d-\%H\%M)"

### oc, jq, base64
PATH_UTIL=""

### Login to the openshift
###   ENCODING_PASSWORD: echo -n "<password>" | base64
API_SERVER=""
ENCODING_USERNAME=""
ENCODING_PASSWORD=""

### Default : KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}
KUBECONFIG=""

### Backup Projects
BACKUP_NAMESPACES=""
BACKUP_API_RESOURCES=""
### OR
KEY_WORD_EXCLUDE_NAMESPACES='namespace/openshift-|namespace/kube-|namespace/default$|namespace/openshift$'
KEY_WORD_EXCLUDE_API_RESOURCES='^builds.|^endpoints$|^endpointslices|^events|^packagemanifests|^pods$|^pods\.|^replicasets.apps|^replicationcontrollers'

###
LINE_BREAK_INTERVAL=50

# silent, debug, standard(default)
BACKUP_MODE=""


################
### Function ###
################

usage() {
    echo
    echo 'Usage: $0 [-u <username>] [--projects "<value 1> ... <value N>"] [--silent] [--debug] [<api server>]'
    echo
    exit 0
}

headline_box() {
    local text="$1"
    local char="$2"
    local length=${#text}
    local headline=$(printf "%-${length}s" | tr ' ' "$char")
    echo "$headline"
    echo "$text"
    echo "$headline"
}

debug_output() {
    local text="$1"
    local char="#"
    local prefix_text=$(printf "%-3s" |tr ' ' "$char")
    echo "$prefix_text DEBUG $prefix_text $text"
}


###################
### Input value ###
###################

DECODING_USERNAME=""
DECODING_PASSWORD=""

if [[ "" != ${ENCODING_USERNAME} ]]; then
    DECODING_USERNAME=$(echo "${ENCODING_USERNAME}" | base64 -d)
fi
if [[ "" != ${ENCODING_PASSWORD} ]]; then
    DECODING_PASSWORD=$(echo "${ENCODING_PASSWORD}" | base64 -d)
fi

help="false"
apiserver="${API_SERVER}"
username="${DECODING_USERNAME}"
password="${DECODING_PASSWORD}"
projects="${BACKUP_NAMESPACES}"
silent="false"
debug="false"

if [[ "silent" = ${BACKUP_MODE} ]]; then
    silent="true"
elif [[ "debug" = ${BACKUP_MODE} ]]; then
    debug="true"
fi

while [[ $# -gt 0 ]];
do
    case "$1" in
        --help)
            help="true"
            shift
            ;;
        -h)
            help="true"
            shift
            ;;
        --username=*)
            username="${1#*=}"
            shift
            ;;
        --username)
            username="$2"
            shift 2
            ;;
        --password=*)
            password="${1#*=}"
            shift
            ;;
        --password)
            password="$2"
            shift 2
            ;;
        --projects=*)
            projects="${1#*=}"
            shift
            ;;
        --projects)
            projects=$(echo "$2" | awk '{$1=$1; print}')
            shift 2
            ;;
        --silent)
            silent="true"
            shift
            ;;
        --debug)
            debug="true"
            shift
            ;;
        -u)
            username="$2"
            shift 2
            ;;
        -p)
            password="$2"
            shift 2
            ;;
        *)
            apiserver="$1"
            shift
            ;;
    esac
done

if [[ "true" = ${help} ]]; then
    usage
fi

if [[ "true" = ${debug} ]]; then
    silent="false"
fi

if [[ "true" = ${debug} ]]; then
    echo
    headline_box "1. Check arguments" "#"
    debug_output ""
    debug_output "apiserver: ${apiserver}"
    debug_output " username: ${username}"
    debug_output " password: ${password}"
    debug_output " projects: $projects"
    debug_output "   silent: ${silent}"
    debug_output "    debug: ${debug}"
    debug_output ""
fi

if [[ "default" = ${projects} ]]; then
    projects=""
    BACKUP_NAMESPACES=""
    BACKUP_API_RESOURCES=""
fi


###########################
### Check utils(oc, jq) ###
###########################

if [[ ! -z ${PATH_UTIL} ]]; then
    export PATH="${PATH_UTIL}:${PATH}"
fi

if [[ -z $(which oc) ]]; then
    exit 1
fi

if [[ -z $(which jq) ]]; then
    exit 1
fi

if [[ "true" = ${debug} ]]; then
    headline_box "2. Check utils(oc, jq)" "#"
    debug_output ""
    debug_output "PATH=${PATH}"
    debug_output ""
    which oc
    debug_output ""
    which jq
    debug_output ""
fi


#################
### oc logout ###
#################

if [[ "true" = ${debug} ]]; then
    echo
    headline_box "3. oc logout" "#"
fi

KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
if [[ "true" = ${debug} ]]; then
    debug_output ""
    debug_output "KUBECONFIG : ${KUBECONFIG}"
    debug_output ""
fi

if [[ -f "${KUBECONFIG}" ]]; then
    USER_TOKEN=$(oc config view --minify -o jsonpath='{.users[].user.token}')
    if [[ -n ${USER_TOKEN} ]]; then
        if [[ "true" = ${debug} ]]; then
            debug_output ""
            debug_output "user.token : ${USER_TOKEN}"
            debug_output "oc whoami  : $(oc whoami)"
            debug_output ""
            oc logout
            debug_output ""
        else
            if [[ "true" = ${silent} ]]; then
                oc logout > /dev/null 2>$1
            else
                oc logout
            fi
        fi
    fi
fi

if [[ "false" = ${silent} ]]; then
    if [[ -z "${apiserver}" ]]; then
        API_SERVER=$(cat ${KUBECONFIG} |grep "^- cluster" -A 2 |grep server |sort -k 2 |uniq |awk '{print $2}')
        if [[ -z ${API_SERVER} ]]; then
            API_SERVER="https://localhost:6443"
        fi

        read -p "Server [${API_SERVER}]: " apiserver
        if [[ -z ${apiserver} ]]; then
            apiserver="${API_SERVER}"
        fi
    fi
    if [[ ${apiserver} != https://* ]]; then
        apiserver="https://${apiserver}"
    fi

    echo
    echo "Authentication required for ${apiserver} (openshift)"

    if [[ -z "${username}" ]]; then
        read -p "Username: " username
    fi

    if [[ -z "${password}" ]]; then
        read -s -p "Password: " password
        echo
    fi
fi

if [[ "true" = ${debug} ]]; then
    echo
    headline_box "4. Login Infomation" "#"
    debug_output ""
    debug_output "apiserver: ${apiserver}"
    debug_output " username: ${username}"
    debug_output " password: ${password}"
    debug_output ""
fi


#############################
### Log in to your server ###
#############################

if [[ -z ${username} || -z ${password} ]]; then
    if [[ "true" != ${silent} ]]; then
        echo
        echo "Username and password cannot be empty"
        echo
    fi
    exit 1
fi

if [[ "true" = ${debug} ]]; then
    echo
    headline_box "5. oc login ${apiserver}" "#"
    debug_output ""
    oc login -u ${username} -p ${password} ${apiserver} --insecure-skip-tls-verify
else
    if [[ "true" = ${silent} ]]; then
        oc login -u ${username} -p ${password} ${apiserver} --insecure-skip-tls-verify  > /dev/null 2>&1
    else
        oc login -u ${username} -p ${password} ${apiserver} --insecure-skip-tls-verify
    fi
fi
login_execute_code=$?

# Execute Code
if [[ ${login_execute_code} -eq 0 ]]; then
    :
else
    exit 1
fi


#######################
### Backup projects ###
#######################

if [[ "true" = ${debug} ]]; then
    echo
    headline_box "6. Backup projects" "#"
fi

NAMESPACES=""
if [[ -z ${projects} ]]; then
    if [[ -z ${KEY_WORD_EXCLUDE_NAMESPACES} ]]; then
        NAMESPACES=$(oc get namespaces -o name --sort-by metadata.name)
    else
        NAMESPACES=$(oc get namespaces -o name --sort-by metadata.name |egrep -v "${KEY_WORD_EXCLUDE_NAMESPACES}")
    fi
else
    for project in ${projects}
    do
        VALID_NAMESPACES=$(oc get namespaces ${project} -o name 2> /dev/null)
        if [[ -z ${VALID_NAMESPACES} ]]; then
            oc get namespaces ${project} -o name
            continue
        else
            NAMESPACES="${NAMESPACES} ${VALID_NAMESPACES}"
        fi
    done
fi
if [[ "true" = ${debug} ]]; then
    debug_output ""
    headline_box "NAMESPACES" "="
    echo "${NAMESPACES}"
    echo
else
    if [[ "true" != ${silent} ]]; then
        echo
        echo "### Backup projects"
        #echo "${NAMESPACES}" |sed 's/^ *//;s/ *$//' |tr ' ' '\n'
        echo "${NAMESPACES}" | awk '{$1=$1; print}' |tr ' ' '\n'
        echo
    fi
fi

API_RESOURCES=""
if [[ -z ${BACKUP_API_RESOURCES} ]]; then
    if [[ -z ${KEY_WORD_EXCLUDE_API_RESOURCES} ]]; then
        API_RESOURCES=$(oc api-resources --namespaced -o name --sort-by name)
    else
        API_RESOURCES=$(oc api-resources --namespaced -o name --sort-by name |egrep -v "${KEY_WORD_EXCLUDE_API_RESOURCES}")
    fi
else
    API_RESOURCES="${BACKUP_API_RESOURCES}"
fi
if [[ "true" = ${debug} ]]; then
    headline_box "API_RESOURCES" "="
    #echo "${API_RESOURCES}" |sed 's/^ *//;s/ *$//' |tr ' ' '\n'
    $(echo "${API_RESOURCES}" | awk '{$1=$1; print}' |tr ' ' '\n')
    echo
fi

PROJ_BACKUP_DIR=""
for ns in ${NAMESPACES}
do
    NAMESPACE=$(echo ${ns} |awk -F"/" '{print $2}')

    PROJ_BACKUP_DIR="${PROJ_BACKUP_BASE_DIR}/${NAMESPACE}"

    if [[ "true" = ${debug} ]]; then
        debug_output "[Current Time]"
        date
        debug_output "mkdir -p ${PROJ_BACKUP_DIR}"
        mkdir -p ${PROJ_BACKUP_DIR}
        mkdir_execute_code=$?
        debug_output "ls -l ${PROJ_BACKUP_DIR}"
        ls -l ${PROJ_BACKUP_DIR}
        echo
    else
        if [[ "true" = ${silent} ]]; then
            mkdir -p ${PROJ_BACKUP_DIR} > /dev/null 2>&1
        else
            mkdir -p ${PROJ_BACKUP_DIR}
        fi
        mkdir_execute_code=$?
    fi
    if [[ ${mkdir_execute_code} -eq 0 ]]; then
        if [[ "false" = ${silent} ]]; then
            echo    "### ${ns} "
        fi
    else
        continue
    fi

    oc get ${ns} -o json  | jq 'del(.status)' > ${PROJ_BACKUP_DIR}/0_namespace_${NAMESPACE}.json

    API_RESOURCE_COUNT=0
    for api_resource in ${API_RESOURCES}
    do
        API_RESOURCE_COUNT=$(expr ${API_RESOURCE_COUNT} + 1)
        if [[ "false" = ${silent} && "false" = ${debug} ]]; then
            echo -n "."
            if (( API_RESOURCE_COUNT % LINE_BREAK_INTERVAL == 0 )); then
                echo
                echo -n ""
            fi
        fi

        OBJ_FILE_NAME="${API_RESOURCE_COUNT}_${api_resource}.json"
        OBJ_FILE="${PROJ_BACKUP_DIR}/${OBJ_FILE_NAME}"

        if [[ "true" = "${debug}" ]]; then
            echo
            debug_output ""
            headline_box "${NAMESPACE} : ${api_resource}" "-"
            oc get -n ${NAMESPACE} ${api_resource} -o name |sort
            echo
        fi

        OBJECTS=$(oc get -n ${NAMESPACE} ${api_resource} -o name 2> /dev/null |sort)

        if [[ "" != ${OBJECTS} ]]; then
            if [[ "persistentvolumeclaims" == "${api_resource}" ]]; then
                PV_FILE=${PROJ_BACKUP_DIR}/${API_RESOURCE_COUNT}_persistentvolumes.json

                PVC_COUNT=0
                for object in $OBJECTS
                do
                    PVC_COUNT=$(expr ${PVC_COUNT} + 1)
                    PVC_NAME=$(echo ${object} |awk -F'/' '{print $2}')
                    PV_NAME=$(oc get pv -o jsonpath='{.items[?(@.spec.claimRef.name=="'${PVC_NAME}'")].metadata.name}')

                    if [[ "true" = "${debug}" ]]; then
                        debug_output "            PVC_COUNT : ${PVC_COUNT}"
                        debug_output "PersistentVolumeClaim : ${PVC_NAME}"
                        debug_output "     PersistentVolume : ${PV_NAME}"
                        echo
                    fi
                    if [[ "1" -eq "${PVC_COUNT}" ]]; then
                        oc get -n ${NAMESPACE} ${object} -o json |jq 'del(.status)'                 > ${OBJ_FILE}
                        oc get pv ${PV_NAME}             -o json |jq 'del(.spec.claimRef,.status)'  > ${PV_FILE}
                    else
                        oc get -n ${NAMESPACE} ${object} -o json |jq 'del(.status)'                >> ${OBJ_FILE}
                        oc get pv ${PV_NAME}             -o json |jq 'del(.spec.claimRef,.status)' >> ${PV_FILE}
                    fi
                done
            else
                echo "${OBJECTS}" |xargs --no-run-if-empty -I {} oc get -n ${NAMESPACE} {} -o json |jq 'del(.status)'   > ${OBJ_FILE}
            fi
        fi
    done
    if [[ "false" = ${silent} && "false" = ${debug} ]]; then
        echo
    fi
done


#################
### oc logout ###
#################

if [[ "true" = ${debug} ]]; then
    echo
    headline_box "7. oc logout" "#"
    debug_output ""
    oc logout
else
    if [[ "true" = ${silent} ]]; then
        oc logout  > /dev/null 2>&1
    else
        oc logout
    fi
fi

```
