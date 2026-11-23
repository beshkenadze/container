Apple container 1.7.1 with fixes for data loss from names that differ only in case, and for `container image push`.

Names that differ only in case, on a case-insensitive file system (the macOS default):

- `container volume create`, `container create` and `container machine create` with a name that differs from an existing one only in case (`Web` beside `web`) wrote into the existing entity's directory. A volume create formatted the existing volume's image; a later delete of the second container removed the first container's root file system. Each create now reserves its directory before it writes, and refuses such a name: "… on this file system its name is the same as that of the existing …".
- A directory left with files by an interrupted create is refused with its path and how to keep its files (`mv`). An empty directory, or one with only the reservation marker, is reclaimed.
- A container directory that fails to load is kept and logged, not deleted.
- A directory that two names already share is kept. Start and delete are refused only when the container's ID does not lead to the directory. The state that 1.7.1-bshk.1 leaves when `web` was created over a started `Web` loads as `Web`, and its delete removes the other name's runtime configuration first.
- A delete that waited while its container was deleted and created again under the same name no longer removes the new container.
- `container run -v <name>:…` reports the conflict when the volume name folds onto another volume.

`container image push`:

- containerization 0.54.0 and beshkenadze/containerization#1, #2
- async-http-client and beshkenadze/async-http-client#1, #2, #3, #4

`container --version` shows `1.7.1`.
