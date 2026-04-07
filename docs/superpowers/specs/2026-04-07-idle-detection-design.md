# Idle Detection with Process Tree CPU Sampling

## Context

배치 잡 스케줄러에서 실행 중인 프로세스의 idle 상태를 감지해야 한다. 현재 `get_process_state()` 함수는 부모 프로세스의 `/proc/<PID>/status`만 확인하기 때문에, 부모가 자식 프로세스(Docker exec, CLI 도구 등)를 호출하고 대기 중일 때 실제로는 작업이 진행 중임에도 부모가 SLEEPING 상태로 보여 idle로 오판하는 문제가 있다.

`JOB_IDLE_TIMEOUT` 설정은 `.env.example`에 정의되어 있고, `tests/test_idle_timeout.sh` 테스트도 존재하지만, 실제 idle 감지 로직은 아직 구현되지 않았다.

## 목표

- 부모 + 자식 프로세스 트리 전체의 CPU 활동을 기반으로 정확한 idle 판단
- `JOB_IDLE_TIMEOUT` 동안 진짜 idle이면 TIMEOUT 상태로 전환 및 프로세스 트리 종료
- 기존 코드 구조(`reap_bg_processes()` 루프)를 활용한 자연스러운 통합

## 설계

### 1. 프로세스 트리 CPU 시간 수집

**새 함수: `get_tree_cpu_time(PID)`** — `bin/monitor.sh`에 추가

1. `get_descendant_pids(PID)`: 부모 PID로부터 전체 자손 프로세스를 재귀적으로 수집 (`pgrep -P` 사용)
2. 각 프로세스의 `/proc/<PID>/stat`에서 14번째(utime)와 15번째(stime) 필드 읽기
3. 부모 포함 모든 프로세스의 utime + stime 합산하여 반환 (단위: jiffies)
4. 프로세스가 이미 종료된 경우 0 반환 (에러 무시)

```
get_descendant_pids(PID):
    children = pgrep -P $PID
    for child in children:
        result += child
        result += get_descendant_pids(child)
    return result

get_tree_cpu_time(PID):
    total = 0
    for pid in [PID] + get_descendant_pids(PID):
        stat = read /proc/$pid/stat
        utime = field 14
        stime = field 15
        total += utime + stime
    return total
```

### 2. Idle 판단 로직

**수정 대상: `reap_bg_processes()`** — `bin/scheduler.sh:188-248`

새로운 상태 추적용 연관 배열 추가:
- `BG_LAST_CPU["$CONTAINER_NAME"]` — 마지막 샘플의 CPU 시간 합계
- `BG_IDLE_SINCE["$CONTAINER_NAME"]` — idle 시작 epoch (0이면 활동 중)

매 호출 시 로직:

```
current_cpu = get_tree_cpu_time(PID)

if current_cpu != BG_LAST_CPU[name]:
    BG_IDLE_SINCE[name] = 0              # 활동 중 → 리셋
elif current_cpu == 0 && PID still exists:
    # 프로세스는 있지만 CPU 시간 0 → 아직 시작 전일 수 있으므로 스킵
    pass
else:
    if BG_IDLE_SINCE[name] == 0:
        BG_IDLE_SINCE[name] = $(date +%s)  # idle 시작 기록
    else:
        elapsed = now - BG_IDLE_SINCE[name]
        if elapsed >= JOB_IDLE_TIMEOUT:
            → 프로세스 트리 종료
            → DB 업데이트: status=TIMEOUT, message="Idle timeout after ${elapsed}s"

BG_LAST_CPU[name] = current_cpu
```

### 3. 프로세스 트리 종료

idle timeout 발생 시 프로세스 트리 전체를 안전하게 종료:

1. `get_descendant_pids(PID)`로 자손 목록 수집
2. 역순(leaf → root)으로 SIGTERM 전송
3. 5초 대기 후 아직 살아있는 프로세스에 SIGKILL
4. DB 업데이트: `status='TIMEOUT'`, `message='Idle timeout after {N}s'`
5. `BG_PIDS`, `BG_LAST_CPU`, `BG_IDLE_SINCE`에서 해당 항목 제거

### 4. 설정

- `JOB_IDLE_TIMEOUT` 환경변수 사용 (기본값: 300초, `.env.example`에 이미 정의됨)
- `JOB_IDLE_TIMEOUT=0`이면 idle 감지 비활성화
- 샘플링 주기: `reap_bg_processes()` 기존 호출 주기를 그대로 사용 (별도 타이머 불필요)

### 5. 수정 대상 파일

| 파일 | 수정 내용 |
|------|-----------|
| `bin/monitor.sh` | `get_descendant_pids()`, `get_tree_cpu_time()` 함수 추가 |
| `bin/scheduler.sh` | `BG_LAST_CPU`, `BG_IDLE_SINCE` 배열 선언, `reap_bg_processes()`에 idle 감지 로직 통합, 프로세스 트리 종료 함수 추가 |
| `tests/test_idle_timeout.sh` | 실제 구현에 맞게 테스트 보완 |

### 6. 테스트 계획

기존 `tests/test_idle_timeout.sh`를 보완:

- **TC1: 진짜 idle 프로세스** — 자식 프로세스 없이 sleep만 하는 작업 → idle timeout 발생, status=TIMEOUT, message에 "Idle" 포함 확인
- **TC2: 활동 중인 자식 프로세스** — 자식이 CPU를 사용하는 작업 → idle timeout 미발생 확인
- **TC3: 자식 종료 후 부모만 남은 경우** — 자식 프로세스가 끝난 후 부모가 idle → idle timeout 발생 확인
- **TC4: JOB_IDLE_TIMEOUT=0** — idle 감지 비활성화 확인

### 7. 기존 코드 재사용

- `get_process_state()` (`monitor.sh:258-276`) — 기존 프로세스 상태 확인은 그대로 유지
- `reap_bg_processes()` (`scheduler.sh:188-248`) — 기존 루프 구조에 idle 감지를 추가
- `run_indexing_task()` (`scheduler.sh:64-77`) — 변경 없음
- `.env.example`의 `JOB_IDLE_TIMEOUT=300` — 이미 정의됨, 그대로 사용
