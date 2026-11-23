# Atuin local snapshots

The backup sidecar runs `backup.sh` immediately at startup, then every 24 hours
after success (every hour after failure). It uses SQLite `VACUUM INTO` with a
30-second lock timeout so committed WAL data is included. It never creates a
missing source database.

Each attempt writes a unique, hidden temporary file beside the final snapshots,
checks `PRAGMA integrity_check`, and renames it only after success. Creation,
validation or publication failure skips retention entirely and logs an error.
Ordinary exits clean up only that attempt's temporary file. SIGKILL/node failure
can leave hidden temporary files; inspect those manually rather than glob-deleting
them. Final filenames contain UTC time and a random suffix to avoid same-day
collisions.

Retention only considers known generated filenames, including legacy
`atuin-YYYY-MM-DD.db`. It keeps the newest **at least three valid generations**
even if they are older than seven days. Other valid generations are eligible
only with `find -mtime +7` (the previous whole-day age policy). Invalid snapshots,
symlinks and unknown names are preserved for manual investigation, not counted
towards the minimum. Errors and successful snapshot/removal paths are logged to
stderr; external alerting on failures/stale success logs remains an operator task.

The single-writer assumption depends on one replica and the Recreate strategy.
Do not run concurrent manual backups alongside the sidecar. The generated
ConfigMap name is hashed by Kustomize, so script updates roll the Deployment.

**These snapshots share the 5 GiB `atuin-data` PVC with the source.** They are not
an independent disaster-recovery backup; this change does not configure remote
storage, resize the PVC, or apply anything to the cluster. A full disk can stop
new snapshots, and failed attempts deliberately do not free old snapshots.
Monitor space and configure a separate off-PVC backup as a distinct operation.

## Local regression tests

Requires Python 3 and the SQLite CLI on PATH. Tests use disposable temporary
databases only and cover WAL, failure/no-pruning, integrity/publication failure,
minimum retention, recent files, repeated runs, missing source, and unrelated files.

```sh
python -m unittest discover -s k8s/apps/atuin -p '*_test.py' -v
sh -n k8s/apps/atuin/backup.sh
kustomize build k8s/apps/atuin >/dev/null
```
