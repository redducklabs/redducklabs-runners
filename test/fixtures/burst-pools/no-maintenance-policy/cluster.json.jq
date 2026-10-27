map(if .name == "redducklabs-cluster" then del(.maintenance_policy) else . end)
