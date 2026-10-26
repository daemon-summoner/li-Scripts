#!/usr/bin/env bash
# tests/cleanup-disk.sh - runs system/cleanup-disk.sh as a normal user in a throwaway Ubuntu container against fake
# models, caches, logs and temp dirs, then checks what it removed and what it kept. Needs Docker and network
# access for apt; everything it deletes is inside the container.
#   tests/cleanup-disk.sh
# --- end usage ---
set -Eeuo pipefail

if [[ ${1:-} != --inside ]]; then
	HERE="$(cd "$(dirname "$0")" && pwd)"
	ROOT="$(dirname "$HERE")"
	command -v docker >/dev/null 2>&1 || {
		echo "FAIL: this test needs docker" >&2
		exit 1
	}
	name="cleanup-disk-test-$$"
	stage=$(mktemp -d)
	trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$stage"' EXIT
	mkdir -p "$stage/system" "$stage/tests"
	cp "$ROOT/system/cleanup-disk.sh" "$stage/system/"
	cp "$HERE/cleanup-disk.sh" "$stage/tests/"
	docker create --name "$name" ubuntu:24.04 bash /src/tests/cleanup-disk.sh --inside >/dev/null
	docker cp "$stage" "$name:/src"
	docker start -a "$name"
	exit
fi

# ---------------------------------------------------------------- inside the container, as root

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq procps faketime >/dev/null
useradd -m -s /bin/bash dev
install -o dev -m 755 /src/system/cleanup-disk.sh /home/dev/cleanup-disk.sh

# Stand-in for the Docker CLI: one running container, "vllm", that mounts the dreamprox model folder and an old
# temp dir. /etc/fake-docker-mode switches it to a daemon that is down or one that hangs.
echo ok >/etc/fake-docker-mode
cat >/usr/local/bin/docker <<'EOF'
#!/bin/sh
mode=$(cat /etc/fake-docker-mode)
if [ "$mode" = down ]; then
	echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
	exit 1
fi
[ "$mode" = hang ] && exec sleep 60
case $1 in
info) exit 0 ;;
ps) echo c0ffee ;;
inspect)
	printf 'M\t/vllm\t/home/dev/.cache/dreamprox/vllm-models\nM\t/vllm\t/tmp/mounted-old\n'
	printf 'R\t/vllm\t["vllm","serve"] null [] ["A=1"]\n'
	;;
system) printf 'Images|0B (0%%)\nBuild Cache|0B\n' ;;
builder | image) echo "Total reclaimed space: 0B" ;;
*)
	echo "fake docker: unexpected arguments: $*" >&2
	exit 1
	;;
esac
EOF
chmod 755 /usr/local/bin/docker

# Everything is created now; the second safe run looks at it from 10 days in the future. "Recent" fixtures get
# a modification time 10 days ahead so they still look fresh then.
su dev -s /bin/bash <<'EOF'
set -e
cd ~
mk() { mkdir -p "$(dirname "$1")"; head -c "$2" /dev/zero >"$1"; }
M=$((1024 * 1024))
mk .lmstudio/models/pub/model-a/a.gguf $((20 * M))
mk .lmstudio/models/pub/model-b/b.gguf $((20 * M))
mk .lmstudio/models/pub/tiny/t.gguf 1000
mkdir -p .omlx/gguf/model-a
ln -s ~/.lmstudio/models/pub/model-a/a.gguf .omlx/gguf/model-a/a.gguf
printf '{\n  "model": {\n    "model_dirs": [\n      "%s/.omlx/models",\n      "%s/.lmstudio/models"\n    ]\n  }\n}\n' \
	"$HOME" "$HOME" >.omlx/settings.json
H=.cache/huggingface/hub
mk $H/models--org--name/blobs/abc $((15 * M))
mkdir -p $H/models--org--name/snapshots/r1 $H/.locks/models--org--name
ln -s ../../blobs/abc $H/models--org--name/snapshots/r1/model.safetensors
mk $H/blobs/d1/shared $((30 * M))
mk .mtplx/models/Big-Model/w.safetensors $((12 * M))
mk .cache/dreamprox/vllm-models/m1/w.bin $((12 * M))
mk .cache/dreamprox/vllm-models/m1-gguf/w.gguf $((12 * M))
mk .cache/someapp/blob $((60 * M))
mk Downloads/thing.deb $((2 * M))
mk .npm/_logs/old.log 100
mk .npm/_logs/new.log 100
touch -d '10 days ago' .npm/_logs/old.log
touch -d '+10 days' .npm/_logs/new.log

mk /tmp/oldtest/f 100
mk /tmp/oldbusy/f 100
mk /tmp/go-build123/f 100
mk /tmp/pytest-of-dev/pytest-1/f 100
mk "/tmp/sp ace/f" 100
mk /tmp/mounted-old/f 100
mk /tmp/newtest/f 100
mk /tmp/pytest-of-dev/pytest-2/f 100
touch -d '+10 days' /tmp/newtest/f /tmp/pytest-of-dev/pytest-2/f
# A freshly unpacked archive: old modification times, but changed just now.
mk /tmp/unpacked/src/main.c 100
touch -d '30 days ago' /tmp/unpacked/src/main.c /tmp/unpacked/src /tmp/unpacked
EOF

# In use: a shell sitting in an old temp dir, and a reader holding a model file open.
su dev -s /bin/bash -c 'cd /tmp/oldbusy && exec sleep 600' &
su dev -s /bin/bash -c 'exec tail -f /home/dev/.lmstudio/models/pub/model-b/b.gguf >/dev/null' &
sleep 1

as_dev() { su dev -s /bin/bash -c "cd ~ && $1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
LOG=/root/out
FAILS=0
check() {
	if "${@:2}"; then
		echo "PASS $1"
	else
		echo "FAIL $1"
		FAILS=$((FAILS + 1))
	fi
}
absent() { [[ ! -e $1 ]]; }
present() { [[ -e $1 ]]; }
said() { grep -Fq -- "$1" "$LOG.$2"; }

echo "===== report"
as_dev './cleanup-disk.sh report --dry-run </dev/null' | tee "$LOG.report"

echo "===== safe --yes, real clock"
as_dev './cleanup-disk.sh safe --yes </dev/null' | tee "$LOG.safe1"
check "unpacked archive with old mtimes kept (fresh ctime)" present /tmp/unpacked/src/main.c
check "old temp dir kept while it was changed today" present /tmp/oldtest
check "log older than 7 days removed" absent /home/dev/.npm/_logs/old.log

echo "===== safe --yes, 10 days later"
as_dev 'faketime -f +10d ./cleanup-disk.sh safe --yes </dev/null' | tee "$LOG.safe2"
check "old temp dir removed" absent /tmp/oldtest
check "temp dir with a space in its name removed" absent "/tmp/sp ace"
check "unpacked archive removed once it really is old" absent /tmp/unpacked
check "recently modified temp dir kept" present /tmp/newtest
check "old temp dir a process sits in kept" present /tmp/oldbusy
check "old temp dir a container mounts kept" present /tmp/mounted-old
check "go-build dir removed" absent /tmp/go-build123
check "finished pytest run removed" absent /tmp/pytest-of-dev/pytest-1
check "recent pytest run kept" present /tmp/pytest-of-dev/pytest-2
check "recent log kept" present /home/dev/.npm/_logs/new.log
check "app cache untouched by the harmless tier" present /home/dev/.cache/someapp/blob

echo "===== models picker: LM Studio group, Hugging Face group, then the mounted dreamprox group"
as_dev 'printf "g1\ny\ng2\ny\ng4\n\n" | script -qec "./cleanup-disk.sh models" /dev/null' | tee "$LOG.models"
check "report flags the model another app links to" said "linked from oMLX GGUF" report
check "report flags models inside a container mount" said "mounted in container vllm" report
check "unlinked-from model in group deleted" absent /home/dev/.lmstudio/models/pub/model-a
check "model held open kept" present /home/dev/.lmstudio/models/pub/model-b/b.gguf
check "picker said why it skipped the open model" said "Skipping pub/model-b: IN USE" models
check "Hugging Face repo deleted" absent /home/dev/.cache/huggingface/hub/models--org--name
check "its lock dir deleted" absent /home/dev/.cache/huggingface/hub/.locks/models--org--name
check "shared Hugging Face blob store kept" present /home/dev/.cache/huggingface/hub/blobs/d1/shared
check "model a container mounts kept" present /home/dev/.cache/dreamprox/vllm-models/m1/w.bin
check "second model a container mounts kept" present /home/dev/.cache/dreamprox/vllm-models/m1-gguf/w.gguf
check "picker said why it skipped the mounted model" said "Skipping m1: mounted in container vllm" models
check "MTPLX untouched" present /home/dev/.mtplx/models/Big-Model/w.safetensors

echo "===== bad selections"
as_dev 'printf "999\nzz\ng9\n\n" | script -qec "./cleanup-disk.sh models" /dev/null' | tee "$LOG.bad"
check "out-of-range number rejected" said "Out of range: 999" bad
check "garbage rejected" said "Not understood: zz" bad
check "missing group rejected" said "No group g9 in the list." bad

echo "===== Docker hangs"
echo hang >/etc/fake-docker-mode
as_dev 'printf "a\n\n" | script -qec "./cleanup-disk.sh models" /dev/null' | tee "$LOG.hang"
as_dev 'faketime -f +10d ./cleanup-disk.sh safe --yes </dev/null' | tee "$LOG.hangsafe"
check "hung Docker is reported" said "Docker did not answer within 15s" hang
check "nothing picked while Docker hangs" said "Skipping Big-Model: Docker not answering" hang
check "MTPLX model kept while Docker hangs" present /home/dev/.mtplx/models/Big-Model/w.safetensors
check "temp step skipped while Docker hangs" said "skipped, there is no telling what is in use" hangsafe
check "mounted temp dir still kept" present /tmp/mounted-old

echo "===== Docker down"
echo down >/etc/fake-docker-mode
as_dev './cleanup-disk.sh report --dry-run </dev/null' | tee "$LOG.down"
check "stopped Docker is reported as not running" said "Docker is not running" down
check "no mount blocks when no container runs" bash -c "! grep -Fq 'mounted in container' $LOG.down"

# shellcheck disable=SC2016  # the glob belongs to the child bash
check "work dirs cleaned up" bash -c '[[ -z $(compgen -G "/tmp/cleanup-disk.*") ]]'

echo "===== $FAILS failure(s)"
((FAILS == 0))
