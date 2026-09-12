# gha-vm — ephemeral GitHub Actions runners in throwaway KVM microVMs

Each job gets a fresh Ubuntu VM built from a golden qcow2 image. The VM takes
exactly one job, powers off, and the host deletes its disk. Nothing survives
between jobs.

**Isolation boundary is the VM, not a container namespace.** Inside the guest a
job can be root, use Docker, run privileged containers — an escape lands in a
disk image that is deleted seconds later. The GitHub credential never enters the
guest: the host mints a single-use JIT runner config and passes only that in
through a cloud-init seed.

## Requirements

- Ubuntu 26.04 LTS host with `/dev/kvm` (virtualization enabled in BIOS)
- A GitHub App (preferred) or PAT — see below
- NVMe for `STATE_DIR` — every job writes a fresh qcow2 overlay there

## Creating the GitHub App

`setup.sh` prints these steps with your own org's URLs filled in. The whole thing
takes about two minutes.

**Org scope** — new app at
`https://github.com/organizations/<ORG>/settings/apps/new`
**Repo scope** — new app at `https://github.com/settings/apps/new`

1. **GitHub App name** — anything unique, e.g. `gha-vm-runners`.
2. **Homepage URL** — required by the form but never used. Any URL.
3. **Webhook** — untick **Active**. This app receives nothing.
4. **Permissions** — exactly one, and it differs by scope:

   | Scope | Permission | Level |
   |---|---|---|
   | org | Organization permissions → **Self-hosted runners** | Read and write |
   | repo | Repository permissions → **Administration** | Read and write |

   Leave everything else at *No access*. Getting this wrong is the most common
   failure: the app installs fine and then every token mint returns 422.
5. **Where can this app be installed** — *Only on this account*.
6. **Create GitHub App.**
7. Note the **App ID** at the top of the app's page. It is a number — not the
   Client ID (`Iv1...`), not the app name.
8. **Generate a private key** → a `.pem` downloads. Open it and paste the whole
   block into `setup.sh` when it asks; a path to the file works there too. Either
   way it lands at `/etc/gha-vm/app.pem` as `root:gha` mode `0640`. Pasting saves
   an `scp` when the key downloaded to your laptop.
9. **Install App** in the left sidebar → install it on the org (or repo).

Changing a permission later re-issues an installation request that an org owner
must accept, under the org's *Installed GitHub Apps* entry. Until that is
accepted the old permissions apply.

### PAT instead

Classic token at `https://github.com/settings/tokens/new`, scope `admin:org` for
org scope or `repo` for repo scope. If the org enforces SAML SSO, click
**Configure SSO** on the token afterwards and authorize it for the org, or every
call returns 403. The PAT is stored in plain text in `/etc/gha-vm/config.env`
and does not expire on its own, which is why the App is the default.

## Install

On each machine, from a checkout of this directory:

```bash
./setup.sh
```

That is the whole install. It re-execs itself under sudo and walks six steps —
host dependencies, GitHub connection, VM size, golden image, network isolation,
slot count — validating each answer as you go and defaulting the slot count to
what the machine can actually carry. Have the GitHub App ID and its `.pem` handy;
the script copies the key into place with the right owner and mode.

Re-running is the supported way to change anything. Every prompt defaults to the
current setting, so pressing enter through leaves the config untouched; the
golden image is not rebuilt unless you ask.

```bash
./setup.sh -y 15               # non-interactive: needs a filled-in config already
./setup.sh --help
```

What step 1 does: verifies the CPU exposes VT-x/SVM, loads and persists the
matching KVM module, enables the `universe` component if a package needs it,
installs the host packages, ensures NTP is running (a drifting clock shows up as
a GitHub App auth failure with no obvious cause), enables `nftables.service`,
creates the `gha` user and state dirs, and writes the config skeleton.

Prefer the individual steps? `gha-vm.sh` still exposes `deps`, `image`, `net`,
`doctor`, `repair`, `capacity`, `install <n>` on their own, in that order, plus
`bootstrap [n]` to chain them without prompts.

When preflight fails, `setup.sh` runs `gha-vm.sh repair` and re-checks before
asking you anything. `repair` fixes only what has one correct answer: loading
the KVM module, adding the `gha` user to the `kvm` group (retriggering udev if
the device node predates it), recreating the state directories, tightening
`config.env` and the app key to `root:gha 0640`, and installing the nftables
ruleset. Anything needing a decision -- credentials, scope, a public repo -- it
leaves for you.

`install` copies both scripts to `/usr/local/lib/gha-vm/` and points the units
there, so the units do not depend on this checkout. **Re-run `install` after
changing either script, and `image` after changing `gha-job.sh`** — the guest
side is baked into the golden image.

## Surviving a reboot

Everything comes back on its own. `install` enables `gha-vm@1..N.service` under
`multi-user.target`, so each slot restarts at boot and `Restart=always` brings a
slot back if its supervisor ever dies. The KVM modules are pinned in
`/etc/modules-load.d/gha-vm.conf`, the isolation rules are included from
`/etc/nftables.conf` with `nftables.service` enabled, and the weekly image
rebuild timer is `Persistent=true`, so it catches up after downtime.

Two things make an unclean shutdown safe rather than merely survivable:

- Each slot deletes its own leftover overlay at startup. Without that, every
  hard reboot would strand one disk image per slot, forever.
- Each unit runs `gha-vm.sh netcheck` as root before starting (`ExecStartPre=+`).
  If the nftables rules are missing, the slot refuses to start instead of
  running untrusted jobs with no isolation. Set `REQUIRE_ISOLATION=0` to
  override, deliberately.

Jobs in flight at shutdown are lost — the runner is ephemeral and GitHub reports
the job as failed. Nothing is corrupted; the next VM is a fresh clone.

## Sizing two machines

`capacity` takes the smaller of the memory, CPU and disk limits, then applies
the profile's `MAX_SLOTS` ceiling if it set one:

```
memory   (RAM − HOST_RESERVE_GB) / VM_MEM
cpu      cores × CPU_OVERCOMMIT / VM_CPUS
disk     free under STATE_DIR / DISK_PER_SLOT_GB
```

`HOST_RESERVE_GB` is a floor, not the answer. With `AUTOTUNE=1` (default) it is
raised to cover whatever is resident when `capacity` runs, so a machine that
also serves other workloads is sized on its real spare memory. The VMs run
`virtio-balloon` with free-page-reporting, so an idle runner hands its unused
pages back to the host — the memory figure is the worst case where every slot
is running a heavy job at once.

Ask any host what it decided:

```bash
gha-vm profile
```

### The two plans

| | dedicated CI box | `services` |
|---|---|---|
| hardware | 128 GB, bare metal | 24 vCPU / 46 GB, QEMU guest |
| already resident | ~nothing | ~18 GB (llama-server, minio, clamd, containers) |
| autotuned reserve | ~8 GB | ~23 GB |
| per slot | 4 vCPU / 8 GB / 30 GB | 4 vCPU / 8 GB / 30 GB |
| **slots** | **~15**, memory-bound | **2**, capped by `MAX_SLOTS` |
| profile file | none needed | `profiles/services.env` |

The dedicated box needs no profile — autotune already lands on the right
number. `services` gets one because two slots is a *policy* about a machine
that has another job, which no amount of hardware inspection can infer. It is
also a QEMU guest, so its runner VMs nest; `capacity` says so rather than
letting the extra latency look like a broken image.

### Host profiles

`deps` installs `profiles/*.env` to `/etc/gha-vm/profiles/`; each host loads the
one matching `HOST_PROFILE`, then `<machine-id>.env`, then `<hostname>.env`,
then `default.env`. Profiles are sourced **after** `config.env`, so sizing set
there wins — keep credentials and scope in `config.env`, sizing in a profile.
`setup.sh` notices an active profile and writes your sizing answers into it
rather than into `config.env`, where they would be silently overridden.
Details and a template: `profiles/README.md`.

Both machines can share one org-level runner pool. Runner names and the
nftables rules are per-host, so the two never touch each other's registrations.
The host's short hostname is added as a runner label automatically, so a
workflow can pin a machine with `runs-on: [self-hosted, <hostname>]`.

## Operating

```bash
gha-vm status                  # slots, live VMs, registered runners
journalctl -fu 'gha-vm@*'      # live guest consoles
gha-vm capacity
gha-vm profile                 # which machine am I, what sizing did it pick
sudo gha-vm repair             # fix the mechanically-fixable preflight items
sudo gha-vm install 20         # resize the fleet (also disables surplus slots)
sudo gha-vm reap               # delete stale offline registrations
sudo gha-vm uninstall          # stop and remove units
```

A weekly timer runs `gha-vm upgrade`, which pins the latest runner release in
the config and rebuilds the golden image. Leave it on: GitHub refuses runners
more than 30 days behind. Running slots adopt a new image when their current VM
finishes, so a rebuild never interrupts a job.

## Isolation details

`gha-vm.sh net` installs an nftables `output` chain matching on the `gha` uid:

- **Host loopback is blocked.** QEMU's user-mode networking maps the guest's
  gateway (10.0.2.2) onto the host's `127.0.0.1`, so without this rule every
  service bound to host loopback is reachable from inside a job.
- **RFC1918 and link-local are blocked** — your LAN, and the 169.254.169.254
  metadata range.
- **DNS is punched through** to the nameservers in `resolv.conf`, port 53 only.

This also blocks a LAN apt mirror or an internal registry. Add accept rules
above the drops in `/etc/gha-vm/nftables.conf` if you need one.

`doctor` fails loudly when the repo or org is public: a fork PR on a public repo
runs attacker-authored code on your hardware. Use a private repo, or restrict
the runner group to private repos.

Nested virtualization is not exposed to guests (`NESTED_VIRT=0`). It widens the
KVM attack surface that the whole isolation model rests on. Turn it on only if a
workflow genuinely needs it.

KSM is deliberately left off. It would dedupe memory across identical guests,
but merging pages between VMs running untrusted job code is a cross-VM
information leak, and the balloon already recovers idle memory. The guests do
share the golden image's page cache through the backing file, which is where
most of the duplication is anyway.

## Failure handling

- A VM that never reaches the runner is killed after `BOOT_TIMEOUT` (7 min) and
  its last 20 console lines are logged, instead of holding a slot for 6 hours.
- A VM is killed after `MAX_LIFETIME` (6 h, matching GitHub's own job limit).
- `-no-reboot` means a guest that panics and reboots exits instead of looping.
- Repeated short or never-ready cycles back off up to 60 s.
- A slot refuses to start a VM below `MIN_FREE_GB` free space rather than
  filling the disk.
- `flock` per slot stops a hand-started supervisor racing the systemd one.
- Each slot reaps only its *own* stale registrations. A host-wide reap here
  would race a sibling slot whose runner is registered but still booting — it
  reads as "offline", and deleting it invalidates that slot's live JIT config.

## Files

| Path | What |
|---|---|
| `setup.sh` | guided installer; the normal way in |
| `gha-vm.sh` | host supervisor, image builder, installer |
| `gha-job.sh` | runs inside the guest; takes one job, powers off |
| `config.vm.env.example` | annotated config, installed to `/etc/gha-vm/config.env` |
| `profiles/*.env` | per-host sizing, installed to `/etc/gha-vm/profiles/` |
| `/var/lib/gha-vm/golden.qcow2` | golden image, backing file for every overlay |
| `/var/lib/gha-vm/run/<name>/` | one live VM: overlay, seed, UEFI vars, console log |
