# Implementation Tasks (TDD & E2E Focused)

## Phase 1: Environment & Database Setup
- [x] **Test**: DB 스키마 생성 및 초기값 입력 테스트 코드 작성
- [x] 프로젝트 디렉토리 구조 생성 (bin, logs, sql)
- [x] SQLite3 데이터베이스 초기화 스크립트 (`init_db.sql`) 작성
  - [x] `config`, `services`, `jobs` 테이블 생성
- [x] DB 접근 전용 유틸리티 함수 (`db_query.sh`) 작성
- [x] **E2E**: DB 초기화 및 기본 쿼리 동작 확인

## Phase 2: Resource Monitoring Module
- [x] **Test**: 모의 데이터 기반 리소스 계산 오류 상황 테스트 (CPU 100%, Disk Full 등)
- [x] CPU/Memory/Disk/Process 사용율 계산 로직 구현
- [x] 리소스 체크 통합 함수 작성 (70% 임계치 판단)
- [x] **E2E**: 실제 시스템 지표 수집 및 임계치 판단 엔진 검증

## Phase 3: Scheduler Core Logic
- [x] **Test**: 시간대별(수행시간 내/외) 실행 시나리오 테스트 코드 작성
- [x] 현재 시간 기반 실행 여부 판단 로직 구현
- [x] 메인 루프 구현 (5분 주기) 및 서비스 순차 실행 로직
- [x] **E2E**: 가상 서비스(Docker 컨테이너)를 활용한 전체 스케줄링 흐름 검증

## Phase 7: Monitoring & UI Enhancement
- [x] `--status` 출력부 중복 컬럼(`Result`) 제거 및 `Message` 필드 매핑
- [x] 리소스 임계치 초과 시 다중 원인 및 기준 수치 로그 출력 개선
- [x] 작업 조회 및 초기화 기간 확장 (20h -> 23h) 일괄 적용

## Phase 4: CLI Interface (`--status`)
- [x] **Test**: 다양한 DB 상태(진행중, 완료, 실패)에 따른 출력 형식 검증 테스트
- [x] `--status` 인자 처리 및 요약 출력 기능 구현
- [x] **E2E**: 실제 스케줄러 구동 중에 별도 세션에서 `--status` 명령 실행 및 결과 정합성 확인

## Phase 5: Final Verification
- [x] 전체 시스템 통합 E2E 테스트 (70개 서비스 시뮬레이션)
- [x] 리소스 고부하 상황에서의 대기 및 재개 메커니즘 최종 검증
- [x] 예외 상황(DB 잠김, Docker 에러 등) 복구 테스트

## Phase 6: Maintenance & Enhancement
- [x] **Test**: /proc 기반 프로세스 부하 계산 수식 검증 테스트
- [x] `/proc/stat` 및 `/proc/loadavg` 기반 프로세스 모니터링 로직 고도화
- [x] 모니터링 임계치 상세 조정 및 검증
- [x] **Feature**: 당일 작업 초기화 (`--init`) 옵션 구현
- [x] **Test**: `--init` 실행 후 스케줄러 재시작 동작 검증
- [x] **Feature**: 인덱싱 작업 단순 비동기 실행 및 고정 실행 간격(Interval) 보장
  - [x] 작업 유무에 관계없이 DB에 설정된 `check_interval`만큼 반드시 대기
  - [x] `run_indexing_task` 백그라운드 실행 (별도 개수 제한 없음)
- [x] **Stabilization**: SQLite 동시성 최적화 (WAL & Busy Timeout)
  - [x] `db_query.sh`에 `busy_timeout` 및 `WAL` 모드 적용
  - [x] 고부하 동시 쓰기 상황(Stress Test) 시나리오 작성
  - [x] 에러 발생 없을 때까지 반복 테스트 및 검증
