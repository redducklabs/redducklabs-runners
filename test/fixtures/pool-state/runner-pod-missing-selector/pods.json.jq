(.items[] | select(.metadata.namespace == "arc-runners" and .metadata.name == "redducklabs-runners-7xk2p-runner-abcde") | .metadata.labels) |= del(."actions.github.com/scale-set-name")
