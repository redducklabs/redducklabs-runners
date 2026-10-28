map(if .name == "github-runners-burst-amd-16g" then .labels["workload-type"] = "batch" else . end)
