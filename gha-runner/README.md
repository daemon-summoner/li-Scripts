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
- x86_64 is what runs in production. aarch64 hosts are parametrized end to end
  (arm64 runner, arm64 cloud image, `qemu-system-aarch64` with AAVMF firmware)
  but untested; expect to touch `QEMU_MACHINE` or the firmware paths.
- GitHub Enterprise Server works by setting `GITHUB_SERVER_URL`; the API URL
  follows as `<server>/api/v3`. Runner tarballs still download from github.com
  unless `RUNNER_DOWNLOAD_BASE` points at a mirror (https only). A server on
  the LAN is reachable through the isolation rules without further config
  (see Isolation details); a separate blob store for artifacts and caches on
  the LAN needs `NET_ALLOW_CIDRS`.

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
host dependencies, GitHub connection, VM size (including a bigger slot 1 and
the memory overcommit, see [Shared fleet memory](#shared-fleet-memory)), golden
image, network isolation, slot count — validating each answer as you go and
defaulting the slot count to what the machine can actually carry. Have the GitHub App ID and its `.pem` handy;
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

`install` copies both scripts (plus the example config and `profiles/`) to
`/usr/local/lib/gha-vm/` and points the units there, so the units and the
weekly upgrade do not depend on this checkout. **Re-run `install` after
changing either script, and `image` after changing `gha-job.sh`** — the guest
side is baked into the golden image.

## Surviving a reboot

Everything comes back on its own. `install` enables `gha-vm@1..N.service` under
`multi-user.target`, so each slot restarts at boot and `Restart=always` brings a
slot back if its supervisor ever dies. The KVM modules are pinned in
`/etc/modules-load.d/gha-vm.conf`, the isolation rules are included from
`/etc/nftables.conf` with `nftables.service` enabled, and the weekly image
rebuild timer is `Persistent=true`, so it catches up after downtime.

The slot unit orders itself after `network-online.target`, `nftables.service`
and `time-sync.target`, and `deps` enables `systemd-time-wait-sync` so the last
one means "clock is synced" rather than "timesyncd started". A GitHub App JWT
carries a timestamp GitHub checks, and a slot that mints one before NTP has
settled fails with an auth error that looks like a bad key; the supervisor also
waits up to `CLOCK_SYNC_WAIT` on its own in case the target is not there.

What happens when something is not ready at boot:

- The isolation rules are self-healing. `netcheck` runs as root before each
  slot (`ExecStartPre=+`); if the `inet gha` table is missing it loads
  `/etc/gha-vm/nftables.conf` itself and logs that it did, then refreshes the
  resolver, host-address and endpoint sets from the live system, so a DHCP
  change or a new resolver never leaves stale accept rules. A set whose
  discovery comes back empty (resolver down at boot) keeps its previous
  elements rather than losing them. Only when the ruleset file is gone too
  does the slot refuse to start (`REQUIRE_ISOLATION=0` overrides that,
  deliberately).
- A supervisor that fails to mint a JIT config five times in a row exits so
  the unit restarts it; the restart re-runs `netcheck`, which is the repair
  for the one host-side cause (sets stale since the last refresh because a
  resolver or endpoint moved).
- A missing golden image is waited for, not fatal: the supervisor logs once and
  polls every 60 s, so a slot enabled before the first `image` run comes up on
  its own when the image lands.
- Restarts back off. `RestartSteps=8` / `RestartMaxDelaySec=300` (systemd 254+;
  `doctor` says when the host is older) stretch the retry gap from 5 s to 5 min
  so a persistent failure does not spin the journal. JIT registration failures
  back off inside the loop the same way, up to `JIT_BACKOFF_MAX`.
- Each slot deletes its own leftover overlay at startup. Without that, every
  hard reboot would strand one disk image per slot, forever.

Shutdown and reboot are graceful. A slot with a job in flight gets
`STOP_GRACE_SEC` (15 min) for the job to finish before the VM is killed. A
slot whose runner is registered but has no job is stopped at once: its runner
is deregistered first, which GitHub refuses for a busy runner, so a job handed
out at that moment still gets its grace period. A slot has a job once the
runner prints `Running job:` on the console. The
unit's `TimeoutStopSec` is that plus 120 s (VM kill, then the bounded deregistration call). On any exit the supervisor's trap
kills its QEMU, deregisters the slot's runner from GitHub (`REAP_ON_STOP=1`)
and removes the run directory. What the trap cannot catch (`kill -9`, power
loss) the next start cleans up: leftover run directories are deleted and the
slot's stale registrations reaped before the first VM boots. Either way no
orphan process, offline runner, or stray disk survives. A job that outlives the
grace period is reported failed by GitHub; nothing is corrupted.

To take a slot out of rotation without killing anything:

```bash
sudo gha-vm drain 3            # finish the current job, then idle
sudo gha-vm undrain 3
sudo gha-vm restart all        # drain every slot, restart its unit, undrain
```

`restart` is what to run after editing `gha-vm.sh` and re-running `install`.
It drains every slot up front, restarts idle ones at once and busy ones as
their job finishes (up to `STOP_GRACE_SEC`); `gha-vm fleet` shows which is
which. An idle slot's VM is stopped by `restart` itself after its runner is
deregistered, so a supervisor still running an older script never holds the
restart for its grace period. `setup.sh` offers this restart when it finds
slots already running.
The supervisor also notices when its own script file changes on disk and
re-execs itself between jobs, so a plain `install` is picked up without a
restart; `restart` only matters when the unit file itself changed.

### Host updates

`deps` installs `unattended-upgrades` and writes
`/etc/apt/apt.conf.d/52gha-vm` enabling daily security updates
(`HOST_UNATTENDED=1`). Reboots for kernel or libc updates are opt-in:
`HOST_AUTO_REBOOT=1` sets `Automatic-Reboot` at `HOST_AUTO_REBOOT_TIME`
(04:30), and because shutdown drains slots, a job that is running at that
moment gets its `STOP_GRACE_SEC` before the machine goes down. `repair`
re-applies the policy if the file drifts from the config.

## Sizing two machines

`capacity` takes the smaller of the memory, CPU and disk limits, then applies
the profile's `MAX_SLOTS` ceiling if it set one:

```
memory   slots 1, 2, ... at their own sizes, until their sum passes
         FLEET_MEM × MEM_OVERCOMMIT_PCT / 100   (FLEET_MEM=auto: RAM − HOST_RESERVE_GB)
cpu      slots 1, 2, ... at their own vCPUs, until their sum passes cores × CPU_OVERCOMMIT
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

### Shared fleet memory

Every slot VM draws from one budget, `FLEET_MEM` (default `auto`: RAM minus
`HOST_RESERVE_GB`), instead of owning a fixed share. A slot can be bigger or
smaller than the rest, and can carry its own labels so workflows can ask for it:

```bash
FLEET_MEM=24G
VM_MEM=8G
VM_MEM_1=16G                  # slot 1 is the big one
RUNNER_LABELS_EXTRA_1=large   # runs-on: [self-hosted, large]
MEM_OVERCOMMIT_PCT=200        # capacity may plan 16G + 4 x 8G into 24G
```

A slot registers a runner only when what the VMs really hold (resident memory
and swap, not page cache) plus that slot's full size fits in the budget.
Otherwise it waits, first come first served, and says why in the journal and in
`gha-vm fleet`. Nothing is registered while it waits, so GitHub cannot hand it a
job the host has no room for. A VM that has just started counts at its full size
for 5 minutes, which stops several slots that free up together from all taking
the same gap. Idle guests hand unused pages back through `virtio-balloon`
free-page-reporting, so light jobs leave room for more slots.

Admission cannot stop a VM that is already running from growing into its full
size. That growth is bounded by the kernel. All slot units run in
`ghavm.slice`, which `install` renders with:

- `MemoryHigh` at the budget. Past it the kernel reclaims and swaps inside the
  slice, so the jobs slow down and the host keeps its reserve. `deps` sets up
  zram swap for this (`HOST_ZRAM=1`); without swap the kernel can only drop
  page cache before it has to kill something.
- `MemoryMax` a margin above the budget (1/16 of it, at least 2 GB) to cover
  QEMU's own overhead. A fleet that still outgrows that loses one VM to the OOM
  killer.

Each slot also keeps its own `MemoryMax` of its size plus 2 GB. A slot with
`VM_MEM_<n>` gets that limit from a drop-in, `gha-vm@<n>.service.d/`.

`FLEET_MEM=off` turns off both the slice limits and the admission wait. With it
off, the slot count is back to a worst-case partition of the host.

```bash
gha-vm fleet      # budget, use, and each slot: busy, idle, waiting (and why), drained
```

After changing `FLEET_MEM` or a `VM_MEM_<n>`, re-run `sudo gha-vm install` to
push the new limits into systemd. The slice takes them at once. Slots take a new
per-slot size at their next restart (`gha-vm restart all`).

### The two plans

| | dedicated CI box | `services` |
|---|---|---|
| hardware | 128 GB, bare metal | 24 vCPU / 46 GB, QEMU guest |
| already resident | ~nothing | ~18 GB (llama-server, minio, clamd, containers) |
| autotuned reserve | ~8 GB | ~23 GB |
| per slot | 4 vCPU / 8 GB / 30 GB | 4 vCPU / 8 GB / 30 GB |
| **slots** | **~15**, memory-bound | **5**, 16G + 4 × 8G at 200% of `FLEET_MEM=24G` |
| profile file | none needed | `profiles/services.env` |

The dedicated box needs no profile — autotune already lands on the right
number. `services` gets one because its fleet memory budget and big slot 1
are *policy* about a machine that has another job, which no amount of hardware
inspection can infer. It is
also a QEMU guest, so its runner VMs nest; `capacity` says so rather than
letting the extra latency look like a broken image.

### Host profiles

`deps` installs `profiles/*.env` to `/etc/gha-vm/profiles/`; each host loads
one of them: `<HOST_PROFILE>.env` when `HOST_PROFILE` is set, otherwise
`<machine-id>.env` if it exists, otherwise `<hostname>.env`; `default.env`
stands in when the chosen file is absent, and `local.env` is sourced last
regardless. Profiles are sourced **after**
`config.env`, so sizing set there wins — keep credentials and scope in
`config.env`, sizing in a profile. `local.env` is this host's own override
layer: `deps` never touches it, and `setup.sh` writes your sizing answers there
so a later `deps` reinstalling the profiles does not undo them. Details and a
template: `profiles/README.md`.

Both machines can share one org-level runner pool. Runner names and the
nftables rules are per-host, so the two never touch each other's registrations.
The host's short hostname is added as a runner label
(`RUNNER_LABELS_APPEND_HOST=1`, also on a custom `RUNNER_LABELS`), so a
workflow can pin a machine with `runs-on: [self-hosted, <hostname>]`. Runner
groups can be named (`RUNNER_GROUP=ci-private`) instead of numbered; each
supervisor looks the id up once, at its first registration.

## Operating

```bash
gha-vm status                  # slots, live VMs, registered runners
journalctl -fu 'gha-vm@*'      # live guest consoles
gha-vm capacity
gha-vm fleet                   # shared memory: budget, use, slots waiting for room
gha-vm profile                 # which machine am I, what sizing did it pick
gha-vm config [KEY]            # effective config after profile, local.env, defaults
sudo gha-vm repair             # fix the mechanically-fixable preflight items
sudo gha-vm install 20         # resize the fleet (also disables surplus slots)
sudo gha-vm drain 2            # finish the current job, then take no more
sudo gha-vm restart all        # drain, restart units, undrain
sudo gha-vm reap               # delete stale offline registrations
sudo gha-vm clean              # remove leftover run dirs (skips live slots; --force)
sudo gha-vm uninstall          # stop and remove units
```

`config` prints the resolved value of every knob (the PAT is masked in the
listing; `config GITHUB_PAT` prints it raw), which is the quickest way to see
what a profile or `local.env` actually changed.

### Upgrades

A weekly timer runs `gha-vm upgrade`, which pins the latest runner release in
the config and rebuilds the golden image. Leave it on: GitHub refuses runners
more than 30 days behind. Running slots adopt a new image when their current VM
finishes, so a rebuild never interrupts a job. With `UPGRADE_REBUILD=always`
(default) the image is rebuilt even when the runner version did not move, so
Ubuntu package updates inside the guest are never more than a week old.

The rebuild cannot leave the fleet on a broken image:

- The cloud image cache is re-verified against Ubuntu's signed `SHA256SUMS` on
  every build and re-downloaded on mismatch; the runner tarball hash is taken
  from the release notes and pinned as `RUNNER_SHA256`.
- `IMAGE_SELFTEST=1` boots the new image once, with a self-test seed instead of
  a JIT config, and waits for the guest to start its runner binary and print
  `GHA-VM: selftest ok`. No marker within `BOOT_TIMEOUT` means the build fails
  with the last console lines in the journal and the current golden image is
  untouched.
- The outgoing image is kept as `golden.qcow2.prev` (`GOLDEN_KEEP_PREVIOUS=1`).
  `sudo gha-vm rollback` swaps it back; running it again swaps forward.

```bash
sudo gha-vm upgrade --check    # what the timer would do, no writes
sudo gha-vm upgrade            # do it now
sudo gha-vm rollback
```

`RUNNER_VERSION` is pinned in whichever file currently sets it, normally
`config.env`; if a profile or `local.env` overrides it, `upgrade` pins there
instead and says so. The previous file is kept as `.bak` beside it.

### Verifying an upgrade

After pulling a new `gha-vm.sh` onto a host, in this order:

```bash
sudo gha-vm doctor
sudo gha-vm install                           # keeps the installed slot count
systemd-analyze verify 'gha-vm@1.service' gha-vm-upgrade.service gha-vm-upgrade.timer
systemctl show gha-vm@1 -p RestartSteps -p TimeoutStopSec -p After
sudo nft -c -f /etc/nftables.conf && sudo nft list table inet gha   # sets populated
sudo gha-vm restart all
journalctl -u 'gha-vm@*' --since -5m           # every slot reaches "up after"
sudo gha-vm upgrade --check
```

Then one deliberate failure of each kind, to see the recovery paths work on
this host rather than in this README: `sudo nft delete table inet gha` followed
by `systemctl restart gha-vm@1` should log that netcheck loaded the rules
itself; `sudo reboot` should bring every slot back with the `inet gha` table
present before the first job; `systemctl stop gha-vm@1` during a job should
wait for the job rather than kill it.

## Moving workflows onto the fleet

Nothing routes here automatically. `runs-on:` is the only selector, and a
GitHub-hosted label never falls through to a self-hosted runner. The runners
register with these labels:

```
self-hosted, linux, x64, vm, ephemeral, docker, <short hostname>
```

(`arm64` in place of `x64` on an aarch64 host, and `kvm` added on a host with
`NESTED_VIRT=1`; see Nested virtualization.)

`adopt-runners.py` sweeps a directory of repos and reports every job that could
move, plus every step that would break on the golden image. It writes nothing
without `--apply`, and `--apply` skips any repo with uncommitted changes — git
is the undo.

```bash
./adopt-runners.py                                  # audit ~/Projects (the default root)
./adopt-runners.py --apply                          # rewrite runs-on to [self-hosted, linux, x64]
./adopt-runners.py --apply --label self-hosted,develop
./adopt-runners.py --arch arm64                     # an aarch64 fleet
./adopt-runners.py ~/work                           # sweep a different directory
```

It edits only the `runs-on` line, leaving comments and formatting byte-identical,
and refuses anything it cannot rewrite unambiguously — `${{ matrix.os }}`, the
`group:`/`labels:` mapping, a list mixing hosted and custom labels, a block
list carrying comments, or a hosted image for the other CPU family
(`ubuntu-24.04-arm` on an x64 fleet). Those are listed as `MANUAL`. Exit status is 1 when any
job has a blocker, so it works as a CI check. Needs `ruamel.yaml`
(`apt install python3-ruamel.yaml` on Debian/Ubuntu, `pip install ruamel.yaml`
elsewhere; the script prints the exact command for its interpreter when missing).

The blockers it knows about, all of them things GitHub-hosted provides and this
image does not:

| Blocker | Why |
|---|---|
| `sudo` | the guest `runner` user is created with `-G docker,kvm` only |
| node / pip / go / java / dotnet / rust | not installed; add the matching `actions/setup-*` |
| `aws`, `az`, `gcloud`, `kubectl`, `helm`, `terraform` | not installed |
| nested virt | Android emulator, `vagrant`, `qemu-system-x86_64` — `NESTED_VIRT=0`; not reported for a job whose `runs-on` includes `kvm` |

A job already calling the right `actions/setup-*` is not flagged for it, and a
`container:` job is only checked for nested virt, since its steps run inside its
own image.

One org variable makes the whole fleet switchable without touching workflows
again — set `CI_RUNNER` under *Org → Settings → Secrets and variables → Actions*
and use `runs-on: ${{ vars.CI_RUNNER }}`. Flipping it back to `ubuntu-latest`
moves everything to GitHub's runners while the box is down for a rebuild.

## Isolation details

`gha-vm.sh net` installs an nftables `output` chain matching on the `gha` uid:

- **Host loopback is blocked.** QEMU's user-mode networking maps the guest's
  gateway (10.0.2.2) onto the host's `127.0.0.1`, so without this rule every
  service bound to host loopback is reachable from inside a job.
- **RFC1918 and link-local are blocked** — your LAN, and the 169.254.169.254
  metadata range.
- **The host's own public addresses are blocked** (`NET_BLOCK_HOST_ADDRS=1`),
  so a service bound to the host's external IP is no more reachable than one on
  loopback.
- **CGNAT, multicast, benchmarking, reserved and broadcast ranges are blocked**
  (`NET_BLOCK_EXTRA=1`) — the ranges a VPN or a container network on the host
  tends to sit in.
- **DNS is punched through** to the host's resolvers, port 53 only.
- **The GitHub endpoints and proxies are punched through**, each on the one
  TCP port its URL names (443 or 80 by scheme when it names none): whatever
  `GITHUB_SERVER_URL`, `GITHUB_API_URL`, `RUNNER_DOWNLOAD_BASE`,
  `HTTPS_PROXY`/`HTTP_PROXY` and `GUEST_HTTP_PROXY` resolve to. For github.com
  that changes nothing; for a GitHub Enterprise Server or a proxy inside a
  blocked range it is what lets the runner register at all, without opening
  the rest of that server. A `GUEST_HTTP_PROXY` at the gateway address
  `10.0.2.2` is the host's loopback, so that proxy port and only that port
  opens on `127.0.0.1`. Pin the addresses with `NET_ENDPOINT_ADDRS`
  (`ADDR[:PORT]`, `[V6]:PORT`) if resolution is not to be trusted.
- The resolver, host-address and endpoint lists live in named sets that
  `netcheck` refreshes from the live system at every slot start, so they
  follow DHCP, resolver and DNS changes instead of freezing at the moment
  `net` ran.

An exception for a LAN apt mirror or an internal registry is one line of
config, not a hand edit to the ruleset (which `net` regenerates):

```
NET_ALLOW_CIDRS=10.20.0.5/32,fd00:20::5/128
```

Allowed CIDRs are accepted before any drop rule. Re-run `sudo gha-vm net` after
changing them.

Every QEMU runs under its seccomp sandbox (`-sandbox on` with obsolete
syscalls, privilege elevation, process spawning and resource control denied;
`QEMU_SANDBOX=0` to disable) with `-nodefaults`, so a VM escape into the QEMU
process still lands in a process that cannot fork or raise privileges. GitHub
tokens never appear on a command line: they go to curl on stdin, and every
call is pinned to HTTPS with TLS 1.2 or later.

### Guest customization

- `GUEST_EXTRA_PACKAGES` adds apt packages to the image on top of the base set.
- `IMAGE_HOOK_DIR` (`/etc/gha-vm/image.d/*.sh`) runs each executable script
  inside the image build as root, after packages, with `GUEST_HTTP_PROXY`
  exported, for anything apt cannot express: a toolchain tarball, a CA
  certificate, a registry login.
- `GUEST_PRE_JOB_HOOK` is a script baked in as `/usr/local/bin/gha-pre-job.sh`
  and run as root on every boot before the runner starts. A non-zero exit
  refuses the job. The self-test boot runs it too, so a broken hook fails the
  image build rather than every job after it.
- `GUEST_HTTP_PROXY` bakes a proxy into `/etc/environment`, apt and dockerd
  inside the guest; `HTTPS_PROXY` / `NO_PROXY` on the host side cover the API
  calls and the image build. `GUEST_RUNTIME_DNS` pins the guest's resolvers.

Re-run `sudo gha-vm image` after changing any of these; they are baked in.

`doctor` fails loudly when the repo or org is public: a fork PR on a public repo
runs attacker-authored code on your hardware. Use a private repo, or restrict
the runner group to private repos.

KSM is deliberately left off. It would dedupe memory across identical guests,
but merging pages between VMs running untrusted job code is a cross-VM
information leak, and the balloon already recovers idle memory. The guests do
share the golden image's page cache through the backing file, which is where
most of the duplication is anyway.

### Nested virtualization

Nested virtualization is not exposed to guests (`NESTED_VIRT=0`). It widens the
KVM attack surface that the whole isolation model rests on. Turn it on only if a
workflow genuinely needs it, such as an Android emulator job, and only on a
bare-metal x64 host: a host that is itself a VM would put the emulator at a
third level.

The image is always ready for it. The guest `runner` user is in the `kvm`
group, and the image carries the libraries the Android emulator loads that the
Ubuntu cloud image lacks (`libxi6 libpulse0 libxkbfile1 libgbm1 libsm6
libice6`). Enabling it on one host:

```bash
echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/gha-vm-nested.conf   # kvm_amd on AMD
echo NESTED_VIRT=1 | sudo tee -a /etc/gha-vm/profiles/local.env
sudo reboot        # reloads kvm with the option; slots drain first and return on their own
sudo gha-vm doctor # nested virt: OK
```

Current kernels already default both modules to `nested=1`; the modprobe file
keeps it pinned. When `doctor` already reports the module OK, `sudo gha-vm
restart all` is enough instead of the reboot.

Runners on that host then register with an extra `kvm` label (`gha-vm profile`
prints the labels), and emulator jobs ask for it, so they never land on a host
without KVM:

```yaml
runs-on: [self-hosted, linux, x64, kvm]
```

## Failure handling

- A VM that never reaches the runner is killed after `BOOT_TIMEOUT` (7 min) and
  its last 20 console lines are logged, instead of holding a slot for 6 hours.
- A VM is killed after `MAX_LIFETIME` (6 h, matching GitHub's own job limit).
- `-no-reboot` means a guest that panics and reboots exits instead of looping.
- Repeated short or never-ready cycles back off up to 60 s; JIT registration
  failures back off 30 s, 60 s, ... up to `JIT_BACKOFF_MAX` (10 min), with the
  HTTP status and any `retry-after` in the journal.
- A slot refuses to start a VM below `MIN_FREE_GB` free space rather than
  filling the disk.
- A slot does not register a runner until its VM fits in the fleet memory
  budget (see "Shared fleet memory"). A VM the kernel OOM-kills, because it
  passed its slot's `MemoryMax` or the fleet passed the slice's, is logged as
  `oom-killed` and deregistered. The unit keeps running (`OOMPolicy=continue`)
  and the slot starts a fresh VM.
- `flock` per slot stops a hand-started supervisor racing the systemd one, and
  `clean` refuses to touch a directory whose slot lock is held.
- Each slot reaps only its *own* stale registrations, immediately after a
  failed boot and otherwise every `REAP_INTERVAL`. A host-wide reap here would
  race a sibling slot whose runner is registered but still booting — it reads
  as "offline", and deleting it invalidates that slot's live JIT config. An
  API failure during a reap is logged and skipped, never read as "no runners".
- `doctor` warns when the golden image is older than `GOLDEN_MAX_AGE_DAYS`,
  when the API is unreachable (public-repo checks report UNKNOWN rather than
  OK), and when systemd is too old for `RestartSteps`.

## Tests

```bash
tests/run.sh             # lint, then render + verify in docker (ubuntu:26.04)
tests/run.sh --update    # regenerate tests/expected after an intended change
```

The suite syntax-checks and shellchecks every script, then inside a throwaway
container renders the systemd units and the nftables ruleset from
`tests/config.test.env`, diffs them against `tests/expected/`, runs
`systemd-analyze verify` and `nft -c` on the result, and exercises the atomic
config editor (`config-set` / `config-unset`) that `setup.sh` and `upgrade`
use. It also checks the fleet memory render (slice, per-slot drop-ins, invalid
settings refused) and `capacity`'s per-slot counting. Admission order and
fleet accounting are checked against a fixture cgroup tree via
`GHA_CGROUP_ROOT`. Without docker it runs the lint half and says so. Anything involving KVM
— booting a VM, a reboot, the drain — can only be verified on a host; see
"Verifying an upgrade".

## Files

| Path | What |
|---|---|
| `setup.sh` | guided installer; the normal way in |
| `gha-vm.sh` | host supervisor, image builder, installer |
| `gha-job.sh` | runs inside the guest; takes one job, powers off |
| `adopt-runners.py` | audits a tree of repos for workflows that can move here |
| `config.vm.env.example` | annotated config, installed to `/etc/gha-vm/config.env` |
| `profiles/*.env` | per-host sizing, installed to `/etc/gha-vm/profiles/` |
| `tests/` | render/verify suite and its expected units and ruleset |
| `/etc/gha-vm/profiles/local.env` | this host's overrides; never rewritten by `deps` |
| `/etc/gha-vm/image.d/*.sh` | image build hooks (`IMAGE_HOOK_DIR`) |
| `/etc/gha-vm/env` | optional `KEY=value` lines the units load as environment; wins over every config file, only for the slot and upgrade units |
| `/etc/gha-vm/nftables.conf` | generated isolation ruleset, included from `/etc/nftables.conf` |
| `/var/lib/gha-vm/golden.qcow2` | golden image, backing file for every overlay |
| `/var/lib/gha-vm/golden.qcow2.prev` | the previous golden image, for `rollback` |
| `/var/lib/gha-vm/run/<name>/` | one live VM: overlay, seed, UEFI vars, console log |
| `/var/lib/gha-vm/run/.slot-<n>.drain` | drain flag; the slot idles while it exists |
| `/var/lib/gha-vm/run/.slot-<n>.wait` | the slot is waiting for fleet memory, since this epoch |
| `/var/lib/gha-vm/run/.slot-<n>.claim` | memory a just-started VM may still grow into, counted for 5 min |
| `/etc/systemd/system/ghavm.slice` | the fleet's shared memory ceiling (`FLEET_MEM`) |
| `/etc/systemd/system/gha-vm@<n>.service.d/50-gha-vm-size.conf` | per-slot `MemoryMax` from `VM_MEM_<n>` |
| `/etc/systemd/zram-generator.conf` | zram swap (`HOST_ZRAM`), written only when absent or ours |
