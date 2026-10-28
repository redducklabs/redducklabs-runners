.items |= map(if .metadata.name == "github-runners-burst-16g-p1q2r" then .spec.taints += [{"key": "dedicated", "value": "ci", "effect": "NoSchedule"}] else . end)
