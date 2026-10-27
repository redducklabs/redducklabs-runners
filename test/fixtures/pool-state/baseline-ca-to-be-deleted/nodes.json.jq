.items |= map(if .metadata.name == "github-runners-pool-16g-a1b2c" then .spec.taints += [{"key": "ToBeDeletedByClusterAutoscaler", "value": "1793015700", "effect": "NoSchedule"}] else . end)
