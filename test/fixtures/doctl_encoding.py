#!/usr/bin/env python3
"""doctl's JSON encoding of `kubernetes cluster node-pool list -o json`.

doctl prints the godo NodePool struct, whose fields are tagged `omitempty`:
a zero count, min_nodes or max_nodes, a false auto_scale and an empty nodes
list are left out of the object instead of being printed (Ruling 39). Live,
a closed burst pool (count 0, 0/0) reads back with exactly the keys
auto_scale, id, labels, name, size, tags and taints.

The burst-autoscaling and acceptance test doubles pass node-pool list JSON
through encode_pool_list, so each of their scenarios exercises the live
encoding. The one exception is the inline doctl() mock in
test/verify-runner-resources.sh, which only prints the baseline pool at
2/2/2: it has no zero fields to omit. Values that
doctl could not omit (an explicit null, a string, a nonzero number) are kept
as they are, so fixtures can still model malformed provider output.

CLI: doctl_encoding.py <file> prints the encoded file. A file that is not
JSON is printed unchanged (fixtures model unparseable output on purpose).
"""

import json
import sys

ZERO_INT_FIELDS = ("count", "min_nodes", "max_nodes")


def omitted(key, value):
    if key in ZERO_INT_FIELDS:
        return type(value) is int and value == 0
    if key == "auto_scale":
        return value is False
    if key == "nodes":
        return value == [] and isinstance(value, list)
    return False


def encode_pool(pool):
    if not isinstance(pool, dict):
        return pool
    return {key: value for key, value in pool.items() if not omitted(key, value)}


def encode_pool_list(document):
    if not isinstance(document, list):
        return document
    return [encode_pool(pool) for pool in document]


def main():
    with open(sys.argv[1], encoding="utf-8") as stream:
        text = stream.read()
    try:
        document = json.loads(text)
    except json.JSONDecodeError:
        sys.stdout.write(text)
        return 0
    print(json.dumps(encode_pool_list(document), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
