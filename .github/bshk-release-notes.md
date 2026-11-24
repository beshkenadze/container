Apple container 1.7.1 with commands to start and stop Kubernetes clusters.

Cluster start and stop:

- Use `container cluster stop` to stop a cluster. Use `container cluster start` to start it again.
- These commands come from an open upstream pull request. Their behavior can change before upstream merges it.
- You cannot restart a multi-node cluster that you created before this release.
- If a start is interrupted, the cluster can show `running` while the pod network does not work. To recover, run `container cluster stop`, then `container cluster start`.
- Each stop ends with a forced kill. The runtime then unmounts the data disk.
- This release fixes a bug in cluster exec that closed the same file descriptors twice in clusters with two or more workers.

Shared image store:

- The installer now includes `cluster-shim`, so `container cluster create --shared-image-store` works.

`container --version` shows `1.7.1`.
