.items += [
  (.items[0]
  | .metadata.name = "github-runners-burst-16g-p1q2r" | .metadata.uid = "a0b1c2d3-4444-4aaa-8bbb-000000000004" | .metadata.creationTimestamp = "2026-10-26T11:20:00Z"
  | .metadata.labels["doks.digitalocean.com/node-pool"] = "github-runners-burst-16g"
  | .metadata.labels["doks.digitalocean.com/node-pool-id"] = "3e9d7b20-8c4f-4d1a-a6e5-71f2c0b9d802"
  | .metadata.labels["doks.digitalocean.com/node-id"] = "github-runners-burst-16g-p1q2r-id"
  | .metadata.labels["kubernetes.io/hostname"] = "github-runners-burst-16g-p1q2r"
  | .metadata.labels["node.kubernetes.io/instance-type"] = "s-8vcpu-16gb"
  | .spec.providerID = "digitalocean://500000101"),
  (.items[0]
  | .metadata.name = "github-runners-burst-amd-16g-s3t4u" | .metadata.uid = "a0b1c2d3-5555-4aaa-8bbb-000000000005" | .metadata.creationTimestamp = "2026-10-26T11:25:00Z"
  | .metadata.labels["doks.digitalocean.com/node-pool"] = "github-runners-burst-amd-16g"
  | .metadata.labels["doks.digitalocean.com/node-pool-id"] = "9a4b2c6d-1e3f-4a5b-8c7d-0e1f2a3b4c03"
  | .metadata.labels["doks.digitalocean.com/node-id"] = "github-runners-burst-amd-16g-s3t4u-id"
  | .metadata.labels["kubernetes.io/hostname"] = "github-runners-burst-amd-16g-s3t4u"
  | .metadata.labels["node.kubernetes.io/instance-type"] = "s-8vcpu-16gb-amd"
  | .spec.providerID = "digitalocean://500000201")
]
