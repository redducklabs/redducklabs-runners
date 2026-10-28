. + [{"id": "7d1e2f30-4a5b-4c6d-8e7f-90a1b2c3d4e5", "name": "github-runners-burst-16g", "size": "s-8vcpu-16gb", "count": 0,
  "tags": ["k8s", "k8s:c4e1f0a2-6b3d-4f58-9a07-1d2e3f4a5b60", "k8s:worker"],
  "labels": {"node-type": "github-runner", "workload-type": "ci-cd"},
  "taints": [{"key": "github-runner", "value": "true", "effect": "NoSchedule"}],
  "auto_scale": true, "min_nodes": 0, "max_nodes": 0, "nodes": []}]
