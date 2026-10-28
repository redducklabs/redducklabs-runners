.items |= map(if .metadata.name == "github-runners-pool-16g-a1b2c" then (.status.conditions |= map(if .type == "Ready" then .status = "False" else . end)) else . end)
