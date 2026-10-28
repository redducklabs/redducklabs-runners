. + [{"id": "9a4b2c6d-1e3f-4a5b-8c7d-0e1f2a3b4c03", "name": "github-runners-burst-intel-16g", "size": "s-8vcpu-16gb-intel", "count": 0,
  "tags": ["k8s", "k8s:c4e1f0a2-6b3d-4f58-9a07-1d2e3f4a5b60", "k8s:worker"],
  "labels": {"node-type": "github-runner", "workload-type": "ci-cd"},
  "taints": [{"key": "github-runner", "value": "true", "effect": "NoSchedule"}],
  "auto_scale": true, "min_nodes": 0, "max_nodes": 0, "nodes": []}]
