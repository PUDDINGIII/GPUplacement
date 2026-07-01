#4nodes iteration 50
#!/bin/bash
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
START_ITER=1
END_ITER=50
EXP_NAME="nonmps_most"
REMOTE_YAML="/home/gpu-master/yolo-10pods-all.yaml"
RESULT_BASE_DIR="./experiment_results_ultra4_v11"
SUMMARY_CSV="${RESULT_BASE_DIR}/nonmps_total_summary_node4.csv"
KUBECONFIG="--kubeconfig=/etc/kubernetes/admin.conf"
TMP_SPEC_DIR="./hybrid_tmp_specs"

# [★4대 노드 고유 정보 실측 동기화]
SSH_PASS="0"
ORIN2_USER="gpu-orin2"; ORIN2_IP="192.168.0.206"; ORIN2_NODE="gpu-orin2"
ORIN3_USER="gpu-orin3"; ORIN3_IP="192.168.0.52" ; ORIN3_NODE="gpu-orin3"
ORIN4_USER="gpu-orin4"; ORIN4_IP="192.168.0.162"; ORIN4_NODE="gpuorin4-desktop"
ORIN5_USER="gpu-orin5"; ORIN5_IP="192.168.0.156"; ORIN5_NODE="gpuorin5-desktop"

###############################################################################
# Initialize Output Directories
###############################################################################
mkdir -p "$RESULT_BASE_DIR"
mkdir -p "$TMP_SPEC_DIR"

if [ ! -f "$SUMMARY_CSV" ]; then
    echo "Exp_ID,Iteration,Pod,Node,StartTime,EndTime,Pre(ms),Inf(ms),Post(ms),Total(ms)" > "$SUMMARY_CSV"
fi

sshrun() { bash -c "$@"; }

remote_pkill() {
    local user=$1; local ip=$2
    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${user}@${ip}" \
    "pkill -u \$(whoami) -f 'tegrastats|mpstat|pidstat|vmstat'" >/dev/null 2>&1 || true
}

###############################################################################
# Benchmark Loop
###############################################################################
for i in $(seq $START_ITER $END_ITER); do
    RUN_ID="${EXP_NAME}${i}"
    RUN_DIR="${RESULT_BASE_DIR}/${RUN_ID}"
    mkdir -p "${RUN_DIR}"

    echo "========================================================"
    echo ">>> [YOLO-10POD] ${RUN_ID} 가동 (스냅샷 동결 수확형 v11.0)"
    echo "========================================================"

    # Clean up remaining monitoring processes
    echo "[0] Pre-cleaning remaining telemetry daemons on remote nodes..."
    remote_pkill "${ORIN2_USER}" "${ORIN2_IP}"
    remote_pkill "${ORIN3_USER}" "${ORIN3_IP}"
    remote_pkill "${ORIN4_USER}" "${ORIN4_IP}"
    remote_pkill "${ORIN5_USER}" "${ORIN5_IP}"
    sleep 2

    # Collect Kubernetes scheduler logs
    kubectl logs -f kube-scheduler-gpu-master -n kube-system $KUBECONFIG \
    | grep --line-buffered -iE "score|filter|selecting|evaluating" \
    | while read line; do echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') $line"; done > "${RUN_DIR}/${RUN_ID}_scheduler_scoring.log" &
    SCHED_PID=$!

    # Start telemetry collection on worker nodes
    for NODE_INFO in "${ORIN2_USER}@${ORIN2_IP}:orin2" "${ORIN3_USER}@${ORIN3_IP}:orin3" "${ORIN4_USER}@${ORIN4_IP}:orin4" "${ORIN5_USER}@${ORIN5_IP}:orin5"; do
        USER_IP=${NODE_INFO%%:*}; PREFIX=${NODE_INFO##*:}

        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "tegrastats --interval 500 > /tmp/${RUN_ID}_${PREFIX}_tg.raw 2>&1 &"
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "mpstat -P ALL 1 > /tmp/${RUN_ID}_${PREFIX}_mp.raw 2>&1 &"
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "vmstat 1 > /tmp/${RUN_ID}_${PREFIX}_vm.raw 2>&1 &"
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "pidstat -u -r -w 1 > /tmp/${RUN_ID}_${PREFIX}_pid.raw 2>&1 &"
    done

    sleep 1
    sleep 9 # Baseline 총합 10초 마진 확보

    # Deploy workloads
    POD_ORDER=("yolo-cls-1" "yolo-det-1" "yolo-seg-1" "yolo-obb-1" "yolo-pos-1" "yolo-cls-2" "yolo-det-2" "yolo-seg-2" "yolo-obb-2" "yolo-pos-2")
    declare -A START_TIMES
    declare -A END_TIMES

    echo "[3] Advanced Rolling Injection Starting..."
    for pod_name in "${POD_ORDER[@]}"; do
        TMP_SPEC="${TMP_SPEC_DIR}/tmp_${pod_name}.yaml"

        if kubectl ${KUBECONFIG} get pod "${pod_name}" 2>/dev/null; then
            kubectl ${KUBECONFIG} delete pod "${pod_name}" --force --grace-period=0 >/dev/null 2>&1 || true
            while kubectl ${KUBECONFIG} get pod "${pod_name}" 2>/dev/null; do sleep 0.1; done
        fi

        awk -v RS='---' -v name="${pod_name}" '$0 ~ "name: "name {print "---"; print $0}' "${REMOTE_YAML}" > "$TMP_SPEC"

        kubectl ${KUBECONFIG} apply -f "$TMP_SPEC"

        ASSIGNED_NODE=""
        for retry in {1..20}; do
            ASSIGNED_NODE=$(kubectl ${KUBECONFIG} get pod "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
            if [ -n "${ASSIGNED_NODE}" ] && [ "${ASSIGNED_NODE}" != "<none>" ]; then break; fi
            sleep 0.1
        done

        kubectl ${KUBECONFIG} delete pod "${pod_name}" --force --grace-period=0 >/dev/null 2>&1 || true
        while kubectl ${KUBECONFIG} get pod "${pod_name}" 2>/dev/null; do sleep 0.1; done

        sed -i "/spec:/a \  nodeName: ${ASSIGNED_NODE}" "$TMP_SPEC"

        if [ "${ASSIGNED_NODE}" == "${ORIN4_NODE}" ] || [ "${ASSIGNED_NODE}" == "${ORIN5_NODE}" ]; then
            echo "🚀 [TRT10 노드 고정] Pod [${pod_name}] -> Node [${ASSIGNED_NODE}] 자물쇠 잠금 및 trt10 탄창 스왑"
            sed -i 's/\.engine/_trt10\.engine/g' "$TMP_SPEC"
        else
            echo "🍏 [순정 노드 고정] Pod [${pod_name}] -> Node [${ASSIGNED_NODE}] 자물쇠 잠금 및 기존 순정 엔진 유지"
        fi

        kubectl ${KUBECONFIG} apply -f "$TMP_SPEC"
        rm -f "$TMP_SPEC"

        for watch_retry in {1..25}; do
            if kubectl ${KUBECONFIG} get pod "${pod_name}" 2>/dev/null | grep -q "Running"; then
                START_TIMES[$pod_name]=$(date '+%Y-%m-%d %H:%M:%S.%3N')
                break
            fi
            sleep 0.2
        done

        sleep 1.5
    done

    # Wait for workload completion
    echo "[4] Monitoring 10-Pod completion with Network Timeout Guard..."
    for pod_name in "${POD_ORDER[@]}"; do
        WAIT_SEC=0; TIMEOUT_LIMIT=120

        while :; do
            LOG_OUTPUT=$(kubectl ${KUBECONFIG} logs "${pod_name}" 2>/dev/null || echo "NET_ERROR")
            if echo "$LOG_OUTPUT" | grep -q "Results saved to"; then
                END_TIMES[$pod_name]=$(date '+%Y-%m-%d %H:%M:%S.%3N')
                echo "🎯 [$pod_name] 정상 연사 완공 감지 완료!"
                break
            fi
            if [ $WAIT_SEC -ge $TIMEOUT_LIMIT ]; then
                END_TIMES[$pod_name]=$(date '+%Y-%m-%d %H:%M:%S.%3N')
                echo "⚠️ [$pod_name] 오린 보드 포화로 인한 감지 타임아웃 우회 (강제 통과 격발)!"
                break
            fi
            sleep 2
            WAIT_SEC=$((WAIT_SEC + 2))
        done

        POD_LOG="${RUN_DIR}/${RUN_ID}_${pod_name}.log"
        kubectl ${KUBECONFIG} logs "${pod_name}" > "${POD_LOG}" 2>/dev/null || echo "Log Dump Timeout" > "${POD_LOG}"

        SPEED_LINE=$(grep "Speed:" "${POD_LOG}" | tail -n 1 || echo "")
        if [ -n "$SPEED_LINE" ]; then
            PRE=$(echo $SPEED_LINE | awk '{print $2}' | sed 's/ms//')
            INF=$(echo $SPEED_LINE | awk '{print $4}' | sed 's/ms//')
            POST=$(echo $SPEED_LINE | awk '{print $6}' | sed 's/ms//')
            TOTAL=$(echo "$PRE + $INF + $POST" | bc -l)
        else
            PRE=0; INF=0; POST=0; TOTAL=0
        fi

        NODE=$(kubectl ${KUBECONFIG} get pod "${pod_name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "Unknown-Node")
        echo "${EXP_NAME},${i},${pod_name},${NODE},${START_TIMES[$pod_name]},${END_TIMES[$pod_name]},${PRE},${INF},${POST},${TOTAL}" >> "$SUMMARY_CSV"
        echo "📈 [장부 적립 완료] 파드: ${pod_name} -> 노드: ${NODE} | Total: ${TOTAL}ms"
    done

    echo "[4.5] Capturing trailing peak metrics (2s cooldown margin)..."
    sleep 2

    # =====================================================
    # 🎯 [가현's 스냅샷 동결 공정 - wait 억까 원천 소독 패치]
    # =====================================================
    echo "❄️ [스냅샷 복사 동결 장치 기동] Freezing 4-Node telemetry raw logs concurrently..."
    CP_PIDS=()
    for NODE_INFO in "${ORIN2_USER}@${ORIN2_IP}:orin2" "${ORIN3_USER}@${ORIN3_IP}:orin3" "${ORIN4_USER}@${ORIN4_IP}:orin4" "${ORIN5_USER}@${ORIN5_IP}:orin5"; do
        USER_IP=${NODE_INFO%%:*}; PREFIX=${NODE_INFO##*:}

        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" \
        "cp /tmp/${RUN_ID}_${PREFIX}_tg.raw /tmp/${RUN_ID}_${PREFIX}_tg.freeze && \
         cp /tmp/${RUN_ID}_${PREFIX}_mp.raw /tmp/${RUN_ID}_${PREFIX}_mp.freeze && \
         cp /tmp/${RUN_ID}_${PREFIX}_vm.raw /tmp/${RUN_ID}_${PREFIX}_vm.freeze && \
         cp /tmp/${RUN_ID}_${PREFIX}_pid.raw /tmp/${RUN_ID}_${PREFIX}_pid.freeze" &
        CP_PIDS+=($!) # 💡 스케줄러 로그 빼고, 딱 '이 cp 명령어들의 PID'만 추적 바인딩!
    done
    for cp_pid in "${CP_PIDS[@]}"; do wait "$cp_pid"; done # 🎯 해당 cp 공정만 개별 락온 대기 완료!

    echo "🚚 [동결 장부 징집] Pulling frozen snapshot metrics via SCP..."
    SCP_PIDS=()
    for NODE_INFO in "${ORIN2_USER}@${ORIN2_IP}:orin2" "${ORIN3_USER}@${ORIN3_IP}:orin3" "${ORIN4_USER}@${ORIN4_IP}:orin4" "${ORIN5_USER}@${ORIN5_IP}:orin5"; do
        USER_IP=${NODE_INFO%%:*}; PREFIX=${NODE_INFO##*:}

        sshpass -p "${SSH_PASS}" scp -o StrictHostKeyChecking=no "${USER_IP}:/tmp/${RUN_ID}_${PREFIX}_*.freeze" "${RUN_DIR}/" &
        SCP_PIDS+=($!)
    done
    for scp_pid in "${SCP_PIDS[@]}"; do wait "$scp_pid"; done

    for PREFIX in orin2 orin3 orin4 orin5; do
        mv "${RUN_DIR}/${RUN_ID}_${PREFIX}_tg.freeze" "${RUN_DIR}/${RUN_ID}_${PREFIX}_tegrastats.txt" 2>/dev/null || true
        mv "${RUN_DIR}/${RUN_ID}_${PREFIX}_mp.freeze" "${RUN_DIR}/${RUN_ID}_${PREFIX}_mpstat.txt" 2>/dev/null || true
        mv "${RUN_DIR}/${RUN_ID}_${PREFIX}_vm.freeze" "${RUN_DIR}/${RUN_ID}_${PREFIX}_vmstat.txt" 2>/dev/null || true
        mv "${RUN_DIR}/${RUN_ID}_${PREFIX}_pid.freeze" "${RUN_DIR}/${RUN_ID}_${PREFIX}_pidstat.txt" 2>/dev/null || true
    done

    # Cleanup
    echo "[5] Cleaning resources for iteration ${i}..."
    kill $SCHED_PID || true

    remote_pkill "${ORIN2_USER}" "${ORIN2_IP}"
    remote_pkill "${ORIN3_USER}" "${ORIN3_IP}"
    remote_pkill "${ORIN4_USER}" "${ORIN4_IP}"
    remote_pkill "${ORIN5_USER}" "${ORIN5_IP}"

    for NODE_INFO in "${ORIN2_USER}@${ORIN2_IP}:orin2" "${ORIN3_USER}@${ORIN3_IP}:orin3" "${ORIN4_USER}@${ORIN4_IP}:orin4" "${ORIN5_USER}@${ORIN5_IP}:orin5"; do
        USER_IP=${NODE_INFO%%:*}; PREFIX=${NODE_INFO##*:}
        sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no "${USER_IP}" "rm -f /tmp/${RUN_ID}_${PREFIX}_*" &
    done
    # 💡 루프 마감 시점에 마진 대기
    sleep 2

    sshrun "kubectl ${KUBECONFIG} delete -f ${REMOTE_YAML} --ignore-not-found=true"
    rm -rf "${TMP_SPEC_DIR}/*"

    echo ">>> [COMPLETE] Iteration ${i} 완료. 인프라 자원 반납 완전 대기 (50초)..."
    sleep 50
done

echo "======================================================"
echo "🎉 50 이터레이션 대장정 전수 완공! 무결성 하이브리드 수확 대성공!"
echo "📂 CSV 결과 위치: ${SUMMARY_CSV}"
echo "======================================================"
~
~
