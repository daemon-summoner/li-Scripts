<div align="center">

<img src=".github/assets/banner.svg" alt="li-Scripts — one tidy toolbox for Linux & macOS" width="100%">

<br/>

[![Shell](https://img.shields.io/badge/shell-bash-121011?style=for-the-badge&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platforms](https://img.shields.io/badge/platforms-Linux%20·%20macOS%20·%20WSL-3b82f6?style=for-the-badge)](#-whats-inside)
[![Commands](https://img.shields.io/badge/commands-22-8b5cf6?style=for-the-badge)](#-commands)
[![ShellCheck](https://img.shields.io/badge/shellcheck-clean-22c55e?style=for-the-badge&logo=gnubash&logoColor=white)](tests/run.sh)
[![PRs](https://img.shields.io/badge/PRs-welcome-ec4899?style=for-the-badge)](#-contributing)

**A personal collection of helper scripts, cleaned up and made to feel like one tool.**<br/>
One entry point. One design language. The right OS handled for you.

</div>

---

## 🪄 The gist

This repo grew for years — setup scripts, disk tools, network helpers, a few security-research demos — and got messy. It's been reworked into a single, coherent toolbox:

- **One front door.** Run `./li` by itself for an interactive menu — pick a number and it runs. Know the name? `./li <command>`. Every script still works on its own too.
- **Cross-platform by default.** The same commands do the right thing on **Ubuntu/Debian**, **macOS**, and **WSL** — no separate scripts to keep in sync.
- **Shared foundation.** Color, logging, prompts, atomic writes, and OS detection live in `lib/`, so every script reads the same way.
- **Your details, not mine.** Personal values (git identity, SSH key, hosts) come from a `config.env` you control — nothing personal is baked into a script.

---

## 🚀 Quick start

```bash
git clone https://github.com/Sellitus/li-Scripts.git
cd li-Scripts

./li                 # interactive menu — pick a command and it runs
./li <command>       # run one directly, e.g. ./li update
./li <command> --help   # help for any one of them
```

`setup.sh` is just one of those commands (`./li setup`) — the one that provisions a whole machine. For everything else, reach for `./li`.

Set up a fresh machine — the same command on either OS:

```bash
sudo ./setup.sh      # Ubuntu/Debian (provisions as root)
./setup.sh           # macOS (runs as your normal user)
```

On first run, `setup.sh` creates `config/config.env` from the sample and tells you where to edit your own git identity, keys, and hosts.

---

## 🧰 Commands

Run any of these as `./li <command>`. Platform notes in parentheses; everything else is cross-platform.

### ⚙️ setup
| Command | What it does |
|---------|--------------|
| `setup` | Set up this machine — detects the OS and runs the matching, modular setup |

### 🖥️ system
| Command | What it does |
|---------|--------------|
| `update` | Update system packages (apt / brew) |
| `cleanup-disk` | Reclaim disk space |
| `benchmark` | Quick system benchmark *(Linux)* |
| `swap-resize` | Resize the swap file *(Linux)* |
| `zero-free-space` | Zero free space to shrink disk images |
| `grub-repair` | Repair / reinstall GRUB *(Linux)* |
| `gpu-unlock` | Unlock NVIDIA 30/50-series limits *(Linux)* |
| `usb-windows11` | Make a bootable Windows 11 USB *(macOS)* |

### 🌐 network
| Command | What it does |
|---------|--------------|
| `scp` | Copy files to/from a configured host (scp) |
| `rsync` | Sync a folder to a configured host (rsync) |
| `ssh-keygen` | Generate an SSH key pair |
| `ufw-allow` | Allow a CIDR through UFW *(Linux)* |
| `wsl-to-desktop` | Copy files from WSL to the Windows desktop |

### 🧑‍💻 dev
| Command | What it does |
|---------|--------------|
| `docker` | Install Docker — Colima on macOS, apt on Linux |
| `kasm-install` | Install Kasm Workspaces |
| `kasm-uninstall` | Uninstall Kasm Workspaces |
| `claude-resume` | Resume the latest Claude Code session |

### 🛡️ security *(authorized use only — see [`security/`](security/README.md))*
| Command | What it does |
|---------|--------------|
| `ap-search` | Scan for Wi-Fi access points |
| `ap-monitor` | Monitor a Wi-Fi access point |
| `ap-deauth` | Send deauth frames to a client |
| `monitor-mode` | Put a Wi-Fi adapter into monitor mode |

---

## 🗂️ What's inside

<details>
<summary><b>Repository layout</b></summary>

```
li-Scripts/
├── li                  # dispatcher: ./li <command> [args]
├── setup.sh            # cross-platform entry → setup/linux.sh | setup/macos.sh
├── lib/                # shared helpers
│   ├── common.sh       #   colors, log/die/need, prompts, atomic writes, config
│   └── platform.sh     #   OS/arch detection, apt↔brew package abstraction
├── setup/
│   ├── linux.sh        # Ubuntu/Debian orchestration (menu + flags)
│   ├── macos.sh        # macOS orchestration
│   ├── files/          # shared dotfiles (bashrc, VS Code settings)
│   └── modules/        # one concern per file: shell, cli-tools, python, node,
│                       #   go, docker, editors, git-config, hardening, server,
│                       #   desktop, nvidia, kubernetes, macos-tweaks, …
├── config/
│   ├── config.env.example   # committed sample
│   └── config.env           # your live values (gitignored, self-seeded)
├── system/             # update, cleanup-disk, benchmark, swap, grub, gpu, usb
├── network/            # scp, rsync, ssh-keygen, ufw-allow, wsl-to-desktop
├── dev/                # docker, kasm, claude-resume, gha-runner/
├── security/           # Wi-Fi research demos + DuckyScript payloads
├── archive/            # old scripts, kept for reference (unmaintained)
└── tests/              # bash -n + shellcheck over the whole active tree
```

</details>

---

## 🧩 Setup, the short version

`setup.sh` detects the OS and hands off to the right orchestrator. Both share the same module set, so your Linux and macOS machines stay in step.

- **Pick what you want.** Choose from a numbered menu, or pass named flags (`--core`, `--security`, `--server`, `--basic`, `--vram`, …). Run just one piece with `--only <module>`, or hold one back with `--skip <module>`.
- **Defaults match the old behavior** — with one deliberate change: it no longer reboots you automatically. It asks, or you pass `--reboot` / `--no-reboot`.
- **Modular.** Shell, CLI tools, Python, Node, Go, Docker, editors, git config, and (on Linux) hardening, server, desktop, NVIDIA, and Kubernetes are each their own toggleable module.

```bash
sudo ./setup.sh --core --security     # Linux: base system + hardening
./setup.sh --basic                    # macOS: full developer environment
./setup.sh --only docker              # just the Docker module, either OS
```

---

## 🔧 Configuration

Personal details live in **`config/config.env`**, never in the scripts.

- A committed **`config.env.example`** shows every setting with a sensible sample value.
- On first run, the setup copies it to a gitignored **`config.env`** and prompts you to edit your own git identity, SSH key, remote hosts, and the like.
- Any value can also be overridden with an environment variable for a single run — the environment always wins over the file.

```bash
LI_SCP_HOST=10.0.0.5 ./li scp -s ./file.txt /remote/file.txt
```

---

## 🛡️ Security demos

The [`security/`](security/README.md) folder holds small Wi-Fi research tools and DuckyScript payloads, kept simple on purpose and meant to grow. **Run them only against hardware and networks you own or are explicitly authorized to test** — that's your responsibility. See the folder's README for the details and the house rules.

---

## 🧪 Development

Every script follows the same house style — `set -Eeuo pipefail`, self-documenting `--help`, a shared logging vocabulary, and idempotent writes — and the whole active tree is linted:

```bash
bash tests/run.sh    # bash -n on everything, shellcheck -x on the active tree
```

`gha-runner/` is a self-contained subproject with its own test suite; run it separately when you work on it.

---

## 🗃️ Archive

Older scripts that no longer fit the active set live in [`archive/`](archive/README.md). They're kept for reference and history, not maintained — read before running.

---

## 🙌 Contributing

This is a personal toolbox, but issues and pull requests are welcome. Keep new scripts in the house style, wire them into `li`, and make sure `bash tests/run.sh` stays green.

<div align="center">

<br/>

*Built to be read a year from now and still make sense.*

</div>
