.items += [{
  "apiVersion": "cilium.io/v2",
  "kind": "CiliumNetworkPolicy",
  "metadata": {"name": "allow-vpc", "namespace": "arc-runners"},
  "spec": {"endpointSelector": {}, "egress": [{"toCIDR": ["10.124.0.0/20"]}]}
}]
