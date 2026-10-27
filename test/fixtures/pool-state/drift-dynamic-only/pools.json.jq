map(if .name == "github-runners-burst-16g" then .count = 3 else . end)
| map(if .name == "github-runners-burst-amd-16g" then .count = 0 else . end)
