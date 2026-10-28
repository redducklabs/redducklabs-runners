.items |= map(if .metadata.name == "github-runners-pool-16g-a1b2c" then .spec.providerID = "digitalocean://500000099" else . end)
