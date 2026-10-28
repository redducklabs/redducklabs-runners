.items |= map(if .metadata.name == "github-runners-burst-intel-16g-s3t4u" then .status.nodeInfo.kubeletVersion = "v1.35.4" else . end)
