.items |= map(if .metadata.name == "github-runners-burst-intel-16g-s3t4u" then del(.metadata.labels["doks.digitalocean.com/node-pool"]) else . end)
