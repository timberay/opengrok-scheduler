# OpenGrok Index Scheduler

70개 이상의 OpenGrok 서비스 컨테이너를 효율적으로 인덱싱하기 위한 Bash 기반 인덱스 스케줄러입니다. 서버의 부하 상태를 실시간으로 모니터링하여 가용 리소스가 충분할 때만 작업을 수행하며, 지정된 야간 시간대에 순차적으로 작업을 관리합니다.

## 주요 기능

- **시간 기반 스케줄링**: 설정된 시간대 (예: 18:00 ~ 익일 06:00) 내에서만 인덱싱 작업 수행
- **실시간 설정 반영**: `config` 테이블의 값을 루프마다 로드하여 스케줄러 재시작 없이 설정 변경 가능 (임계치, 간격 등)
- **정밀한 리소스 모니터링**: 
  - **CPU**: `top`의 2회 반복 측정을 통해 순간적인 실제 부하 반영
  - **Memory**: 캐시/버퍼를 제외한 실질 가용 메모리(`available`) 기준 판단
  - **Network**: 인터페이스 속도 자동 감지 및 실시간 대역폭 사용률 계산
  - **Disk I/O**: `iostat` %util 및 Blocked Process 상태를 종합하여 검사
- **SQLite3 기반 관리**: 서비스 목록, 스케줄러 설정, 작업 로그 및 상태를 SQLite3 DB로 통합 관리
- **비동기 백그라운드 실행**: 인덱싱 작업을 백그라운드로 실행하여 여러 작업을 동시에 수행 가능 (리소스 상태에 따라 동적 시작)
- **고정 실행 간격 보장**: 작업 유무와 관계없이 설정된 `check_interval` 주기를 엄격히 준수하여 규칙적인 스캔 수행
- **SQLite3 동시성 최적화**: WAL(Write-Ahead Logging) 모드 및 Busy Timeout(10초)을 적용하여 다중 프로세스 접근 시 DB Lock 방지
- **상태 리포팅**: `--status` 명령어를 통해 처리 현황 및 통계 정보 요약 출력 (상태, 메시지 등).
- **독립적 구동**: 스케줄러가 백그라운드에서 실행 중이더라도 별도 세션에서 상태 확인 가능

## 프로젝트 구조

```text
opengrok-scheduler/
├── bin/
│   ├── scheduler.sh    # 메인 스케줄러 및 CLI 인터페이스
│   ├── monitor.sh      # 시스템 리소스 모니터링 모듈
│   └── db_query.sh     # SQLite3 쿼리 유틸리티
├── sql/
│   └── init_db.sql     # 데이터베이스 스키마 및 초기 설정
├── data/
│   └── scheduler.db    # 생성된 SQLite3 데이터베이스 파일
├── tests/              # TDD를 위한 단계별 테스트 스크립트
├── logs/               # 실행 로그 보관 디렉토리
├── README.md           # 프로젝트 가이드
├── ARCHITECTURE.md     # 상세 개발 설계서 (기존 SPEC.md)
└── TASK.md             # 구현 진행 기록
```

## 설치 및 시작하기

### 1. 사전 요구사항
- Bash Shell
- SQLite3, sysstat (iostat)
- Docker (인덱싱 대상 서비스가 컨테이너로 구동 중이어야 함)

### 2. 데이터베이스 초기화
```bash
mkdir -p data logs
sqlite3 data/scheduler.db < sql/init_db.sql
```

### 3. 서비스 등록
인덱싱이 필요한 도커 컨테이너들을 등록합니다.
```bash
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('opengrok-service-1', 10);"
./bin/db_query.sh "INSERT INTO services (container_name, priority) VALUES ('opengrok-service-2', 5);"
```

### 4. 스케줄러 실행
```bash
chmod +x bin/*.sh
./bin/scheduler.sh
```

## 사용 방법

### 특정 서비스 단독 실행 (--service)
스케줄 시간이나 리소스 상태와 관계없이 특정 컨테이너를 즉시 인덱싱합니다.
```bash
./bin/scheduler.sh --service opengrok-service-1
```

### 상태 확인 (--status)
현재 스케줄러의 진행 상황과 작업 이력을 요약하여 출력합니다.
```bash
./bin/scheduler.sh --status
```

### 작업 초기화 (--init)
최근 23시간 이내의 모든 작업 기록을 삭제하고 초기 상태로 만듭니다. (실수로 중단된 스케줄을 재시작할 때 사용)
```bash
./bin/scheduler.sh --init
```

### 설정 값 확인 및 변경
`config` 테이블을 통해 스케줄러 동작을 세밀하게 조정할 수 있습니다.

| Key | Description | Default |
|:---|:---|:---|
| `start_time` | 작업 시작 가능 시간 | `18:00` |
| `end_time` | 작업 종료 시간 | `06:00` |
| `resource_threshold` | 리소스 임계치 (%) | `70` |
| `check_interval` | 상태 체크 및 다음 작업 검색 주기 (초, 작업 유무와 상관없이 고정 대기) | `300` |
| `net_interface` | 모니터링 인터페이스 (자동 감지 가능) | - |
| `max_bandwidth` | 최대 대역폭 (Bytes/s, 속도 감지 실패 시 사용) | - |
| `disk_device` | I/O 모니터링 대상 디스크 (자동 감지 가능) | - |

```bash
# 임계치를 80%로 상향
./bin/db_query.sh "UPDATE config SET value='80' WHERE key='resource_threshold';"
```

## 테스트 실행
각 모듈의 정상 동작을 확인하려면 `tests/` 디렉토리의 스크립트를 실행합니다.
```bash
./tests/test_monitor.sh           # 리소스 모니터링 엔진 테스트
./tests/test_scheduler_logic.sh   # 시간대 및 대기 로직 테스트
./tests/test_status_output.sh     # CLI 출력 포맷 테스트
./tests/test_db_stress.sh        # DB 동시성 및 안정성 스트레스 테스트
```
