map(if .name == "redducklabs-cluster" then .cluster_autoscaler_configuration.expanders = ["priority", "random"] else . end)
