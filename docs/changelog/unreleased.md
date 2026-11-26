# Unreleased

### Added

- **Busy page: the node a pod runs on.** On Kubernetes a process's hostname is its pod's name. The heartbeat now also reports `node`, the first one set of `WURK_NODE_NAME`, `K8S_NODE_NAME` and `NODE_NAME` (set it from the downward API's `spec.nodeName`), and `node_zone` from `WURK_NODE_ZONE`. Both are null when unset, and both appear in `/api/processes` and in `/v1/swarm`'s hosts. Each card shows "on <node>" with its zone, and a row of node chips filters the cards to one node or groups them under a heading per node. A bare host reports no node, and the page looks as before.
