map(if .name == "github-runners-burst-16g" then .labels["workload-type"] = "batch" else . end)
