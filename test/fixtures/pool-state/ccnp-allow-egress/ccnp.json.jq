.items += [{
  "apiVersion": "cilium.io/v2",
  "kind": "CiliumClusterwideNetworkPolicy",
  "metadata": {"name": "allow-vpc-everywhere"},
  "spec": {"endpointSelector": {}, "egress": [{"toCIDR": ["10.124.0.0/20"]}]}
}]
