.items += [{
  "apiVersion": "networking.k8s.io/v1",
  "kind": "NetworkPolicy",
  "metadata": {"name": "allow-vpc", "namespace": "arc-runners"},
  "spec": {
    "podSelector": {},
    "policyTypes": ["Egress"],
    "egress": [{"to": [{"ipBlock": {"cidr": "10.124.0.0/20"}}]}]
  }
}]
