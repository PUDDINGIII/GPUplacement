# Setup

This document describes the environment setup process for building a Kubernetes cluster using Containerd.

---
## Requirements

- Ubuntu 24.04
- Kubernetes v1.29
- Containerd
- NVIDIA Container Runtime
- NVIDIA Jetson Orin

## 1. Verify System Information 

Verify the network interface and system UUID before configuring the cluster.

```bash
# Check network interface
ifconfig -a

# Check system UUID
sudo cat /sys/class/dmi/id/product_uuid
```

> **Note**
>
> System-specific information has been omitted.

---

## 2. Disable Swap

Kubernetes requires swap memory to be disabled.

```bash
# Disable swap temporarily
sudo swapoff -a

# Disable swap permanently
sudo sed -i '/swap/s/^/#/' /etc/fstab

# Verify memory status
free -m

# Verify swap status (No output means swap is disabled)
swapon --show
```

---

## 3. Disable Firewall

Disable the firewall to prevent communication issues between cluster nodes.

```bash
sudo apt-get install -y firewalld

sudo systemctl stop firewalld
sudo systemctl disable firewalld
```

(Optional) Verify firewall status.

```bash
sudo firewall-cmd --list-all

# Check listening ports
sudo netstat -tlnp
```

---

## 4. Configure Kernel Modules

Enable the kernel modules required by Kubernetes networking.

Create the module configuration file.

```bash
sudo tee /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
```

Load the modules immediately.

```bash
sudo modprobe overlay
sudo modprobe br_netfilter
```

---

## 5. Configure Network Parameters

Create the Kubernetes sysctl configuration.

```bash
sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
```

Apply the configuration.

```bash
sudo sysctl --system
```

---

## 6. Install Containerd

### Install Required Packages

```bash
sudo apt-get update

sudo apt-get install -y \
apt-transport-https \
ca-certificates \
curl \
gnupg
```

---

### Add Docker GPG Key

```bash
sudo install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
sudo gpg --dearmor \
-o /etc/apt/keyrings/docker.gpg

sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

---

### Register Docker Repository

```bash
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

---

### Install Containerd

```bash
sudo apt-get update

sudo apt-get install -y containerd.io
```

---

### Generate Default Configuration

```bash
sudo mkdir -p /etc/containerd

sudo containerd config default | \
sudo tee /etc/containerd/config.toml
```

---

### Enable Systemd Cgroup

```bash
sudo sed -i \
's/SystemdCgroup = false/SystemdCgroup = true/' \
/etc/containerd/config.toml
```

---

### Restart Containerd

```bash
sudo systemctl restart containerd

sudo systemctl enable containerd
```

---

### Verify Installation

```bash
sudo systemctl status containerd
```

---

## 7. Install Kubernetes

### Install Required Packages

```bash
sudo apt-get update

sudo apt-get install -y \
apt-transport-https \
ca-certificates \
curl \
gpg

sudo mkdir -p -m 755 /etc/apt/keyrings
```

---

### Register Kubernetes Repository

```bash
curl -fsSL \
https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
sudo gpg --dearmor \
-o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

```bash
echo \
'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
sudo tee /etc/apt/sources.list.d/kubernetes.list
```

---

### Install Kubernetes Components

```bash
sudo apt-get update

sudo apt-get install -y \
kubelet \
kubeadm \
kubectl
```

---

### Prevent Automatic Updates

```bash
sudo apt-mark hold \
kubelet \
kubeadm \
kubectl
```

---

### Verify Installation

```bash
kubelet --version

kubeadm version

kubectl version

sudo systemctl status kubelet.service
```

---

## 8. Initialize the Kubernetes Control Plane

Initialize the Kubernetes control plane on the master node.

```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
```

After the initialization is complete, configure `kubectl` for the current user.

```bash
sudo mkdir -p $HOME/.kube

sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config

sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

> **Note**
>
> Without this configuration, `kubectl` may return the following error:
>
> ```
> The connection to the server localhost:8080 was refused
> ```

---

## 9. Install Flannel CNI

Flannel provides the overlay network used for communication between Kubernetes Pods.

Download and deploy Flannel.

```bash
curl -O https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

kubectl apply -f kube-flannel.yml
```

Verify the CNI installation.

```bash
kubectl get pods -A
```

---

## 10. Join Worker Nodes

Repeat the environment setup, Containerd installation, and Kubernetes installation on each worker node.

Join the worker node to the cluster.

```bash
sudo kubeadm join <MASTER_IP>:6443 \
--token <TOKEN> \
--discovery-token-ca-cert-hash sha256:<HASH>
```

> **Note**
>
> The join token and certificate hash are generated whenever the control plane is initialized.
> Replace `<MASTER_IP>`, `<TOKEN>`, and `<HASH>` with the values displayed by `kubeadm init`.

---

## 11. Generate a New Join Token (Optional)

If the join token has expired, create a new one.

```bash
kubeadm token create
```

List the available tokens.

```bash
kubeadm token list
```

Generate the CA certificate hash.

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
| openssl rsa -pubin -outform der 2>/dev/null \
| openssl dgst -sha256 -hex \
| sed 's/^.* //'
```

---

## 12. Verify Cluster Status

On the master node, verify that all nodes have joined successfully.

```bash
kubectl get nodes
```

Expected output.

```text
NAME         STATUS   ROLES
gpu-master   Ready    control-plane
gpu-orin2    Ready    <none>
gpu-orin3    Ready    <none>
```

Verify that the system Pods are running.

```bash
kubectl get pods -A
```

---

### bridge-nf-call-iptables does not exist

If the following error appears:

```text
[ERROR FileContent--proc-sys-net-bridge-bridge-nf-call-iptables]
```

Run the following commands.

```bash
sudo modprobe br_netfilter

echo 1 | sudo tee /proc/sys/net/bridge/bridge-nf-call-iptables
```

---

### Worker Node Already Joined

If the worker node was previously initialized, reset Kubernetes before joining again.

```bash
sudo kubeadm reset
```

Then execute the `kubeadm join` command again.

---

## 13. Install NVIDIA Device Plugin

Deploy the NVIDIA Device Plugin to expose GPU resources to Kubernetes.

```bash
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml
```

Add the NVIDIA Helm repository.

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin

helm repo update
```

Install the device plugin.

```bash
helm install k8s-device-plugin \
nvdp/nvidia-device-plugin \
--namespace nvidia-device-plugin \
--create-namespace \
-f values.yaml
```

---

### Example values.yaml

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: serverType
              operator: In
              values:
                - gpu

tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
```

---

### Example config.yaml

```yaml
version: v1

sharing:
  timeSlicing:
    mps: true

    resources:
      - name: nvidia.com/gpu
        replicas: 5
```

---

## 14. Configure NVIDIA Runtime

Modify the Containerd runtime configuration on each worker node.

```bash
sudo vi /etc/containerd/config.toml
```

Configure the runtime to use the NVIDIA Container Runtime.
Only the modified section of `config.toml` is shown below.

```toml
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
runtime_type = "io.containerd.runc.v2"
runtime_engine = "/usr/bin/nvidia-container-runtime"
```

Restart Containerd.

```bash
sudo systemctl restart containerd
```

---

## 15. Test GPU Resource

Create a test Pod.

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: gpu-test-pod

spec:
  restartPolicy: OnFailure

  containers:

  - name: cuda-container

    image: nvcr.io/nvidia/cuda:11.8.0-devel-ubuntu22.04

    command: ["/bin/bash","-c"]

    args: ["sleep 3600"]

    resources:
      limits:
        nvidia.com/gpu: 1
```

Apply the Pod.

```bash
kubectl apply -f gpu-test-pod.yaml
```

Verify the Pod.

```bash
kubectl get pods

kubectl exec -it gpu-test-pod -- bash
```

Verify CUDA.

```bash
nvcc --version
```

---

## 16. Verify GPU Resource

Verify that GPU resources are exposed correctly.

```bash
kubectl describe node <WORKER_NODE> | grep nvidia.com/gpu
```

Expected output.

```text
nvidia.com/gpu: 5
```
GPU resources are successfully exposed through the NVIDIA Device Plugin with MPS Time-Slicing enabled.

---

## Setup Completed

At this point,

* Kubernetes Cluster has been initialized.
* Worker Nodes have joined the cluster.
* Flannel networking is configured.
* NVIDIA Runtime is enabled.
* NVIDIA Device Plugin is installed.
* GPU Time-Slicing is configured.
* The cluster is now ready to deploy GPU-accelerated workloads such as YOLOv8 inference.
