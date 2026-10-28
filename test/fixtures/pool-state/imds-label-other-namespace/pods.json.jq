(.items[] | select(.metadata.namespace == "kube-system" and (.metadata.name | startswith("do-node-agent"))) | .metadata.labels) += {"doks.digitalocean.com/allow-imds-egress": "true"}
