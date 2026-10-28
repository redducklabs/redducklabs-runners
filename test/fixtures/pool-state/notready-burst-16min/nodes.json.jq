.items |= map(if .metadata.name == "github-runners-burst-16g-p1q2r" then .metadata.creationTimestamp = "2026-10-26T11:44:00Z" | (.status.conditions |= map(if .type == "Ready" then .status = "False" | .reason = "KubeletNotReady" else . end))
  | .spec.taints += [{"key": "node.kubernetes.io/not-ready", "effect": "NoSchedule"}] else . end)
