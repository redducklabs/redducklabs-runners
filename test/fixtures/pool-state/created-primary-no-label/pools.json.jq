map(if .name == "github-runners-burst-16g" then del(.labels["workload-type"]) else . end)
