map(if .name == "github-runners-burst-amd-16g" then .taints[0].value = "false" else . end)
