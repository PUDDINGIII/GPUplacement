#!/bin/bash
###############################################################################
#
# VIGIA Scheduler
#
# Vigilant Intelligent GPU Inference Allocator
#
# Hardware-Aware GPU Scheduling Framework for Kubernetes
#
# Description
# ----------
# VIGIA collects runtime hardware telemetry from worker nodes,
# computes a hardware-aware penalty score,
# selects the optimal worker node,
# injects nodeName into the Pod manifest,
# and deploys AI inference workloads.
#
###############################################################################

set -euo pipefail

###############################################################################
# Experiment Configuration
###############################################################################

START_ITER=1
END_ITER=50

EXP_NAME="vigia"

REMOTE_YAML="/home/gpu-master/yolo-5pods-all.yaml"

RESULT_DIR="./results"

SUMMARY_CSV="${RESULT_DIR}/vigia_summary.csv"

KUBECONFIG="--kubeconfig=/etc/kubernetes/admin.conf"

###############################################################################
# Worker Node Information
###############################################################################

SSH_PASS="0"

ORIN2_USER="gpu-orin2"
ORIN2_IP="192.168.0.254"

ORIN3_USER="gpu-orin3"
ORIN3_IP="192.168.0.216"

###############################################################################
# Model Sensitivity (θ)
###############################################################################

declare -A MODEL_THETA=(

["yolo-cls"]=1.00
["yolo-seg"]=1.84
["yolo-pos"]=2.24
["yolo-det"]=2.38
["yolo-obb"]=3.18

)

###############################################################################
# Penalty Weights
###############################################################################

W_CS=0.40
W_POWER=0.35
W_TEMP=0.10

###############################################################################
# Initialize Result Directory
###############################################################################

mkdir -p "${RESULT_DIR}"

if [ ! -f "${SUMMARY_CSV}" ]; then

echo "Experiment,Iteration,Pod,Node,Start,End,Pre,Inference,Post,Total" \
> "${SUMMARY_CSV}"

fi

###############################################################################
# Utility Functions
###############################################################################

timestamp() {

date '+%Y-%m-%d %H:%M:%S.%3N'

}

log() {

echo "[$(timestamp)] $1"

}

###############################################################################
# Cleanup Monitoring Processes
###############################################################################

remote_cleanup() {

local USER=$1
local IP=$2

sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER}@${IP}" \
"pkill -u \$(whoami) -f 'tegrastats|vmstat|pidstat|mpstat'" \
>/dev/null 2>&1 || true

}

###############################################################################
# Runtime Hardware Metric Collection
###############################################################################

collect_metrics() {

local USER=$1
local IP=$2

###############################################################################
# Collect tegrastats
###############################################################################

local STATS

STATS=$(sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER}@${IP}" \
"tegrastats --interval 200 | head -n 2 | tail -n 1")

###############################################################################
# Extract Power
###############################################################################

local POWER

POWER=$(echo "${STATS}" \
| grep -Po 'POM_5V_IN \K[0-9]+' \
|| echo 3000)

###############################################################################
# Extract Temperature
###############################################################################

local TEMP

TEMP=$(echo "${STATS}" \
| grep -Po 'thermal BCM@\K[0-9.]+' \
|| echo 40)

###############################################################################
# Context Switching
###############################################################################

local CS

CS=$(sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER}@${IP}" \
"vmstat 1 2 | tail -n 1 | awk '{print \$12}'")

###############################################################################
# Disk Usage
###############################################################################

local DISK

DISK=$(sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER}@${IP}" \
"df / --output=pcent | tail -n 1 | tr -dc '0-9'")

echo "${POWER},${TEMP},${CS},${DISK}"

}

###############################################################################
# Hardware-aware Penalty Calculation
###############################################################################

calculate_penalty() {

local MODEL=$1
local POWER=$2
local TEMP=$3
local CS=$4

local THETA=${MODEL_THETA[$MODEL]}

local PENALTY

PENALTY=$(echo "

${THETA} * (

${W_CS} * ${CS} / 1000 +

${W_POWER} * ${POWER} / 10000 +

${W_TEMP} * ${TEMP} / 100

)

" | bc -l)

echo "${PENALTY}"

}

###############################################################################
# VIGIA Scheduler
###############################################################################

select_vigia_node() {

local MODEL=$1

local SCORE_LOG="${RUN_DIR}/${RUN_ID}_vigia_scoring.log"

echo "===================================================" >> "${SCORE_LOG}"
echo "Scheduling ${MODEL}" >> "${SCORE_LOG}"
echo "===================================================" >> "${SCORE_LOG}"

local BEST_NODE=""
local MIN_SCORE=999999999

for NODE in \
"${ORIN2_USER}@${ORIN2_IP}:gpu-orin2" \
"${ORIN3_USER}@${ORIN3_IP}:gpu-orin3"

do

USER_IP=${NODE%%:*}
NODE_NAME=${NODE##*:}

###############################################################################
# Collect Runtime Metrics
###############################################################################

IFS=',' read POWER TEMP CS DISK <<< \
$(collect_metrics "${USER_IP%@*}" "${USER_IP#*@}")

###############################################################################
# Disk Filter
###############################################################################

if [ "${DISK}" -ge 90 ]; then

echo "$(timestamp) ${NODE_NAME} skipped (Disk=${DISK}%)" \
>> "${SCORE_LOG}"

continue

fi

###############################################################################
# Compute Penalty
###############################################################################

PENALTY=$(calculate_penalty \
"${MODEL}" \
"${POWER}" \
"${TEMP}" \
"${CS}")

###############################################################################
# Logging
###############################################################################

echo "$(timestamp)

Node        : ${NODE_NAME}

Power       : ${POWER}

Temperature : ${TEMP}

Context Sw. : ${CS}

Penalty     : ${PENALTY}

" >> "${SCORE_LOG}"

###############################################################################
# Select Minimum Penalty
###############################################################################

if (( $(echo "${PENALTY} < ${MIN_SCORE}" | bc -l) ))

then

MIN_SCORE=${PENALTY}

BEST_NODE=${NODE_NAME}

fi

done

echo "Selected Node : ${BEST_NODE}" >> "${SCORE_LOG}"

echo "${BEST_NODE}"

}

###############################################################################
# Deploy Pod
###############################################################################

deploy_pod() {

local POD=$1
local NODE=$2

log "Deploying ${POD} on ${NODE}"

###############################################################################
# Remove Existing Pod
###############################################################################

kubectl delete pod "${POD}" \
--force \
--grace-period=0 \
>/dev/null 2>&1 || true

###############################################################################
# Inject nodeName
###############################################################################

awk -v RS='---' \
-v pod="${POD}" \
-v node="${NODE}" '

$0 ~ "name: "pod {

printf "---\n"

split($0, lines, "\n")

for(i=1;i<=length(lines);i++){

print lines[i]

if(lines[i] ~ /^spec:/){

print "  nodeName: " node

}

}

}

' "${REMOTE_YAML}" | kubectl apply -f -

}

###############################################################################
# Wait Until Inference Finishes
###############################################################################

wait_for_completion() {

local POD=$1

while true

do

if kubectl logs "${POD}" 2>/dev/null \
| grep -q "Results saved to"

then

break

fi

sleep 3

done

}

###############################################################################
# Save Experiment Result
###############################################################################

save_result() {

local POD=$1

local START=$2

local END

END=$(timestamp)

LOGFILE="${RUN_DIR}/${RUN_ID}_${POD}.log"

kubectl logs "${POD}" > "${LOGFILE}"

###############################################################################
# Parse TensorRT Speed
###############################################################################

SPEED=$(grep "Speed:" "${LOGFILE}" | tail -1)

PRE=$(echo "${SPEED}" | awk '{print $2}' | sed 's/ms//')

INF=$(echo "${SPEED}" | awk '{print $4}' | sed 's/ms//')

POST=$(echo "${SPEED}" | awk '{print $6}' | sed 's/ms//')

TOTAL=$(echo "${PRE}+${INF}+${POST}" | bc)

NODE=$(kubectl get pod "${POD}" \
-o custom-columns=NODE:.spec.nodeName \
--no-headers)

###############################################################################
# Save CSV
###############################################################################

echo "${EXP_NAME},

${ITER},

${POD},

${NODE},

${START},

${END},

${PRE},

${INF},

${POST},

${TOTAL}" \
| tr -d '\n' \
| sed 's/, */,/g' \
>> "${SUMMARY_CSV}"

echo >> "${SUMMARY_CSV}"

}

###############################################################################
# Main Experiment Loop
###############################################################################

PODS=(

yolo-cls
yolo-det
yolo-seg
yolo-obb
yolo-pos

)

for ITER in $(seq ${START_ITER} ${END_ITER})

do

RUN_ID="${EXP_NAME}_${ITER}"

RUN_DIR="${RESULT_DIR}/${RUN_ID}"

mkdir -p "${RUN_DIR}"

log "========================================================"
log "Starting Experiment ${ITER}"
log "========================================================"

###############################################################################
# Start Hardware Monitoring
###############################################################################

for NODE in \
"${ORIN2_USER}@${ORIN2_IP}:orin2" \
"${ORIN3_USER}@${ORIN3_IP}:orin3"

do

USER_IP=${NODE%%:*}

PREFIX=${NODE##*:}

sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER_IP}" \
"tegrastats --interval 500" \
> "${RUN_DIR}/${PREFIX}_tegrastats.log" 2>&1 &

sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER_IP}" \
"vmstat 1" \
> "${RUN_DIR}/${PREFIX}_vmstat.log" 2>&1 &

sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER_IP}" \
"pidstat -u -r -w 1" \
> "${RUN_DIR}/${PREFIX}_pidstat.log" 2>&1 &

sshpass -p "${SSH_PASS}" \
ssh -o StrictHostKeyChecking=no "${USER_IP}" \
"mpstat -P ALL 1" \
> "${RUN_DIR}/${PREFIX}_mpstat.log" 2>&1 &

done

###############################################################################
# Baseline Stabilization
###############################################################################

sleep 10

###############################################################################
# Deploy Pods
###############################################################################

declare -A START_TIME

for POD in "${PODS[@]}"

do

START_TIME[$POD]=$(timestamp)

NODE=$(select_vigia_node "${POD}")

log "${POD} -> ${NODE}"

deploy_pod "${POD}" "${NODE}"

sleep 5

done

###############################################################################
# Wait for Completion
###############################################################################

for POD in "${PODS[@]}"

do

wait_for_completion "${POD}"

save_result "${POD}" "${START_TIME[$POD]}"

done

###############################################################################
# Cleanup
###############################################################################

log "Cleaning resources..."

remote_cleanup "${ORIN2_USER}" "${ORIN2_IP}"

remote_cleanup "${ORIN3_USER}" "${ORIN3_IP}"

kubectl delete -f "${REMOTE_YAML}" \
>/dev/null 2>&1 || true

sleep 30

done

###############################################################################
# Finished
###############################################################################

log "========================================================"
log "All Experiments Completed"
log "========================================================"
