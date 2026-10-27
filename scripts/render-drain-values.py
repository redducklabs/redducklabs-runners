#!/usr/bin/env python3
"""Write the `drain` Helm values file derived from deploy/dind-values.yaml.

The drain contract is the production values with maxRunners 4 and the baseline
node-pool affinity made required instead of preferred. Helm cannot delete a key
set by an earlier values file, so this is generated rather than layered as an
overlay: the result is meant to be passed as the single `-f` file.

Usage: render-drain-values.py OUTPUT_PATH
"""
import pathlib
import sys

import yaml

BASELINE_POOL = "github-runners-pool-16g"
SOURCE = pathlib.Path(__file__).resolve().parent.parent / "deploy" / "dind-values.yaml"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: render-drain-values.py OUTPUT_PATH", file=sys.stderr)
        return 2
    with open(SOURCE, encoding="utf-8") as stream:
        values = yaml.safe_load(stream)
    if not isinstance(values, dict) or not isinstance(
        values.get("template", {}).get("spec"), dict
    ):
        print("ERROR: deploy/dind-values.yaml has no template.spec", file=sys.stderr)
        return 1
    values["maxRunners"] = 4
    values["template"]["spec"]["affinity"] = {
        "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
                "nodeSelectorTerms": [
                    {
                        "matchExpressions": [
                            {
                                "key": "doks.digitalocean.com/node-pool",
                                "operator": "In",
                                "values": [BASELINE_POOL],
                            }
                        ]
                    }
                ]
            }
        }
    }
    with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as stream:
        yaml.safe_dump(values, stream, sort_keys=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
