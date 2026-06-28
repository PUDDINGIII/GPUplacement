# VIGIA: A Hardware-Aware GPU Scheduling Framework for Kubernetes

VIGIA (**Vigilant Intelligent GPU Inference Allocator**) is a lightweight hardware-aware scheduling framework designed for Kubernetes clusters running AI inference workloads on NVIDIA Jetson Orin devices.

Unlike the default Kubernetes scheduler, which primarily relies on static CPU and memory resource requests, VIGIA incorporates real-time hardware telemetry—including context switching, power consumption, and temperature—to make scheduling decisions that improve inference latency, resource utilization, and system stability.

---

# Motivation

The default Kubernetes scheduler places Pods based primarily on static resource requests and node availability.

Although this strategy is effective for cloud environments, it cannot accurately reflect the rapidly changing hardware conditions of edge AI devices.

During TensorRT inference, execution latency is strongly affected by runtime hardware conditions such as:

- Context switching
- CPU scheduling overhead
- Power consumption
- Thermal throttling
- Hardware resource contention

Consequently, workloads with identical resource requests may experience significantly different execution times depending on the current hardware state.

VIGIA addresses this limitation by observing runtime hardware metrics before deployment and selecting the worker node with the lowest estimated execution cost.

---

# Design Goals

VIGIA was designed with the following objectives.

- Reduce inference latency
- Improve scheduling stability
- Avoid overloaded worker nodes
- Utilize runtime hardware telemetry
- Preserve the existing Kubernetes deployment workflow without modifying the Kubernetes scheduler

---

# Overall Workflow

```text
Collect Hardware Metrics
        │
        ▼
Compute Penalty Score
        │
        ▼
Apply Model Sensitivity
        │
        ▼
Select Optimal Worker Node
        │
        ▼
Inject nodeName into Pod Manifest
        │
        ▼
Deploy Pod
```

---

# Runtime Hardware Metrics

VIGIA periodically collects runtime information from every worker node.

| Metric | Description |
|----------|-------------------------------|
| Context Switch | Kernel scheduling overhead |
| Power | Instantaneous power consumption |
| Node Temperature | Runtime thermal status |
| Disk Usage | Available storage capacity |

These metrics are combined to estimate the runtime scheduling cost of each worker node.

---

# Model Sensitivity

Different YOLO11 workloads exhibit different levels of sensitivity to hardware contention.

VIGIA assigns a model sensitivity coefficient (θ) to each workload.

| Model | θ |
|----------------------|----:|
| YOLO11 Classification | 1.00 |
| YOLO11 Segmentation | 1.84 |
| YOLO11 Pose | 2.24 |
| YOLO11 Detection | 2.38 |
| YOLO11 OBB | 3.18 |

Classification is selected as the baseline because it exhibits the lowest sensitivity to runtime interference.

The OBB model receives the highest coefficient due to its computational complexity and the additional CPU overhead introduced by rotated Non-Maximum Suppression (NMS).

---

# Hardware-Aware Penalty Function

VIGIA estimates the scheduling cost of each worker node using the following penalty function.

```math
Penalty =
\theta_{model}
\left(
W_{CS}\frac{CS}{1000}
+
W_{P}\frac{Power}{10000}
+
W_{T}\frac{Temperature}{100}
\right)
```

where

- **θ** : model sensitivity coefficient
- **CS** : context switching frequency
- **Power** : instantaneous power consumption
- **Temperature** : runtime node temperature

The worker node with the lowest penalty score is selected for Pod deployment.

---

# Scheduling Strategy

Instead of replacing the default Kubernetes scheduler, VIGIA performs hardware-aware scheduling immediately before Pod deployment.

The selected worker node is injected directly into the Pod specification using the **nodeName** field.

```text
Hardware Monitoring
        │
        ▼
Penalty Calculation
        │
        ▼
Node Selection
        │
        ▼
Inject nodeName
        │
        ▼
kubectl apply
```

This hybrid strategy preserves the standard Kubernetes deployment workflow while enabling runtime hardware-aware scheduling.

---

# Why a Bash-Based Hybrid Scheduler?

Although implementing a custom scheduler plugin in Go is the standard Kubernetes approach, VIGIA adopts a lightweight Bash-based implementation for practical research purposes.

## Experimental Determinism

The default Kubernetes scheduler may modify placement decisions during its scheduling pipeline.

VIGIA bypasses this uncertainty by directly injecting the selected node into the Pod manifest, ensuring that deployment decisions are determined solely by the proposed scheduling algorithm.

## Lightweight Runtime Monitoring

Runtime metrics are collected using lightweight Linux utilities, including

- tegrastats
- vmstat
- pidstat
- mpstat

This approach minimizes implementation complexity while providing low-overhead hardware telemetry.

## Rapid Parameter Optimization

Scheduling parameters can be adjusted by editing a small number of variables inside the scheduling script.

No recompilation, image rebuilding, or Kubernetes component modification is required, enabling rapid experimental iteration.

---

# Reliability Features

Several mechanisms are incorporated to improve scheduling reliability.

## Disk Filter

Worker nodes whose disk utilization exceeds **90%** are excluded from scheduling.

## Force Delete

Existing Pods are forcefully removed before deployment to prevent immutable resource conflicts.

## Remote Cleanup

Background monitoring processes are automatically terminated after each experiment to maintain a clean execution environment.

---

# Example Implementation

The complete implementation is provided in

```text
scheduler/vigia_scheduler.sh
```

The scheduler performs the following steps.

1. Collect hardware telemetry from every worker node.
2. Calculate the hardware-aware penalty score.
3. Apply the model sensitivity coefficient.
4. Select the worker node with the minimum penalty.
5. Inject the selected node into the Pod manifest.
6. Deploy the workload using Kubernetes.

Workflow:

```text
Collect tegrastats
        │
        ▼
Collect vmstat
        │
        ▼
Calculate Penalty
        │
        ▼
Select Best Node
        │
        ▼
Inject nodeName
        │
        ▼
kubectl apply
```

---

# Experimental Results

VIGIA was evaluated using TensorRT-accelerated YOLO11 inference workloads on a Kubernetes cluster composed of two NVIDIA Jetson Orin worker nodes.

Under identical software and hardware configurations, VIGIA demonstrated:

- Lower average inference latency
- Reduced P99 latency
- Improved scheduling stability
- Lower Energy-Delay Product (EDP)
- More balanced workload distribution

These improvements were achieved without modifying the Kubernetes scheduler or control plane components.

---

# Current Limitations

Several limitations remain.

- Model sensitivity coefficients are manually tuned.
- Hardware conditions may change between scheduling and execution.
- Hardware variations among physically identical worker nodes are not fully normalized.

These limitations will be addressed in future work.

---

# Future Work

Future research will focus on:

- Adaptive model sensitivity estimation
- Predictive scheduling using historical telemetry
- Reinforcement learning-based scheduling
- Support for heterogeneous GPU clusters
- Larger Kubernetes edge clusters
- Additional AI inference workloads

---

# Summary

VIGIA demonstrates that lightweight hardware-aware scheduling can substantially improve AI inference performance on edge Kubernetes clusters.

By combining runtime hardware telemetry with model-aware scheduling, VIGIA provides a practical alternative to conventional resource-based scheduling while preserving compatibility with existing Kubernetes deployment workflows.
