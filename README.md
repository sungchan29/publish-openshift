# ImageSetConfiguration 생성을 위한 오퍼레이터 버전 경우의 수

이 문서는 `oc-mirror-03-ocp4-operator-images-01-gen-imageset-config.sh` 스크립트가 OpenShift Operator Lifecycle Manager (OLM) 카탈로그를 처리하여 `imageset-config.yaml` 파일을 생성할 때의 동작을 분석합니다. 오퍼레이터 정의와 버전-채널 관계에 따른 모든 경우의 수를 다루며, 스크립트가 오퍼레이터를 처리하고 YAML 출력을 생성하는 방법을 설명합니다.

## 개요

이 스크립트는 `REDHAT_OPERATORS`, `CERTIFIED_OPERATORS`, 또는 `COMMUNITY_OPERATORS` 배열에 정의된 오퍼레이터 패키지를 처리하여 `ImageSetConfiguration` YAML 파일을 생성합니다. 오퍼레이터는 `operator_name|version1|version2|...` 형식으로 지정되며, 버전은 선택 사항입니다. 스크립트는 OLM 카탈로그 파일(`catalog.json` 또는 `index.json`)에서 채널 및 버전 정보를 가져와 오퍼레이터 이름, 채널, 그리고 선택적으로 `minVersion` 필드를 포함한 YAML을 생성합니다.

### 입력 구조
- **오퍼레이터 정의**: `REDHAT_OPERATORS`에 지정 (예: `["advanced-cluster-management|advanced-cluster-management.v2.12.1"]`).
- **카탈로그 데이터**: 채널과 버전 메타데이터를 포함한 JSON 파일.
- **출력**: `mirror.operators` 아래 `catalog`, `packages`, `channels`, `minVersion`을 포함한 `imageset-config.yaml`.

## 경우의 수 분석

스크립트는 오퍼레이터 정의 방식과 버전-채널 관계에 따라 다양한 경우를 처리합니다. 아래는 각 경우의 조건, 스크립트 동작, 그리고 생성된 YAML 출력입니다.

### 1. 오퍼레이터 정의에 따른 경우

#### 1.1. 오퍼레이터 이름만 지정
- **설명**: 버전 없이 오퍼레이터 이름만 지정 (예: `REDHAT_OPERATORS=["advanced-cluster-management"]`).
- **조건**:
  - `lc_operator_specified_versions`가 비어 있음 (`${#lc_operator_specified_versions[@]} -eq 0`).
  - 기본 채널(`lc_default_channel`) 존재.
- **스크립트 동작**:
  - 기본 채널을 YAML에 추가.
  - 다른 채널(`lc_different_channels`)이 존재하면, 가장 높은 버전의 채널(`lc_highest_channel_different_channel`)을 `lc_is_min_version_added`와 `lc_is_highest_channel_added`가 `false`일 때 추가.
  - `minVersion`은 설정되지 않음 (최신 버전 사용 가정).
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.13  # 기본 채널
    - name: release-2.12  # 가장 높은 버전의 다른 채널 (존재 시)
  ```
- **비고**:
  - 최소한 기본 채널이 포함됨.
  - 버전이 지정되지 않은 경우에만 높은 버전 채널 추가.

#### 1.2. 오퍼레이터 이름과 단일 버전
- **설명**: 오퍼레이터와 단일 버전 지정 (예: `REDHAT_OPERATORS=["advanced-cluster-management|advanced-cluster-management.v2.12.1"]`).
- **조건**:
  - `lc_operator_specified_versions=["advanced-cluster-management.v2.12.1"]`.
  - 버전은 기본 채널 또는 다른 채널에 존재 가능.
- **스크립트 동작**:
  - 지정된 버전을 기본 채널 버전(`lc_default_versions`)과 비교.
  - 일치하면 기본 채널에 `minVersion` 추가.
  - 기본 채널에 없고 다른 채널에 있으면 해당 채널에 `minVersion` 추가.
  - 버전이 없으면 기본 채널 추가.
- **YAML 출력** (버전이 기본 채널에 있는 경우):
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
      minVersion: '2.12.1'
  ```
- **비고**:
  - `get_extract_version`으로 `advanced-cluster-management.v2.12.1` → `2.12.1` 변환.
  - `get_string`으로 숫자 버전에 따옴표 추가 (`'2.12.1'`).

#### 1.3. 오퍼레이터 이름과 다중 버전
- **설명**: 오퍼레이터와 여러 버전 지정 (예: `REDHAT_OPERATORS=["advanced-cluster-management|advanced-cluster-management.v2.12.1|advanced-cluster-management.v2.11.0"]`).
- **조건**:
  - `lc_operator_specified_versions=["advanced-cluster-management.v2.12.1", "advanced-cluster-management.v2.11.0"]` (내림차순 정렬).
  - 버전은 여러 채널에 분산 가능.
- **스크립트 동작**:
  - 기본 채널에서 일치하는 버전(`lc_matching_versions`) 찾기.
  - 일치하면 가장 낮은 버전을 `minVersion`으로 기본 채널에 추가.
  - 남은 버전은 다른 채널에서 확인하여 일치하는 채널에 `minVersion` 추가.
- **YAML 출력** (버전이 여러 채널에 분산된 경우):
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
      minVersion: '2.12.1'
    - name: release-2.11
      minVersion: '2.11.0'
  ```
- **비고**:
  - 각 채널은 일치하는 가장 낮은 버전을 사용.
  - 일치하지 않는 버전은 경고 로그 출력.

### 2. 버전과 채널 관계에 따른 경우

#### 2.1. 지정된 버전이 기본 채널에 있는 경우
- **설명**: 지정된 버전이 기본 채널에 존재 (예: `advanced-cluster-management.v2.12.1`이 `release-2.12`에 있음).
- **조건**:
  - `lc_matching_versions`에 지정된 버전 포함.
- **스크립트 동작**:
  - 기본 채널에 지정된 버전을 `minVersion`으로 추가.
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
      minVersion: '2.12.1'
  ```
- **비고**:
  - 버전이 기본 채널과 정렬된 간단한 경우.

#### 2.2. 기본 채널에 지정된 버전이 여러 개 있는 경우
- **설명**: 기본 채널에 여러 지정된 버전 존재 (예: `advanced-cluster-management.v2.12.1`, `advanced-cluster-management.v2.12.0`이 `release-2.12`에 있음).
- **조건**:
  - `lc_matching_versions`에 여러 버전 포함.
- **스크립트 동작**:
  - 가장 낮은 버전(`sort -V | head -n 1`)을 `minVersion`으로 선택.
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
      minVersion: '2.12.0'
  ```
- **비고**:
  - 가장 이른 호환 버전 사용 보장.

#### 2.3. 지정된 버전이 기본 채널에 없고 다른 채널에 있는 경우
- **설명**: 지정된 버전이 기본 채널에 없고 다른 채널에 존재 (예: `advanced-cluster-management.v2.11.0`이 `release-2.11`에 있음, `release-2.12`에는 없음).
- **조건**:
  - 기본 채널의 `lc_matching_versions`가 비어 있음.
  - 다른 채널의 `lc_matching_versions_channel`에 버전 포함.
- **스크립트 동작**:
  - 기본 채널 추가 (`minVersion` 없이).
  - 일치하는 채널에 `minVersion` 추가.
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
    - name: release-2.11
      minVersion: '2.11.0'
  ```
- **비고**:
  - 기본 채널은 호환성을 위해 항상 포함.

#### 2.4. 지정된 버전이 카탈로그에 없는 경우
- **설명**: 지정된 버전이 어떤 채널에도 존재하지 않음 (예: `advanced-cluster-management.v2.10.0`).
- **조건**:
  - `lc_matching_versions`와 `lc_matching_versions_highest`가 비어 있음.
- **스크립트 동작**:
  - 기본 채널을 `minVersion` 없이 추가.
  - 남은 버전에 대해 경고 로그 출력:
    ```bash
    [WARN] Specified versions not found in catalog for operator 'advanced-cluster-management' in OCP 4.17.25 (only default channel 'release-2.12' available).
    [WARN] Remaining versions:
                advanced-cluster-management.v2.10.0
    [WARN] Please verify the version specifications in REDHAT_OPERATORS or check compatibility with OCP 4.17.25.
    ```
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
  ```
- **비고**:
  - 기본 채널로 폴백하여 최소 구성 보장.

#### 2.5. 기본 채널이 모든 지정된 버전을 포함하지만 다른 채널에 더 높은 버전이 있는 경우
- **설명**: 기본 채널에 모든 지정된 버전 포함 (예: `2.12.1`, `2.12.0`이 `release-2.12`에 있음), 다른 채널에 더 높은 버전 존재 (예: `2.13.0`이 `release-2.13`에 있음).
- **조건**:
  - `lc_matching_versions`가 모든 지정된 버전 포함.
  - `lc_different_channels`에 더 높은 버전 채널(`release-2.13`) 포함.
- **스크립트 동작**:
  - 기본 채널에 가장 낮은 `minVersion` 추가.
  - 더 높은 버전 채널은 지정된 버전이 없으므로 제외 (단, 버전 미지정 시 추가 가능).
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
      minVersion: '2.12.0'
  ```
- **비고**:
  - 버전이 지정된 경우 높은 버전 채널 제외.
  - 버전 미지정 시 높은 버전 채널 추가 가능.

### 3. 추가적인 경우

#### 3.1. 기본 채널과 동일한 버전 목록을 가진 채널
- **설명**: 기본 채널과 동일한 버전 목록을 가진 비기본 채널 존재 (예: `release-2.12`와 동일한 `stable-2.12`).
- **조건**:
  - `lc_identical_channels`에 일치하는 채널 포함.
- **스크립트 동작**:
  - 동일 채널을 로그에 기록하지만 YAML에는 추가하지 않음.
  - 로그 예시:
    ```bash
    [INFO] Channels with Identical Version List to Default Channel : stable-2.12
    ```
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
  ```
- **비고**:
  - 중복 채널 항목 방지.

#### 3.2. Candidate 채널 제외
- **설명**: 채널 이름이 `candidate`인 경우.
- **조건**:
  - `lc_channel == "candidate"`.
- **스크립트 동작**:
  - `lc_different_channels`에서 `candidate` 채널 제외.
- **YAML 출력**:
  - `candidate` 채널은 YAML에 포함되지 않음.
- **비고**:
  - 불안정한 채널 무시.

#### 3.3. 지정된 버전 없고 다른 채널도 없는 경우
- **설명**: 버전 미지정, 기본 채널만 존재.
- **조건**:
  - `lc_different_channels`가 비어 있음.
- **스크립트 동작**:
  - 기본 채널만 추가.
- **YAML 출력**:
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
  ```
- **비고**:
  - 최소 구성의 가장 간단한 경우.

#### 3.4. 카탈로그 파일 누락 또는 비어 있음
- **설명**: 카탈로그 파일(`catalog.json` 또는 `index.json`)이 없거나 비어 있음.
- **조건**:
  - `lc_catalog_file`이 존재하지 않거나 비어 있음.
- **스크립트 동작**:
  - 오퍼레이터를 건너뛰고 경고 로그 출력:
    ```bash
    [WARN] No catalog file found for operator 'advanced-cluster-management' at /path/to/catalog.json. Skipping...
    ```
- **YAML 출력**:
  - 해당 오퍼레이터는 YAML에 포함되지 않음.
- **비고**:
  - 잘못된 카탈로그 데이터에 대한 강력한 에러 처리.

#### 3.5. 기본 채널이 가장 높은 버전을 가지지 않은 경우
- **설명**: 기본 채널보다 다른 채널이 더 높은 버전 포함 (예: `release-2.12` vs. `release-2.13`).
- **조건**:
  - `lc_check_highest_default_channel`가 `lc_default_channel`과 다름.
- **스크립트 동작**:
  - 지정된 버전이 없거나 버전이 일치하면 가장 높은 채널 추가.
- **YAML 출력** (버전 미지정 시):
  ```yaml
  - name: advanced-cluster-management
    channels:
    - name: release-2.12
    - name: release-2.13
  ```
- **비고**:
  - 호환성을 유지하면서 더 높은 버전 허용.

## 요약 표

| **오퍼레이터 정의** | **버전-채널 관계** | **스크립트 동작** |
|---------------------|--------------------|-------------------|
| 이름만 지정 | 기본 채널만 존재 | 기본 채널 추가 |
| 이름만 지정 | 기본 + 더 높은 버전 채널 | 기본 + 가장 높은 채널 추가 |
| 단일 버전 | 기본 채널에 버전 존재 | 기본 채널에 `minVersion` 추가 |
| 단일 버전 | 다른 채널에 버전 존재 | 기본 + 일치 채널에 `minVersion` 추가 |
| 단일 버전 | 카탈로그에 버전 없음 | 기본 채널 추가, 경고 로그 |
| 다중 버전 | 기본 채널에 일부/전체 포함 | 기본 채널에 가장 낮은 `minVersion` 추가 |
| 다중 버전 | 여러 채널에 분산 | 기본 + 일치 채널에 `minVersion` 추가 |
| 다중 버전 | 일부 버전 없음 | 일치 채널 추가, 경고 로그 |
| 다중 버전 | 기본 채널에 모두 포함, 다른 채널에 더 높은 버전 | 기본 채널에 `minVersion`, 높은 채널 제외 |
| 모두 | 동일 버전 목록 채널 | 기본 채널 추가, 동일 채널 로그 |
| 모두 | Candidate 채널 | `candidate` 채널 제외 |
| 모두 | 카탈로그 파일 누락 | 오퍼레이터 제외, 경고 로그 |

## 추가 참고

- **로그 출력**: 원시 및 추출된 버전, 일치/남은 버전, YAML 생성 단계를 포함한 상세 로그로 디버깅 지원.
- **제한사항**:
  - `candidate` 채널은 항상 제외되어 불안정 버전 처리 불가.
  - 일치하지 않는 버전은 경고만 출력하며 대체 버전 제안 없음.
  - `get_properties_version`은 사용되지 않으나 버전 메타데이터 활용 가능.
- **확장 가능성**:
  - 버전 범위 지원 또는 최신 버전 자동 선택 추가 가능.
  - 잘못된 버전 형식에 대한 에러 처리 개선 가능.

## 결론

스크립트는 오퍼레이터 버전 경우를 포괄적으로 처리하며 다음을 고려하여 작성 하였습니다.
- 호환성을 위한 기본 채널 포함.
- 지정된 버전에 대한 정확한 `minVersion` 설정.
- 여러 채널에 걸친 버전에 대한 적절한 채널 추가.
- 일치하지 않는 경우에 알림.
