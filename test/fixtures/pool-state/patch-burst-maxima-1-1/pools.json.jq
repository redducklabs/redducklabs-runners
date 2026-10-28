map(if .name == "github-runners-burst-amd-16g" then .max_nodes = 1 else . end)
| map(if .name == "github-runners-burst-intel-16g" then .max_nodes = 1 else . end)
