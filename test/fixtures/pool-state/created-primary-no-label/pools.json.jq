map(if .name == "github-runners-burst-amd-16g" then del(.labels["workload-type"]) else . end)
