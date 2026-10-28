(.items[] | select(.metadata.namespace == "arc-runners") | .metadata.labels) += {"doks.digitalocean.com/allow-imds-egress": "true"}
