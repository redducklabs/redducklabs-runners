.items |= map(if .metadata.name == "github-runners-burst-16g-p1q2r" then .spec.taints += [{"key": "node.kubernetes.io/not-ready", "effect": "NoSchedule"}] else . end)
