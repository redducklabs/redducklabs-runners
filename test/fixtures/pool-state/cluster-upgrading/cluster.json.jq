map(if .name == "redducklabs-cluster" then .status = {"state": "upgrading", "message": "Cluster is upgrading"} else . end)
