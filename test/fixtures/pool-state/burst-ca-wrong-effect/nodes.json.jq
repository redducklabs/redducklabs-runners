.items |= map(if .metadata.name == "github-runners-burst-16g-p1q2r" then .spec.taints += [{"key": "DeletionCandidateOfClusterAutoscaler", "value": "1793015700", "effect": "NoExecute"}] else . end)
