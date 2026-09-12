#!/usr/bin/env python3
"""Audit every git repo under a directory for gha-vm self-hosted compatibility.

Usage: adopt-runners.py [ROOT] [--apply] [--arch x64|arm64] [--label L[,L...]]
                        [-q] [--no-blockers]
Reports jobs pinned to GitHub-hosted runners and steps that would break on the
golden image; --apply rewrites the movable `runs-on` lines in place.
"""

import argparse
import re
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path


def _ruamel_install_hint() -> str:
    """Install command for the interpreter that is actually running this script."""
    if shutil.which("apt"):
        return "sudo apt install python3-ruamel.yaml"
    cmd = f"{sys.executable} -m pip install ruamel.yaml"
    # PEP 668: Homebrew and Debian pythons refuse pip installs without this flag.
    if (Path(sysconfig.get_path("stdlib")) / "EXTERNALLY-MANAGED").exists():
        cmd += " --break-system-packages"
    return cmd


try:
    from ruamel.yaml import YAML
    from ruamel.yaml.error import YAMLError
except ImportError:
    sys.exit(
        "adopt-runners.py needs ruamel.yaml to locate `runs-on` accurately.\n"
        f"  {_ruamel_install_hint()}\n"
        "Regex would be enough for most files and would silently mangle the rest,"
        " which is not a trade worth making across every repo you own."
    )

# GitHub's Linux images, including the -arm variants and the dated pins. Only
# these are offered for rewriting, and only when the image's architecture is
# the one the fleet runs (--arch): a job is portable to this hardware exactly
# when it already expects Linux on the same CPU family.
HOSTED_LINUX = re.compile(r"^ubuntu-(?:latest|\d{2}\.\d{2})(?P<arm>-arm)?$")
FOREIGN = re.compile(r"^(?:windows|macos|macOS)-")
ARCHES = ("x64", "arm64")
# An opening bracket without its close, or a block scalar indicator.
CONTINUES = re.compile(r"^(\[(?!.*\]$)|\{(?!.*\}$)|[|>][-+0-9]*$)")


def unsafe_head(head):
    """Why a value cannot be replaced from its first line alone, or None.

    Only that line is known, so anything that continues below it, or that
    another job refers back to, would be cut in half by a rewrite.
    """
    if CONTINUES.match(head):
        return "value spans several lines"
    q = head[:1]
    if q in ('"', "'") and (
        len(head) < 2 or not head.endswith(q) or head.endswith("\\" + q)
    ):
        return "quoted value spans several lines"
    if q in ("&", "*", "!"):
        return "anchor, alias or tag on the value"
    return None


def hosted_arch(label):
    """Architecture a GitHub-hosted Linux label targets, or None if not hosted."""
    m = HOSTED_LINUX.match(label)
    if not m:
        return None
    return "arm64" if m.group("arm") else "x64"


# What `gha-vm.sh image` installs, plus the Ubuntu base. Anything a workflow
# reaches for that is not here fails at the first `run:` step that uses it.
# Each entry is (command, why it is missing, the remedy).
MISSING = [
    (
        ("node", "npm", "npx", "yarn", "pnpm"),
        "no Node toolchain on the image",
        (
            "add actions/setup-node (the runner's bundled Node serves JS actions only,"
            " it is not on PATH for run: steps)"
        ),
    ),
    (("pip", "pip3"), "python3-pip is not installed", "add actions/setup-python"),
    (
        ("python",),
        "python3 exists but there is no `python` alias (no python-is-python3)",
        "add actions/setup-python, or call python3",
    ),
    (("go", "gofmt"), "no Go toolchain", "add actions/setup-go"),
    (("java", "javac", "mvn", "gradle"), "no JDK", "add actions/setup-java"),
    (("dotnet",), "no .NET SDK", "add actions/setup-dotnet"),
    (("cargo", "rustc", "rustup"), "no Rust toolchain", "add dtolnay/rust-toolchain"),
    (
        ("gh",),
        "the GitHub CLI is not installed",
        "install it in a step, or use actions/github-script",
    ),
    (
        ("aws", "az", "gcloud", "kubectl", "helm", "terraform", "ansible"),
        "no cloud CLI is installed",
        "install it in a step",
    ),
]

# Its own entry because the cause is not a missing package: the guest user is
# created with `-G docker` and nothing else, so sudo refuses it. GitHub-hosted
# grants `runner` passwordless sudo, which is why workflows assume it freely.
SUDO_WHY = "the guest `runner` user has no sudo (created with -G docker only)"
SUDO_FIX = (
    "give the image's runner passwordless sudo -- it is already"
    " root-equivalent through the docker group, so this removes no"
    " boundary"
)

# These jobs run a VM of their own, so they need /dev/kvm inside a guest that is
# already a VM. gha-vm ships NESTED_VIRT=0 deliberately, and the failure surfaces
# as a missing-accelerator error that says nothing about nesting.
NESTED_ACTIONS = (
    "reactivecircus/android-emulator-runner",
    "ChristopherHX/android-emulator-runner",
)
NESTED_CMDS = ("kvm-ok", "qemu-system-x86_64", "vagrant")
NESTED_WHY = "needs nested virtualisation; gha-vm sets NESTED_VIRT=0"
NESTED_FIX = (
    "keep this job on GitHub-hosted, or set NESTED_VIRT=1 in"
    " /etc/gha-vm/config.env -- which widens the KVM attack surface the whole"
    " isolation model rests on"
)

# The setup action that supplies each toolchain, so a job that already calls one
# is not reported for the commands that action provides.
SATISFIED_BY = {
    "actions/setup-node": {"node", "npm", "npx", "yarn", "pnpm"},
    "actions/setup-python": {"python", "pip", "pip3"},
    "actions/setup-go": {"go", "gofmt"},
    "actions/setup-java": {"java", "javac", "mvn", "gradle"},
    "actions/setup-dotnet": {"dotnet"},
    "pnpm/action-setup": {"pnpm"},
    "dtolnay/rust-toolchain": {"cargo", "rustc", "rustup"},
    "actions-rust-lang/setup-rust-toolchain": {"cargo", "rustc", "rustup"},
    "hashicorp/setup-terraform": {"terraform"},
    "azure/setup-helm": {"helm"},
    "azure/setup-kubectl": {"kubectl"},
    "aws-actions/configure-aws-credentials": {"aws"},
}

_CMD_RE = {}


def uses_cmd(script, cmd):
    """True when `cmd` appears in command position in a shell script.

    Heuristic by necessity -- resolving this exactly means running the shell.
    It anchors on the separators that can precede a command so `npm` matches in
    `&& npm ci` but not in `--npm-flag` or a path ending in npm.
    """
    pat = _CMD_RE.get(cmd)
    if pat is None:
        pat = re.compile(
            r"(?:^|[\n;|&(]|\$\(|`|\bsudo\s+|\benv\s+|\bxargs\s+|\btime\s+|\bthen\s+|\bdo\s+)"
            r"\s*" + re.escape(cmd) + r"(?=\s|$|;|&|\||\))",
            re.MULTILINE,
        )
        _CMD_RE[cmd] = pat
    return bool(pat.search(script))


def strip_comments(script):
    """Drop whole-line shell comments so a commented-out `npm ci` is not a hit."""
    return "\n".join(
        ln for ln in script.splitlines() if not ln.lstrip().startswith("#")
    )


def job_blockers(job):
    """Every reason this job would fail on the golden image."""
    steps = job.get("steps")
    if not isinstance(steps, list):
        return []

    provided, scripts, actions = set(), [], set()
    for step in steps:
        if not isinstance(step, dict):
            continue
        uses = step.get("uses")
        if isinstance(uses, str):
            name = uses.split("@", 1)[0]
            actions.add(name)
            provided |= SATISFIED_BY.get(name, set())
        run = step.get("run")
        if isinstance(run, str):
            scripts.append(strip_comments(run))

    script = "\n".join(scripts)
    found = []

    # Checked before the container short-circuit: a container cannot conjure
    # /dev/kvm that the guest kernel was never given.
    if actions.intersection(NESTED_ACTIONS) or any(c in script for c in NESTED_CMDS):
        found.append(("nested virt", NESTED_WHY, NESTED_FIX))

    # A container: job runs its steps inside that image, so the host's missing
    # toolchain says nothing about whether they resolve. Docker itself is
    # installed, so everything else about the job works.
    if job.get("container") or not script:
        return found

    if uses_cmd(script, "sudo"):
        found.append(("sudo", SUDO_WHY, SUDO_FIX))
    for cmds, why, fix in MISSING:
        hit = [c for c in cmds if c not in provided and uses_cmd(script, c)]
        if hit:
            found.append(("/".join(hit), why, fix))
    return found


def classify(value, arch):
    """Bucket a runs-on value: movable, already-ours, foreign, or manual.

    `arch` is the fleet's runner architecture. A hosted Linux image for the
    other CPU family is reported manual: rewriting it would hand an arm64 job to
    x64 hardware (or vice versa) and the failure only shows at build time.
    """
    if isinstance(value, str):
        if "${{" in value:
            return "manual", "expression: " + value.strip()
        hosted = hosted_arch(value)
        if hosted == arch:
            return "hosted", value
        if hosted:
            return "manual", f"hosted {hosted} image, fleet is {arch}: {value}"
        if FOREIGN.match(value):
            return "foreign", value
        return "self", value
    if isinstance(value, list):
        labels = [v for v in value if isinstance(v, str)]
        if len(labels) != len(value) or any("${{" in v for v in labels):
            return "manual", "non-scalar list"
        if not labels:
            return "manual", "empty list"
        shown = ", ".join(labels)
        if any(FOREIGN.match(v) for v in labels):
            return "foreign", shown
        arches = [hosted_arch(v) for v in labels]
        other = sorted({a for a in arches if a and a != arch})
        if other:
            return "manual", f"hosted {'/'.join(other)} image, fleet is {arch}: {shown}"
        hosted = [bool(a) for a in arches]
        if all(hosted):
            return "hosted", shown
        if any(hosted):
            # A list is an AND, so this asks for a runner carrying both a hosted
            # image name and something else. Replacing it either drops a label
            # that mattered or keeps one that cannot be satisfied here.
            return "manual", f"mixes hosted and custom labels: {shown}"
        return "self", shown
    if isinstance(value, dict):
        # The `group:`/`labels:` form. Rewriting it means deciding what happens
        # to the group, which is a policy call.
        return "manual", "group/labels mapping"
    return "manual", "unrecognised form"


def render(labels):
    return labels[0] if len(labels) == 1 else "[" + ", ".join(labels) + "]"


def plan_edit(lines, job_map, new_text):
    """Locate this job's runs-on and return (start, end, replacement) or a reason.

    ruamel gives parser-grade line numbers; the replacement is then built by
    hand so the diff touches only the value. Reformatting the file through the
    dumper would reflow quoting and comments across every workflow in the tree.
    """
    try:
        kline, kcol = job_map.lc.key("runs-on")
        vline, _ = job_map.lc.value("runs-on")
    except (KeyError, TypeError, AttributeError):
        return None, "could not locate the runs-on line"

    if vline == kline:
        m = re.match(r"^(\s*runs-on\s*:\s*)(.*?)(\s+#.*)?$", lines[kline])
        if not m:
            return None, "runs-on line did not parse"
        why = unsafe_head(m.group(2).strip())
        if why:
            return None, f"{why}; rewrite it by hand"
        return (kline, kline + 1, m.group(1) + new_text + (m.group(3) or "")), None

    seq = job_map["runs-on"]
    if not isinstance(seq, list) or not len(seq):
        return None, "block value is not a list"
    try:
        item_lines = [seq.lc.item(i)[0] for i in range(len(seq))]
    except (AttributeError, TypeError):
        return None, "could not measure the block list"
    last = max(item_lines)

    # A comment inside the range would be destroyed by collapsing it to one line.
    if any("#" in lines[i] for i in range(kline, last + 1)):
        return None, "comments inside the runs-on block; rewrite it by hand"
    for i in item_lines:
        why = unsafe_head(re.sub(r"^\s*-\s*", "", lines[i]).strip())
        if why:
            return None, f"list item: {why}; rewrite it by hand"
    return (kline, last + 1, " " * kcol + "runs-on: " + new_text), None


def find_repos(root):
    repos, stack = [], [root]
    while stack:
        d = stack.pop()
        try:
            entries = sorted(d.iterdir())
        except (PermissionError, OSError):
            continue
        if (d / ".git").exists():
            repos.append(d)
            continue
        for e in entries:
            if e.is_dir() and not e.is_symlink() and not e.name.startswith("."):
                stack.append(e)
    return sorted(repos)


def is_dirty(repo):
    r = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain"],
        capture_output=True,
        text=True,
        check=False,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or "git status failed")
    return bool(r.stdout.strip())


def main():
    ap = argparse.ArgumentParser(
        description="Audit repos for gha-vm self-hosted runner compatibility.",
        epilog="Without --apply nothing is written. Exit 1 when any job has a "
        "blocker, so this works as a CI check.",
    )
    ap.add_argument("root", nargs="?", default=".", type=Path)
    ap.add_argument(
        "--apply",
        action="store_true",
        help="rewrite movable runs-on values (skips dirty repos)",
    )
    ap.add_argument(
        "--arch",
        choices=ARCHES,
        default="x64",
        help="fleet runner architecture; hosted images for the other family are "
        "reported MANUAL instead of rewritten (default: x64)",
    )
    ap.add_argument(
        "--label",
        help="comma-separated labels to write (default: self-hosted,linux,<arch>)",
    )
    ap.add_argument(
        "--no-blockers",
        action="store_true",
        help="only report runs-on placement, not toolchain gaps",
    )
    ap.add_argument(
        "-q", "--quiet", action="store_true", help="hide jobs that are already correct"
    )
    args = ap.parse_args()

    root = args.root.expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"not a directory: {root}")

    label_text = (
        args.label if args.label is not None else f"self-hosted,linux,{args.arch}"
    )
    labels = [s.strip() for s in label_text.split(",") if s.strip()]
    if not labels:
        sys.exit("--label needs at least one label")
    new_text = render(labels)

    yaml = YAML(typ="rt")
    yaml.preserve_quotes = True

    counts = {
        "repos": 0,
        "files": 0,
        "jobs": 0,
        "hosted": 0,
        "moved": 0,
        "self": 0,
        "manual": 0,
        "foreign": 0,
        "blocked": 0,
        "skipped": 0,
    }

    for repo in find_repos(root):
        wf_dir = repo / ".github" / "workflows"
        files = (
            sorted(p for p in wf_dir.glob("*") if p.suffix in (".yml", ".yaml"))
            if wf_dir.is_dir()
            else []
        )
        if not files:
            continue
        counts["repos"] += 1

        dirty = None
        if args.apply:
            try:
                dirty = is_dirty(repo)
            except RuntimeError as e:
                print(f"\n{repo}\n  SKIP  {e}")
                counts["skipped"] += 1
                continue

        repo_lines = []
        for path in files:
            # Line endings are kept as found: ruamel counts "\n" only, and
            # the file goes back with the same terminator it came with.
            with path.open(encoding="utf-8", newline="") as fh:
                text = fh.read()
            nl = "\r\n" if "\r\n" in text else "\n"
            try:
                doc = yaml.load(text)
            except YAMLError as e:
                repo_lines.append(
                    f"  {path.name}\n    PARSE FAIL  {str(e).splitlines()[0]}"
                )
                counts["skipped"] += 1
                continue
            if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
                continue
            counts["files"] += 1

            lines = text.split(nl)
            edits, out = [], []

            for jid, job in doc["jobs"].items():
                if not isinstance(job, dict):
                    continue
                counts["jobs"] += 1

                if "uses" in job and "runs-on" not in job:
                    if not args.quiet:
                        out.append(
                            f"    {jid:<24} CALLS   reusable workflow; "
                            f"runs-on lives in the callee"
                        )
                    continue
                if "runs-on" not in job:
                    out.append(f"    {jid:<24} MANUAL  no runs-on key")
                    counts["manual"] += 1
                    continue

                kind, shown = classify(job["runs-on"], args.arch)
                counts[kind] += 1

                if kind == "hosted":
                    edit, why = plan_edit(lines, job, new_text)
                    if edit and args.apply and not dirty:
                        edits.append(edit)
                        counts["moved"] += 1
                        out.append(f"    {jid:<24} MOVED   {shown} -> {new_text}")
                    elif edit:
                        out.append(f"    {jid:<24} HOSTED  {shown} -> {new_text}")
                    else:
                        counts["hosted"] -= 1
                        counts["manual"] += 1
                        out.append(f"    {jid:<24} MANUAL  {why}")
                elif kind == "foreign":
                    out.append(
                        f"    {jid:<24} FOREIGN {shown}; this fleet is linux/{args.arch} only"
                    )
                elif kind == "manual":
                    out.append(f"    {jid:<24} MANUAL  {shown}")
                elif not args.quiet:
                    out.append(f"    {jid:<24} SELF    {shown}")

                if not args.no_blockers:
                    blockers = job_blockers(job)
                    if blockers:
                        counts["blocked"] += 1
                    for cmd, why, fix in blockers:
                        out.append(f"      BLOCKER {cmd}: {why}")
                        out.append(f"              {fix}")

            if edits:
                for start, end, repl in sorted(edits, reverse=True):
                    lines[start:end] = [repl]
                with path.open("w", encoding="utf-8", newline="") as fh:
                    fh.write(nl.join(lines))
            if out:
                repo_lines.append(f"  {path.name}\n" + "\n".join(out))

        if repo_lines:
            print(f"\n{repo}")
            if dirty:
                print(
                    "  SKIP WRITES  uncommitted changes; "
                    "commit or stash, then re-run --apply"
                )
                counts["skipped"] += 1
            print("\n".join(repo_lines))

    c = counts
    print(f"\n{c['repos']} repos, {c['files']} workflows, {c['jobs']} jobs")
    print(f"  movable to self-hosted    {c['hosted']}")
    print(
        f"  rewritten                 {c['moved']}"
        + ("" if args.apply else "   (--apply to rewrite)")
    )
    print(f"  already self-hosted       {c['self']}")
    print(f"  need a human              {c['manual']}")
    print(f"  {f'linux/{args.arch} incompatible':<26}{c['foreign']}")
    print(f"  jobs with blockers        {c['blocked']}")
    if c["skipped"]:
        print(f"  skipped                   {c['skipped']}")

    return 1 if c["blocked"] else 0


if __name__ == "__main__":
    sys.exit(main())
