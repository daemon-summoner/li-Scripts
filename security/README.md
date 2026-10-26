# security

Small, self-contained security-research demos. These are teaching and lab tools
kept deliberately simple so the technique is easy to read, and they are meant to
grow over time.

## Authorized use only

Everything here touches networks or machines directly. Run it **only** against
hardware and networks you own, or that you have explicit written permission to
test. Wi-Fi deauthentication, monitor-mode capture, and keystroke-injection
payloads are illegal to use against systems you do not control in most
jurisdictions. You are responsible for staying inside the law and inside your
rules of engagement. The authors provide these for education and authorized
testing, nothing else.

## Contents

### `kali/` — Wi-Fi research (Linux, needs a monitor-mode-capable adapter)

Thin wrappers over `aircrack-ng`. Run as root, on Kali or any distro with the
`aircrack-ng` suite installed.

| Script | What it does |
|--------|--------------|
| `enable_monitor_mode.sh` | Put a wireless interface into monitor mode (`airmon-ng`). |
| `ap_search.sh` | Scan the area for access points and their clients (`airodump-ng`). |
| `ap_monitor.sh` | Focus capture on one access point / channel. |
| `ap_deauth.sh` | Send deauthentication frames to a client on a target AP. |

Typical flow: enable monitor mode, scan to find a BSSID and channel, monitor
that AP, then exercise the deauth demo against a client you own.

### `duckyscript/` — USB Rubber Ducky payloads

Plain-text DuckyScript payloads for keystroke-injection demos (BadUSB-class
hardware). They are text, not executables — a Ducky-compatible device compiles
and replays them. The ones here are harmless Windows demonstrations (close the
foreground window, Alt+F4, open a hidden PowerShell) used to show how fast an
injection runs once a machine trusts the device.

## Notes

These are intentionally minimal. If you extend them, keep each script focused on
one clearly explainable technique, and keep the authorized-use expectation front
and center.
