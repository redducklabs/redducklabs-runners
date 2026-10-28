map(if .name == "github-runners-burst-16g" then .taints[0].value = "false" else . end)
