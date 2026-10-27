.items += [{
  "apiVersion": "cilium.io/v2",
  "kind": "CiliumClusterwideNetworkPolicy",
  "metadata": {"name": "mixed-specs"},
  "specs": [
    {"endpointSelector": {}, "egressDeny": [{"toCIDR": ["169.254.169.254/32"]}]},
    {"endpointSelector": {}, "ingress": [{"fromEntities": ["cluster"]}]}
  ]
}]
