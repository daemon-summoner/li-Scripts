# archive

Old scripts kept for reference. **Unmaintained** — they are not wired into `li`,
not covered by the test harness, and not held to the current design language.
Some target software or services that no longer exist. Read before running, and
expect to adapt paths and versions.

Nothing here was deleted so the history stays useful; it just no longer belongs
in the active set. If one of these becomes relevant again, the right move is to
rewrite it against `lib/common.sh` and promote it into one of the topic folders,
not to run it as-is.

## What's here

- `oldScripts/` — a grab bag from older machines: game servers (ARK, Minecraft),
  backups (duplicity, WordPress), a TeamSpeak installer, Pritunl, Eclipse Che,
  NoMachine, an Atom editor setup, a tiny HTTPS test server, and assorted
  one-liners.
- `vpsbench-master/` — a vendored third-party VPS benchmark (kept with its own
  LICENSE). The maintained benchmark now lives at `system/benchmark.sh`.
- `bashrc` — the original monolithic shell config, superseded by
  `setup/files/bashrc` and the `shell` setup module.
- `bench.sh`, `clean_loading_bar.sh`, `debug-setup.sh`,
  `git_clone_li-scripts_ssh.sh`, `pip_update.py` — standalone odds and ends that
  were useful once and are kept for reference.
