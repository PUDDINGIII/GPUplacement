# GPUplacement

A Kubernetes-based GPU scheduling framework for deploying and evaluating TensorRT-optimized YOLO11 workloads on an NVIDIA Jetson Orin cluster.

This repository also introduces **VIGIA (Vigilant Intelligent GPU Inference Allocator)**, a lightweight hardware-aware scheduling framework that dynamically selects worker nodes using runtime hardware telemetry.

---

## Overview

GPUplacement is an experimental framework for evaluating GPU scheduling strategies for edge AI inference workloads running on Kubernetes.

The project demonstrates how multiple TensorRT-optimized YOLO11 workloads can be deployed across an NVIDIA Jetson Orin cluster while monitoring runtime hardware conditions and scheduling behavior.

Unlike the default Kubernetes scheduler, **VIGIA** considers runtime hardware metrics such as context switching, power consumption, and temperature before Pod deployment to improve scheduling decisions.

The repository includes:

* Kubernetes cluster setup
* TensorRT engine generation
* YOLO11 deployment
* GPU resource monitoring
* Experimental methodology
* VIGIA hardware-aware scheduling framework

---

## Repository Structure

```text
GPUplacement/

README.md

docs/
├── Setup.md
├── YOLO_Deployment.md
├── Experiments.md
└── VIGIA.md

scheduler/
├── vigia_scheduler.sh
├── metrics.sh
├── parse_tegrastats.sh
└── config.sh

yaml/

results/

images/
```

---

## Documentation

| Document           | Description                                            |
| ------------------ | ------------------------------------------------------ |
| Setup.md           | Kubernetes cluster setup and Containerd installation   |
| YOLO_Deployment.md | TensorRT engine export and YOLO11 deployment           |
| Experiments.md     | Experimental methodology and evaluation                |
| VIGIA.md           | Hardware-aware scheduling algorithm and implementation |

---

## Key Contributions

* Kubernetes-based AI inference framework for NVIDIA Jetson Orin
* TensorRT-optimized YOLO11 deployment
* Hardware-aware scheduling using runtime telemetry
* Lightweight Bash-based scheduling framework (**VIGIA**)
* Performance evaluation using latency, GPU utilization, power consumption, and EDP
* Reproducible experimental workflow for edge AI scheduling research
