# Host profiles

One checkout, a fleet of machines, no per-machine editing of `config.env`.

`gha-vm.sh deps` installs every `*.env` here to `/etc/gha-vm/profiles/`. At load
time each host picks **one** of them:

1. `HOST_PROFILE` set in the environment or `config.env` — explicit wins
2. `/etc/gha-vm/profiles/<machine-id>.env` — survives a hostname change
3. `/etc/gha-vm/profiles/<short hostname>.env` — the readable, normal case
4. `/etc/gha-vm/profiles/default.env` — a fleet-wide fallback, if you ship one
5. nothing — built-in defaults plus autotune

Steps 1-3 decide the name; `default.env` is only read when that name has no
file. Neither a profile file nor `local.env` can change `HOST_PROFILE`
itself; a line doing so is ignored with a warning.

Profiles are sourced **after** `config.env`, so anything a profile sets wins.
Put credentials and scope in `config.env`; put sizing in a profile.

## `local.env`

`/etc/gha-vm/profiles/local.env` is sourced last, after whichever profile was
picked, and `deps` never writes it. It is the place for a setting that belongs
to this one machine and should survive the checkout's profiles being
reinstalled: `setup.sh` writes the sizing answers there, and anything you set
by hand (`MAX_SLOTS=3` while the box is borrowed for something else) goes there
too. Precedence, lowest to highest:

```
built-in defaults  <  config.env  <  the profile  <  local.env
```

Check which files a machine loaded, and what every value resolved to:

```bash
gha-vm profile           # the profile and local.env in effect
gha-vm config            # every effective value
gha-vm config MAX_SLOTS  # one of them
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
#VM_MEM_1=16G          # slot 1 runs a bigger VM...
#RUNNER_LABELS_EXTRA_1=large   # ...that workflows reach with runs-on: [self-hosted, large]
#FLEET_MEM=auto        # memory all VMs share; auto = RAM - HOST_RESERVE_GB
#MEM_OVERCOMMIT_PCT=100
DISK_PER_SLOT_GB=30
HOST_RESERVE_GB=8      # a floor; autotune only ever raises it
MIN_FREE_GB=20
NESTED_VIRT=0
```

## Shipped

| Profile | Machine | Slots |
|---|---|---|
| `services.env` | 24 vCPU / 46G, QEMU guest, runs llama-server + minio + containers | 5: one 16G + four 8G in a 24G shared budget |

A dedicated 128G box needs no file here: autotune already sizes it to roughly
`(128 − reserve) / 8` = 15 slots. Add one only to pin `MAX_SLOTS` or to change
the per-job shape.
