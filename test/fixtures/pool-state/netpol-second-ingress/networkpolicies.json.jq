.items += [{
  "apiVersion": "networking.k8s.io/v1",
  "kind": "NetworkPolicy",
  "metadata": {"name": "allow-ingress", "namespace": "arc-runners"},
  "spec": {
    "podSelector": {"matchLabels": {"actions.github.com/scale-set-name": "redducklabs-runners"}},
    "policyTypes": ["Ingress"],
    "ingress": [{}]
  }
}]
