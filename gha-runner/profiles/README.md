# Host profiles

One checkout, a fleet of machines, no per-machine editing of `config.env`.

`gha-vm.sh deps` installs every `*.env` here to `/etc/gha-vm/profiles/`. At load
time each host picks **one** of them:

1. `HOST_PROFILE` set in the environment or `config.env` — explicit wins
2. `/etc/gha-vm/profiles/<machine-id>.env` — survives a hostname change
3. `/etc/gha-vm/profiles/<short hostname>.env` — the readable, normal case
4. `/etc/gha-vm/profiles/default.env` — a fleet-wide fallback, if you ship one
5. nothing — built-in defaults plus autotune

Profiles are sourced **after** `config.env`, so anything a profile sets wins.
Put credentials and scope in `config.env`; put sizing in a profile.

Check what a machine resolved to:

```bash
gha-vm profile
```

## You usually do not need one

`AUTOTUNE=1` (the default) raises `HOST_RESERVE_GB` to cover whatever is
resident when `capacity` runs. On a dedicated CI box that is a small number and
capacity comes out at the nameplate; on a box already running other services the
reserve absorbs them automatically. Write a profile when you want a *policy*
the hardware cannot infer — most often a hard ceiling on slots.

## Template

```bash
# profiles/<hostname>.env
MAX_SLOTS=0            # 0 = let the hardware decide
VM_CPUS=4
VM_MEM=8G
VM_DISK=80G
DISK_PER_SLOT_GB=30
HOST_RESERVE_GB=8      # a floor; autotune only ever raises it
MIN_FREE_GB=20
NESTED_VIRT=0
```

## Shipped

| Profile | Machine | Slots |
|---|---|---|
| `services.env` | 24 vCPU / 46G, QEMU guest, runs llama-server + minio + containers | capped at 2 |

A dedicated 128G box needs no file here: autotune already sizes it to roughly
`(128 − reserve) / 8` = 15 slots. Add one only to pin `MAX_SLOTS` or to change
the per-job shape.
