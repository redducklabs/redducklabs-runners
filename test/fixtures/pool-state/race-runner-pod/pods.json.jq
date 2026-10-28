.items += [{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "redducklabs-runners-7xk2p-runner-zzzzz", "namespace": "arc-runners",
    "labels": {"actions.github.com/scale-set-name": "redducklabs-runners", "actions.github.com/scale-set-namespace": "arc-runners", "app.kubernetes.io/component": "runner"}},
   "spec": {"nodeName": "github-runners-burst-amd-16g-n3w99", "resources": {"requests": {"cpu": "3", "memory": "5Gi"}},
            "containers": [{"name": "runner"}], "initContainers": [{"name": "dind", "restartPolicy": "Always"}]},
   "status": {"phase": "Running"}}]
