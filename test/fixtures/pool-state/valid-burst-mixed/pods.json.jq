.items += [
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "cilium-p1q2r", "namespace": "kube-system", "labels": {"k8s-app": "cilium"}},
   "spec": {"nodeName": "github-runners-burst-amd-16g-p1q2r", "containers": [{"name": "main", "resources": {"requests": {"cpu": "300m", "memory": "300Mi"}}}]},
   "status": {"phase": "Running"}},
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "do-node-agent-p1q2r", "namespace": "kube-system", "labels": {"app": "do-node-agent"}},
   "spec": {"nodeName": "github-runners-burst-amd-16g-p1q2r", "containers": [{"name": "main", "resources": {"requests": {"cpu": "100m", "memory": "80Mi"}}}]},
   "status": {"phase": "Running"}},
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "cilium-s3t4u", "namespace": "kube-system", "labels": {"k8s-app": "cilium"}},
   "spec": {"nodeName": "github-runners-burst-intel-16g-s3t4u", "containers": [{"name": "main", "resources": {"requests": {"cpu": "300m", "memory": "300Mi"}}}]},
   "status": {"phase": "Running"}},
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "do-node-agent-s3t4u", "namespace": "kube-system", "labels": {"app": "do-node-agent"}},
   "spec": {"nodeName": "github-runners-burst-intel-16g-s3t4u", "containers": [{"name": "main", "resources": {"requests": {"cpu": "100m", "memory": "80Mi"}}}]},
   "status": {"phase": "Running"}},
  {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "redducklabs-runners-7xk2p-runner-klmno", "namespace": "arc-runners",
    "labels": {"actions.github.com/scale-set-name": "redducklabs-runners", "actions.github.com/scale-set-namespace": "arc-runners", "app.kubernetes.io/component": "runner"}},
   "spec": {"nodeName": "github-runners-burst-amd-16g-p1q2r", "resources": {"requests": {"cpu": "3", "memory": "5Gi"}},
            "containers": [{"name": "runner"}], "initContainers": [{"name": "dind", "restartPolicy": "Always"}]},
   "status": {"phase": "Running"}}
]
