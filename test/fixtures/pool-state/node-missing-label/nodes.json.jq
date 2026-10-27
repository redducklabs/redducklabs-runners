.items |= map(if .metadata.name == "github-runners-burst-amd-16g-s3t4u" then del(.metadata.labels["workload-type"]) else . end)
