.items |= map(if .metadata.name == "github-runners-burst-16g-p1q2r" then .spec.taints += [{"key": "ToBeDeletedByClusterAutoscaler", "value": "1793015700", "effect": "NoSchedule"}] else . end)
