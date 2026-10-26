#!/usr/bin/env bash
# Frees disk space on macOS and Ubuntu. Harmless cleanups (regenerable caches, idle temp dirs, old logs) run after
# one confirmation; optional extras and downloaded AI models are listed by app so you can pick what to delete.
# Usage: system/cleanup-disk.sh [report|safe|extras|models] [--yes] [--dry-run]   (--help for details)
set -uo pipefail

TEMP_DAYS="${CLEANUP_TEMP_DAYS:-3}"
LOG_DAYS="${CLEANUP_LOG_DAYS:-7}"
JOURNAL_DAYS="${CLEANUP_JOURNAL_DAYS:-14}"
GO_CACHE_HOURS="${CLEANUP_GO_CACHE_HOURS:-24}"
MIN_MB="${CLEANUP_MIN_MB:-50}"
EXTRA_MODEL_DIRS="${CLEANUP_MODEL_DIRS:-}"
MIN_MODEL_KB=10240

COMMAND=menu
DRY_RUN=0
ASSUME_YES=0
FAILURES=0
SUDO_OK=0
DOCKER_OK=0
INUSE_UNKNOWN=0
MOUNTS_UNKNOWN=0
SAFE_RAN=0
CACHE_SIZES_PID=0
TMP_SCAN_PID=0
SAFE_PLANNED=0
EXTRAS_SCANNED=0
MODELS_SCANNED=0
NOW=$(date +%s)
NL_GLOB=$'*\n*'
TAB_GLOB=$'*\t*'
TAB=$'\t'

if [[ -t 1 ]]; then
	BOLD=$'\033[1m'
	DIM=$'\033[2m'
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[0;33m'
	NC=$'\033[0m'
else
	BOLD=""
	DIM=""
	RED=""
	GREEN=""
	YELLOW=""
	NC=""
fi

say() { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
fail() {
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2
	FAILURES=$((FAILURES + 1))
}
die() {
	printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2
	exit 1
}

usage() {
	cat <<EOF
Usage: $0 [command] [--yes] [--dry-run]

Commands (no command opens a menu):
  report   Show disk use, what each tier would clean, and every model. Deletes nothing.
  safe     Run the harmless cleanups after one confirmation (--yes skips it, e.g. for cron).
  extras   Pick optional items to delete: installers, trash, app caches, inference caches,
           developer caches, emulator snapshots, unused Docker images, unneeded packages.
  models   Pick downloaded AI models to delete, grouped by app and folder.

  --yes, -y      Do not ask before the harmless cleanups.
  --dry-run, -n  Show what would be removed or run, and change nothing.

Harmless means it comes back on its own when needed and nothing in use is touched:
  temp dirs where nothing was modified or changed in ${TEMP_DAYS}+ days (go-build, pytest, Chrome clones: 1 day),
  Go build cache entries unused for ${GO_CACHE_HOURS}h+, Gradle build cache entries over a day old,
  brew/npm/pnpm/yarn/bun/pip/uv cache pruning, conda tarballs, Docker build cache over a day old and
  dangling images (then fstrim inside Colima), logs older than ${LOG_DAYS} days, unavailable Xcode
  simulators, and on Ubuntu the apt cache and journal entries older than ${JOURNAL_DAYS} days (sudo).
A step whose tool is busy (an install running, uv holding its cache) is skipped and says so.

Never deleted, in the pickers or anywhere else:
  IN USE                 a running process has a file in it open
  mounted in container X a running Docker container mounts it, or a folder inside or around it
If Docker is installed but does not answer, nothing a container could use is deleted.
Warnings you can still delete past:
  container X     a running Docker container names this model in its command, args or env
  linked from X   another app's folder links to files in here and would break
  dup?            another app has a model with the same name
Select with numbers and ranges (1 4 7-9), g2 for a whole group, or a for everything listed.

Models are found in LM Studio, Hugging Face, oMLX, MTPLX, dreamprox, llama.cpp, Ollama,
PyTorch hub, Whisper and ModelScope folders, plus any you add with CLEANUP_MODEL_DIRS.

Settings (environment variables):
  CLEANUP_TEMP_DAYS=3        Days a temp dir must sit untouched before it is removed
  CLEANUP_LOG_DAYS=7         Age in days of log files to remove
  CLEANUP_JOURNAL_DAYS=14    Ubuntu journal entries older than this are removed
  CLEANUP_GO_CACHE_HOURS=24  Go build cache entries unused this long are removed
  CLEANUP_MIN_MB=50          Smallest app cache listed in extras
  CLEANUP_MODEL_DIRS=a:b     More model folders to list, colon-separated
EOF
}

check_number() {
	if [[ ! $2 =~ ^[0-9]+$ ]] || (($2 == 0)); then
		die "$1 must be a positive whole number (got '$2')"
	fi
}

human() {
	awk -v k="$1" 'BEGIN {
		if (k < 0) { print "?"; exit }
		split("K M G T", u, " "); i = 1
		while (k >= 1024 && i < 4) { k /= 1024; i++ }
		fmt = (i == 1) ? "%d%s\n" : "%.1f%s\n"
		printf fmt, k, u[i] }'
}

# Docker and Ollama print decimal units ("12.22GB", "4.7 GB").
human_to_kb() {
	awk -v s="$1" 'BEGIN {
		gsub(/ /, "", s)
		if (!match(s, /^[0-9.]+/)) { print -1; exit }
		n = substr(s, 1, RLENGTH); u = toupper(substr(s, RLENGTH + 1))
		if (u == "B") m = 1; else if (u == "KB") m = 1e3; else if (u == "MB") m = 1e6
		else if (u == "GB") m = 1e9; else if (u == "TB") m = 1e12; else { print -1; exit }
		printf "%d\n", n * m / 1024 }'
}

# Listing and sizing skip entries this user cannot read, so sizes are floors. Deletions report every failure.
dir_kb() {
	local kb
	kb=$(du -sk -- "$1" 2>/dev/null | awk 'END { print $1 }')
	printf '%s\n' "${kb:-0}"
}

# "KB<TAB>path" for each NUL-separated path on stdin, measured in parallel.
du_many() {
	xargs -0 -r -P "$JOBS" -n 1 du -sk 2>/dev/null
}

# Total KB of the paths in one column of a TSV file.
list_kb() {
	cut -f"$1" "$2" | tr '\n' '\0' | du_many | awk '{ s += $1 } END { print s + 0 }'
}

age_days() {
	local m
	if [[ $OS == mac ]]; then m=$(stat -f %m -- "$1" 2>/dev/null); else m=$(stat -c %Y -- "$1" 2>/dev/null); fi
	if [[ -z $m ]]; then echo -1; else echo $(((NOW - m) / 86400)); fi
}

# Physical path, so it matches what lsof and /proc report (/tmp is /private/tmp on macOS).
phys() {
	if [[ -d $1 ]]; then
		(cd -P -- "$1" 2>/dev/null && pwd -P)
	else
		local d
		d=$(cd -P -- "${1%/*}" 2>/dev/null && pwd -P) || return 1
		printf '%s/%s\n' "${d%/}" "${1##*/}"
	fi
}

tilde() {
	local t='~'
	printf '%s\n' "${1/#"$HOME"/$t}"
}

run_timeout() {
	local secs=$1
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	else
		perl -e 'alarm shift @ARGV; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$secs" "$@"
	fi
}

# Runs a cleanup command quietly, printing its last line on success and its tail on failure.
run_tool() {
	local label=$1 secs=$2 rc last
	shift 2
	if ((DRY_RUN)); then
		say "    would run: $*"
		return 0
	fi
	run_timeout "$secs" "$@" >"$WORK/tool.out" 2>&1
	rc=$?
	if ((rc == 0)); then
		last=$(grep -v '^[[:space:]]*$' "$WORK/tool.out" | tail -n 1)
		[[ -n $last ]] && say "    ${DIM}${last}${NC}"
		return 0
	fi
	if ((rc == 124 || rc == 142)); then
		fail "$label did not finish within ${secs}s and was stopped"
	else
		fail "$label failed (exit $rc):"
		tail -n 8 "$WORK/tool.out" | sed 's/^/    /' >&2
	fi
	return 1
}

confirm() {
	local ans
	read -r -p "$1 [y/N] " ans || return 1
	[[ $ans == [yY] || $ans == [yY][eE][sS] ]]
}

ensure_sudo() {
	((SUDO_OK)) && return 0
	if sudo -n true 2>/dev/null; then
		SUDO_OK=1
		return 0
	fi
	if ((ASSUME_YES)) || [[ ! -t 0 ]]; then
		warn "Skipping $1: it needs sudo and no sudo credentials are cached."
		return 1
	fi
	if confirm "$1 needs sudo. Enter your password now?" && sudo -v; then
		SUDO_OK=1
		return 0
	fi
	warn "Skipping $1."
	return 1
}

# Is someone running an install with this tool right now? Long-running servers (npx, uv run) do not count.
installing() {
	pgrep -u "$USER_NAME" -f "(^|/)$1(-cli\\.js)? ($2)( |\$)" >/dev/null 2>&1
}

# ---------------------------------------------------------------- free space

TRACK_PATHS=()

track() {
	[[ -e $1 ]] && TRACK_PATHS+=("$1")
}

df_avail() {
	df -Pk "${TRACK_PATHS[@]}" 2>/dev/null | awk 'NR > 1 && !seen[$6]++ { s += $4 } END { print s + 0 }'
}

freed_since() {
	local d=$(($(df_avail) - $1))
	((d < 0)) && d=0
	human "$d"
}

# ---------------------------------------------------------------- in-use detection

# Every path some process has open (files, mmapped models, working dirs) plus all of its parent dirs, so one
# exact-match lookup answers "does anything under this path have a user?". Processes of other users, such as
# root-run containers, are only visible when the OS lets this user see them.
build_inuse_index() {
	local raw="$WORK/open.raw"
	if [[ $OS == mac ]]; then
		lsof -nP -w -Fn 2>/dev/null | sed -n 's/^n\(\/.*\)/\1/p' >"$raw"
	else
		{
			find /proc/[0-9]*/cwd -maxdepth 0 -printf '%l\n'
			find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 -type l -printf '%l\n'
			cat /proc/[0-9]*/maps | awk '{ i = index($0, " /"); if (i) print substr($0, i + 1) }'
		} 2>/dev/null >"$raw"
	fi
	if [[ ! -s $raw ]]; then
		INUSE_UNKNOWN=1
		warn "Could not list open files, so everything that could be in use is treated as in use."
	fi
	awk '/^\// { p = $0; sub(/ \(deleted\)$/, "", p)
		while (length(p) > 1 && !(p in seen)) { seen[p] = 1; print p; sub(/\/[^\/]*$/, "", p) } }' "$raw" >"$WORK/inuse"
}

# awk helper: mounted(p) is the name of a running container whose bind mount is p, is inside p, or holds p,
# given the mounts loaded as nm, mn[] (names) and ms[] (host paths).
MOUNT_AWK='function mounted(p, i) {
	for (i = 1; i <= nm; i++)
		if (ms[i] == "/" || p == ms[i] || index(ms[i] "/", p "/") == 1 || index(p "/", ms[i] "/") == 1) return mn[i]
	return "" }'

# Name of a running container that mounts the path, a folder inside it or one around it; empty when none does.
mounted_by() {
	[[ -s $WORK/mounts ]] || return 0
	awk -F'\t' -v p="$1" "$MOUNT_AWK"' { nm++; mn[nm] = $1; ms[nm] = $2 } END { printf "%s", mounted(p) }' "$WORK/mounts"
}

# Keeps lines of a TSV whose given column is a path nothing has open and no running container mounts.
filter_not_in_use() {
	if ((INUSE_UNKNOWN || MOUNTS_UNKNOWN)); then
		: >"$3"
		return 0
	fi
	awk -F'\t' -v c="$1" "$MOUNT_AWK"'
		FILENAME == ARGV[1] { u[$0] = 1; next }
		FILENAME == ARGV[2] { nm++; mn[nm] = $1; ms[nm] = $2; next }
		!($c in u) && mounted($c) == ""' "$WORK/inuse" "$WORK/mounts" "$2" >"$3"
}

docker_unknown() {
	MOUNTS_UNKNOWN=1
	warn "$1, so there is no telling which files containers use. Models, caches and temp dirs are left alone."
}

# Containers run as root (Linux) or inside a VM (Colima), where lsof and /proc cannot see their open files, so
# Docker itself has to say what they mount. A daemon that is down runs no containers; one that hangs or refuses
# this user might.
check_docker() {
	local out rc
	command -v docker >/dev/null 2>&1 || return 0
	out=$(run_timeout 15 docker info 2>&1 >/dev/null)
	rc=$?
	if ((rc == 0)); then
		DOCKER_OK=1
	elif ((rc == 124 || rc == 142)); then
		docker_unknown "Docker did not answer within 15s"
	elif [[ $out == *"Cannot connect to the Docker daemon"* ]]; then
		info "Docker is not running; Docker steps are skipped."
	else
		docker_unknown "Docker refused to answer (${out##*$'\n'})"
	fi
}

# Per running container: bind-mount sources go to $WORK/mounts ("name<TAB>host path") and block deleting anything
# in or around them; command, entrypoint, args and env go to $WORK/docker_refs for matching model names.
build_docker_refs() {
	local ids tag name src
	: >"$WORK/docker_refs"
	: >"$WORK/mounts"
	((DOCKER_OK)) || return 0
	MOUNTS_UNKNOWN=0
	if ! ids=$(run_timeout 15 docker ps -q 2>/dev/null); then
		docker_unknown "docker ps failed"
		return 0
	fi
	[[ -n $ids ]] || return 0
	# shellcheck disable=SC2086  # container IDs are hex words
	if ! run_timeout 30 docker inspect --format \
		'{{range .Mounts}}M{{"\t"}}{{$.Name}}{{"\t"}}{{.Source}}{{"\n"}}{{end}}R{{"\t"}}{{.Name}}{{"\t"}}{{json .Config.Cmd}} {{json .Config.Entrypoint}} {{json .Args}} {{json .Config.Env}}' \
		$ids >"$WORK/docker.raw" 2>/dev/null; then
		docker_unknown "docker inspect failed (a container may have just stopped; run again)"
		return 0
	fi
	awk -F'\t' -v OFS='\t' '$1 == "R" { sub(/^\//, "", $2); print $2, $3 }' "$WORK/docker.raw" >"$WORK/docker_refs"
	while IFS="$TAB" read -r tag name src; do
		[[ $tag == M && $src == /* ]] || continue
		if [[ -e $src ]]; then src=$(phys "$src") || continue; fi
		[[ $src == / ]] || src=${src%/}
		printf '%s\t%s\n' "${name#/}" "$src" >>"$WORK/mounts"
	done <"$WORK/docker.raw"
}

colima_trim() {
	command -v colima >/dev/null 2>&1 || return 0
	colima status >/dev/null 2>&1 || return 0
	say "    Returning freed blocks from the Colima VM disk to macOS"
	run_tool "fstrim in the Colima VM" 600 colima ssh -- sudo fstrim -a
}

# ---------------------------------------------------------------- deletion

safe_rm() {
	local path=$1 root=${2%/}
	if [[ $path != /* || -z $root || $root == / || $path != "$root"/* ]]; then
		fail "Refusing to remove $path: it is not inside $root"
		return 1
	fi
	if [[ $path/ == */../* || $path/ == */./* ]]; then
		fail "Refusing to remove $path: the path has . or .. parts"
		return 1
	fi
	[[ -e $path || -L $path ]] || return 0
	if ((DRY_RUN)); then
		say "    would remove $(tilde "$path")"
		return 0
	fi
	if ! rm -rf -- "$path" 2>"$WORK/rm.err"; then
		# Go's module cache and some test fixtures leave read-only dirs that rm cannot empty. A chmod that
		# fails here shows up as the second rm's error.
		chmod -R u+w -- "$path" 2>/dev/null
		if ! rm -rf -- "$path" 2>"$WORK/rm.err"; then
			fail "Could not remove $(tilde "$path"): $(head -n 2 "$WORK/rm.err" | tr '\n' ' ')"
			return 1
		fi
	fi
}

empty_dir() {
	local dir=$1 root=$2 c rc=0
	if [[ $dir != "${root%/}"/* ]]; then
		fail "Refusing to empty $dir: it is not inside $root"
		return 1
	fi
	for c in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
		[[ -e $c || -L $c ]] || continue
		safe_rm "$c" "$dir" || rc=1
	done
	return $rc
}

# ---------------------------------------------------------------- item lists (TSV)

# Columns: group, group label, KB, age in days, name, path, action, root, flags, blocked.
# KB is -1 when unknown, or "@<min KB>" until measure_items sizes it and drops it if it is smaller than that.
add_item() {
	local f
	for f in "$@"; do
		case $f in *"$TAB"* | *$'\n'*) return 0 ;; esac
	done
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10:--}" "${11:-0}" >>"$1"
}

measure_items() {
	local f=$1
	awk -F'\t' '$3 ~ /^@/ { print $6 }' "$f" | tr '\n' '\0' | du_many >"$f.du"
	awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { i = index($0, "\t"); kb[substr($0, i + 1)] = substr($0, 1, i - 1); next }
		$3 ~ /^@/ { min = substr($3, 2) + 0; if (!($6 in kb) || kb[$6] + 0 < min) next; $3 = kb[$6] }
		{ print }' "$f.du" "$f" >"$f.new" && mv "$f.new" "$f"
}

annotate_in_use() {
	local f=$1
	awk -F'\t' -v OFS='\t' -v ukn="$INUSE_UNKNOWN" -v dkn="$MOUNTS_UNKNOWN" "$MOUNT_AWK"'
		function block(t) { $9 = ($9 == "-") ? t : $9 ", " t; $10 = 1 }
		FILENAME == ARGV[1] { u[$0] = 1; next }
		FILENAME == ARGV[2] { nm++; mn[nm] = $1; ms[nm] = $2; next }
		$7 ~ /^(rm|rm-hf|empty-dir)$/ {
			if (ukn) block("IN USE?"); else if ($6 in u) block("IN USE")
			if (dkn) block("Docker not answering"); else if ((c = mounted($6)) != "") block("mounted in container " c)
		}
		{ print }' "$WORK/inuse" "$WORK/mounts" "$f" >"$f.new" && mv "$f.new" "$f"
}

# A model counts as referenced when its folder name appears in a running container's command, args or env.
annotate_containers() {
	local f=$1
	[[ -s $WORK/docker_refs ]] || return 0
	awk -F'\t' -v OFS='\t' 'FILENAME == ARGV[1] { n++; c[n] = $1; sub(/^\//, "", c[n]); t[n] = tolower($0); next }
		{ k = tolower($5); sub(/^(dataset|space): /, "", k); sub(/^.*\//, "", k)
		  if (length(k) >= 6) for (i = 1; i <= n; i++) if (index(t[i], k)) {
			  $9 = ($9 == "-") ? "container " c[i] : $9 ", container " c[i]; break }
		  print }' "$WORK/docker_refs" "$f" >"$f.new" && mv "$f.new" "$f"
}

# Flags models that a symlink elsewhere in the model folders points into, such as oMLX's GGUF entries that
# link to LM Studio's files. Links inside the model itself (Hugging Face snapshots) do not count.
annotate_links() {
	local f=$1
	[[ -s $WORK/links ]] || return 0
	awk -F'\t' -v OFS='\t' '
		function norm(p, a, out, n, i, k) {
			n = split(p, a, "/"); k = 0
			for (i = 1; i <= n; i++) {
				if (a[i] == "" || a[i] == ".") continue
				if (a[i] == "..") { if (k > 0) k--; continue }
				out[++k] = a[i]
			}
			p = ""
			for (i = 1; i <= k; i++) p = p "/" out[i]
			return p
		}
		FILENAME == ARGV[1] {
			t = $2
			if (substr(t, 1, 1) != "/") { s = $1; sub(/\/[^\/]*$/, "", s); t = s "/" t }
			t = norm(t)
			while (length(t) > 1) {
				if (index($1 "/", t "/") != 1 && !(t in from)) from[t] = $3
				sub(/\/[^\/]*$/, "", t)
			}
			next
		}
		$7 ~ /^(rm|rm-hf)$/ && ($6 in from) { $9 = ($9 == "-") ? "linked from " from[$6] : $9 ", linked from " from[$6] }
		{ print }' "$WORK/links" "$f" >"$f.new" && mv "$f.new" "$f"
}

annotate_dups() {
	local f=$1
	awk -F'\t' -v OFS='\t' '
		function key(n) { n = tolower(n); sub(/^(dataset|space): /, "", n); sub(/^.*\//, "", n); sub(/[-_](gguf|mlx)$/, "", n); return n }
		NR == FNR { k = key($5); if (!((k, $1) in seen)) { seen[k, $1] = 1; groups[k]++ } next }
		{ if (groups[key($5)] > 1) $9 = ($9 == "-") ? "dup?" : $9 ", dup?"; print }' "$f" "$f" >"$f.new" && mv "$f.new" "$f"
}

I_G=()
I_GL=()
I_KB=()
I_AGE=()
I_NAME=()
I_PATH=()
I_ACT=()
I_ROOT=()
I_FLAG=()
I_BLOCK=()
I_DONE=()

load_items() {
	local g gl kb age name path action root flag block prev="" n=0
	I_G=()
	I_GL=()
	I_KB=()
	I_AGE=()
	I_NAME=()
	I_PATH=()
	I_ACT=()
	I_ROOT=()
	I_FLAG=()
	I_BLOCK=()
	I_DONE=()
	while IFS="$TAB" read -r g gl kb age name path action root flag block; do
		if [[ $g != "$prev" ]]; then
			n=$((n + 1))
			prev=$g
		fi
		I_G+=("$n")
		I_GL+=("$gl")
		I_KB+=("$kb")
		I_AGE+=("$age")
		I_NAME+=("$name")
		I_PATH+=("$path")
		I_ACT+=("$action")
		I_ROOT+=("$root")
		I_FLAG+=("$flag")
		I_BLOCK+=("$block")
		I_DONE+=(0)
	done < <(sort -t "$TAB" -k1,1n -k3,3nr "$1")
}

save_items() {
	local i
	: >"$1"
	for ((i = 0; i < ${#I_G[@]}; i++)); do
		((I_DONE[i])) && continue
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${I_G[i]}" "${I_GL[i]}" "${I_KB[i]}" "${I_AGE[i]}" \
			"${I_NAME[i]}" "${I_PATH[i]}" "${I_ACT[i]}" "${I_ROOT[i]}" "${I_FLAG[i]}" "${I_BLOCK[i]}" >>"$1"
	done
}

# Prints "<count> <KB>" for a list.
tsv_summary() {
	awk -F'\t' '{ n++; if ($3 > 0) s += $3 } END { print n + 0, s + 0 }' "$1"
}

render_items() {
	local i j gkb gn prev="" flag age color
	for ((i = 0; i < ${#I_G[@]}; i++)); do
		((I_DONE[i])) && continue
		if [[ ${I_G[i]} != "$prev" ]]; then
			prev=${I_G[i]}
			gkb=0
			gn=0
			for ((j = i; j < ${#I_G[@]} && I_G[j] == I_G[i]; j++)); do
				((I_DONE[j])) && continue
				gn=$((gn + 1))
				((I_KB[j] > 0)) && gkb=$((gkb + I_KB[j]))
			done
			printf '\n%s[g%s] %s%s  %s%s, %d item(s)%s\n' "$BOLD" "${I_G[i]}" "${I_GL[i]}" "$NC" "$DIM" "$(human "$gkb")" "$gn" "$NC"
		fi
		age="-"
		((I_AGE[i] >= 0)) && age="${I_AGE[i]}d"
		flag=""
		if [[ ${I_FLAG[i]} != "-" ]]; then
			color=$YELLOW
			((I_BLOCK[i])) && color=$RED
			flag="  ${color}[${I_FLAG[i]}]${NC}"
		fi
		printf '  %4d  %7s  %5s  %s%s\n' $((i + 1)) "$(human "${I_KB[i]}")" "$age" "${I_NAME[i]}" "$flag"
	done
	say ""
}

SEL=()

parse_selection() {
	local input=${1//,/ } tok a b i n=${#I_G[@]} found
	local -a toks marks
	SEL=()
	set -f
	# shellcheck disable=SC2206  # word splitting on purpose; globbing is off
	toks=($input)
	set +f
	for ((i = 0; i < n; i++)); do marks[i]=0; done
	for tok in "${toks[@]}"; do
		case $tok in
		a | all)
			for ((i = 0; i < n; i++)); do ((I_DONE[i])) || marks[i]=1; done
			;;
		g[0-9]*)
			a=${tok#g}
			if [[ ! $a =~ ^[0-9]+$ ]]; then
				warn "Not a group: $tok"
				return 1
			fi
			found=0
			for ((i = 0; i < n; i++)); do
				if ((I_G[i] == a && !I_DONE[i])); then
					marks[i]=1
					found=1
				fi
			done
			if ((!found)); then
				warn "No group $tok in the list."
				return 1
			fi
			;;
		*)
			if [[ $tok =~ ^[0-9]+-[0-9]+$ ]]; then
				a=${tok%-*}
				b=${tok#*-}
			elif [[ $tok =~ ^[0-9]+$ ]]; then
				a=$tok
				b=$tok
			else
				warn "Not understood: $tok"
				return 1
			fi
			if ((a < 1 || b > n || a > b)); then
				warn "Out of range: $tok (items are 1-$n)"
				return 1
			fi
			for ((i = a - 1; i < b; i++)); do
				((I_DONE[i])) || marks[i]=1
			done
			;;
		esac
	done
	for ((i = 0; i < n; i++)); do
		((marks[i])) && SEL+=("$i")
	done
	return 0
}

delete_item() {
	local i=$1 path=${I_PATH[$1]} root=${I_ROOT[$1]} b
	case ${I_ACT[i]} in
	rm) safe_rm "$path" "$root" ;;
	rm-hf)
		safe_rm "$path" "$root" || return 1
		if [[ -e $root/.locks/${path##*/} ]]; then safe_rm "$root/.locks/${path##*/}" "$root"; fi
		;;
	empty-dir) empty_dir "$path" "$root" ;;
	ollama) run_tool "ollama rm $path" 120 ollama rm "$path" ;;
	docker-images) run_tool "docker image prune" 1800 docker image prune -af && colima_trim ;;
	docker-builder) run_tool "docker builder prune" 1800 docker builder prune -af && colima_trim ;;
	go-modcache) run_tool "go clean -modcache" 1800 go clean -modcache ;;
	uv-clean) run_tool "uv cache clean" 1800 uv cache clean ;;
	brew-autoremove) run_tool "brew autoremove" 1800 brew autoremove ;;
	apt-autoremove) ensure_sudo "apt autoremove" && run_tool "apt autoremove" 3600 sudo -n apt-get autoremove -y ;;
	snap-rev)
		b=${path##*/}
		b=${b%.snap}
		ensure_sudo "snap remove" && run_tool "snap remove ${b%_*}" 900 sudo -n snap remove "${b%_*}" --revision="${b##*_}"
		;;
	*)
		fail "Unknown action ${I_ACT[i]} for ${I_NAME[i]}"
		return 1
		;;
	esac
}

is_path_action() {
	[[ $1 == rm || $1 == rm-hf || $1 == empty-dir ]]
}

# Interactive picker over a TSV list; deleted items are dropped from the list file.
pick() {
	local file=$1 title=$2 input i kb count before refresh flag c
	[[ -t 0 ]] || die "Picking $title needs a terminal."
	load_items "$file"
	while true; do
		count=0
		for ((i = 0; i < ${#I_G[@]}; i++)); do ((I_DONE[i])) || count=$((count + 1)); done
		if ((count == 0)); then
			info "No $title left to pick from."
			break
		fi
		say ""
		say "${BOLD}${title}${NC}  ${DIM}size, last modified, name${NC}"
		render_items
		read -r -p "Select (e.g. 1 4 7-9, g2, a), Enter to go back: " input || break
		[[ -z ${input// /} || $input == q ]] && break
		parse_selection "$input" || continue
		((${#SEL[@]})) || continue

		refresh=0
		for i in "${SEL[@]}"; do
			is_path_action "${I_ACT[i]}" && refresh=1
		done
		if ((refresh)); then
			build_inuse_index
			build_docker_refs
			for i in "${SEL[@]}"; do
				if ! is_path_action "${I_ACT[i]}" || ((I_BLOCK[i])); then continue; fi
				if ((INUSE_UNKNOWN)) || grep -Fxq -- "${I_PATH[i]}" "$WORK/inuse"; then
					I_BLOCK[i]=1
					I_FLAG[i]="IN USE"
				elif ((MOUNTS_UNKNOWN)); then
					I_BLOCK[i]=1
					I_FLAG[i]="Docker not answering"
				else
					c=$(mounted_by "${I_PATH[i]}")
					if [[ -n $c ]]; then
						I_BLOCK[i]=1
						I_FLAG[i]="mounted in container $c"
					fi
				fi
			done
		fi

		kb=0
		count=0
		say ""
		for i in "${SEL[@]}"; do
			if ((I_BLOCK[i])); then
				warn "Skipping ${I_NAME[i]}: ${I_FLAG[i]}"
				continue
			fi
			count=$((count + 1))
			((I_KB[i] > 0)) && kb=$((kb + I_KB[i]))
			flag=""
			[[ ${I_FLAG[i]} != "-" ]] && flag="  ${YELLOW}[${I_FLAG[i]}]${NC}"
			printf '  %7s  %s%s\n' "$(human "${I_KB[i]}")" "${I_NAME[i]}" "$flag"
		done
		((count)) || continue
		if ((!DRY_RUN)); then
			confirm "Delete these $count item(s), about $(human "$kb")? This cannot be undone." || continue
		fi
		before=$(df_avail)
		for i in "${SEL[@]}"; do
			((I_BLOCK[i])) && continue
			if delete_item "$i" && ((!DRY_RUN)); then
				I_DONE[i]=1
				say "  ${GREEN}removed${NC} ${I_NAME[i]}"
			fi
		done
		((DRY_RUN)) || info "Freed $(freed_since "$before") (measured with df)."
	done
	save_items "$file"
}

# ---------------------------------------------------------------- locations

json_string() {
	[[ -f $2 ]] || return 0
	sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$2" | head -n 1
}

lmstudio_home() {
	local home="$HOME/.lmstudio"
	if [[ -f $HOME/.lmstudio-home-pointer ]]; then
		home=$(head -n 1 "$HOME/.lmstudio-home-pointer")
	fi
	printf '%s\n' "$home"
}

lmstudio_models_dir() {
	local home dl
	home=$(lmstudio_home)
	dl=$(json_string downloadsFolder "$home/settings.json")
	printf '%s\n' "${dl:-$home/models}"
}

omlx_model_dirs() {
	local s="$HOME/.omlx/settings.json"
	printf '%s\n' "$HOME/.omlx/models"
	[[ -f $s ]] || return 0
	json_string model_dir "$s"
	awk '/"model_dirs"[[:space:]]*:/ { f = 1 }
		f { while (match($0, /"\/[^"]*"/)) { print substr($0, RSTART + 1, RLENGTH - 2); $0 = substr($0, RSTART + RLENGTH) } }
		f && /\]/ { exit }' "$s"
}

hf_home() { printf '%s\n' "${HF_HOME:-$XDG_CACHE/huggingface}"; }
hf_hub_dir() { printf '%s\n' "${HF_HUB_CACHE:-${HUGGINGFACE_HUB_CACHE:-$(hf_home)/hub}}"; }

llama_cache_dir() {
	if [[ -n ${LLAMA_CACHE:-} ]]; then
		printf '%s\n' "$LLAMA_CACHE"
	elif [[ $OS == mac ]]; then
		printf '%s\n' "$HOME/Library/Caches/llama.cpp"
	else
		printf '%s\n' "$XDG_CACHE/llama.cpp"
	fi
}

go_cache_dir() {
	local c
	command -v go >/dev/null 2>&1 || return 0
	c=$(go env GOCACHE 2>/dev/null) || return 0
	# Only a directory that looks like Go's cache gets age-trimmed.
	[[ -d $c && (-f $c/README || -f $c/trim.txt) ]] && printf '%s\n' "$c"
}

pip_cmd() {
	if command -v pip3 >/dev/null 2>&1; then
		PIP=(pip3)
	elif command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
		PIP=(python3 -m pip)
	else
		return 1
	fi
}

# ---------------------------------------------------------------- models

MR_LABEL=()
MR_PATH=()
MR_KIND=()

register_model_root() {
	local p i
	[[ -n $2 && -d $2 ]] || return 0
	p=$(phys "$2") || return 0
	for ((i = 0; i < ${#MR_PATH[@]}; i++)); do
		if [[ ${MR_PATH[i]} == "$p" ]]; then
			[[ " ${MR_LABEL[i]} " == *" $1 "* ]] || MR_LABEL[i]="${MR_LABEL[i]} + $1"
			return 0
		fi
	done
	MR_LABEL+=("$1")
	MR_PATH+=("$p")
	MR_KIND+=("${3:-generic}")
	track "$p"
}

hf_display() {
	local n=$1 kind="" sep=/
	case $n in
	models--*) n=${n#models--} ;;
	datasets--*)
		n=${n#datasets--}
		kind="dataset: "
		;;
	spaces--*)
		n=${n#spaces--}
		kind="space: "
		;;
	*)
		printf '%s\n' "$n"
		return
		;;
	esac
	printf '%s%s\n' "$kind" "${n//--/$sep}"
}

# A folder is one model when it holds files itself or is a Hugging Face cache entry; otherwise it is an
# org folder (LM Studio's publisher/model layout) whose children are the models.
is_model_dir() {
	case ${1##*/} in models--* | datasets--* | spaces--*) return 0 ;; esac
	[[ -d $1/snapshots || -d $1/blobs ]] && return 0
	[[ -n $(find "$1" -mindepth 1 -maxdepth 1 -type f ! -name '.*' -print -quit 2>/dev/null) ]]
}

add_model() {
	local gidx=$1 glabel=$2 path=$3 name=$4 root=$5 action=rm
	case ${path##*/} in models--* | datasets--* | spaces--*) action=rm-hf ;; esac
	add_item "$MODELS_TSV" "$gidx" "$glabel" "@$MIN_MODEL_KB" "$(age_days "$path")" "$name" "$path" "$action" "$root"
}

scan_model_root() {
	local gidx=$1 label=$2 root=$3 kind=$4 glabel child name g
	glabel="$label · $(tilde "$root")"
	for child in "$root"/*; do
		[[ -e $child && ! -L $child ]] || continue
		name=${child##*/}
		# A Hugging Face hub folder can also hold shared blob stores that other repos link into; only whole
		# repos are safe to delete there.
		if [[ $kind == hf ]]; then
			case $name in models--* | datasets--* | spaces--*) ;; *) continue ;; esac
		fi
		# llama.cpp keeps saved prompt slots next to its models; they are listed under inference caches.
		[[ $name == slots && $label == llama.cpp* ]] && continue
		if [[ -f $child ]]; then
			add_model "$gidx" "$glabel" "$child" "$name" "$root"
		elif [[ -d $child ]]; then
			if is_model_dir "$child"; then
				add_model "$gidx" "$glabel" "$child" "$(hf_display "$name")" "$root"
			else
				for g in "$child"/*; do
					[[ -e $g && ! -L $g ]] || continue
					add_model "$gidx" "$glabel" "$g" "$name/${g##*/}" "$root"
				done
			fi
		fi
	done
}

collect_model_links() {
	local i
	: >"$WORK/links"
	for ((i = 0; i < ${#MR_PATH[@]}; i++)); do
		if [[ $OS == mac ]]; then
			find "${MR_PATH[i]}" -type l ! -name "$NL_GLOB" -print0 2>/dev/null | xargs -0 -r stat -f "%N${TAB}%Y" 2>/dev/null
		else
			find "${MR_PATH[i]}" -type l ! -name "$NL_GLOB" -printf '%p\t%l\n' 2>/dev/null
		fi | awk -v l="${MR_LABEL[i]}" '{ print $0 "\t" l }' >>"$WORK/links"
	done
}

scan_ollama() {
	local gidx=$1 out running name size flag block
	command -v ollama >/dev/null 2>&1 || return 0
	if ! out=$(run_timeout 20 ollama list 2>&1); then
		warn "Ollama is installed but 'ollama list' failed, so its models are not listed: ${out##*$'\n'}"
		return 0
	fi
	running=$(run_timeout 20 ollama ps 2>/dev/null | awk 'NR > 1 { print $1 }')
	while IFS="$TAB" read -r name size; do
		flag=-
		block=0
		if grep -Fxq -- "$name" <<<"$running"; then
			flag="IN USE"
			block=1
		fi
		add_item "$MODELS_TSV" "$gidx" "Ollama · ollama list" "$(human_to_kb "$size")" -1 "$name" "$name" ollama ollama "$flag" "$block"
	done < <(awk 'NR > 1 && NF >= 4 { print $1 "\t" $3 $4 }' <<<"$out")
}

scan_models() {
	local d i
	local -a extra
	info "Scanning AI model folders"
	: >"$MODELS_TSV"
	MR_LABEL=()
	MR_PATH=()
	MR_KIND=()
	register_model_root "LM Studio" "$(lmstudio_models_dir)"
	register_model_root "LM Studio (old location)" "$XDG_CACHE/lm-studio/models"
	register_model_root "Hugging Face" "$(hf_hub_dir)" hf
	while IFS= read -r d; do
		register_model_root "oMLX" "$d"
	done < <(omlx_model_dirs)
	register_model_root "oMLX GGUF" "$HOME/.omlx/gguf"
	register_model_root "MTPLX" "$HOME/.mtplx/models"
	for d in "$XDG_CACHE"/dreamprox/*/; do
		d=${d%/}
		[[ -d $d ]] && register_model_root "dreamprox ${d##*/}" "$d"
	done
	register_model_root "dreamprox voices" "$XDG_CACHE/dreamprox-voices"
	register_model_root "llama.cpp" "$(llama_cache_dir)"
	register_model_root "PyTorch hub" "${TORCH_HOME:-$XDG_CACHE/torch}/hub"
	register_model_root "Whisper" "$XDG_CACHE/whisper"
	register_model_root "ModelScope" "${MODELSCOPE_CACHE:-$XDG_CACHE/modelscope}/hub" hf
	IFS=: read -r -a extra <<<"$EXTRA_MODEL_DIRS"
	for ((i = 0; i < ${#extra[@]}; i++)); do
		if [[ ! -d ${extra[i]} ]]; then
			warn "CLEANUP_MODEL_DIRS entry is not a folder: ${extra[i]}"
			continue
		fi
		register_model_root "Custom" "${extra[i]}"
	done
	for ((i = 0; i < ${#MR_PATH[@]}; i++)); do
		scan_model_root $((i + 1)) "${MR_LABEL[i]}" "${MR_PATH[i]}" "${MR_KIND[i]}"
	done
	scan_ollama $((${#MR_PATH[@]} + 1))
	measure_items "$MODELS_TSV"
	collect_model_links
	annotate_in_use "$MODELS_TSV"
	annotate_containers "$MODELS_TSV"
	annotate_links "$MODELS_TSV"
	annotate_dups "$MODELS_TSV"
	MODELS_SCANNED=1
}

# ---------------------------------------------------------------- optional extras

add_dir_extra() {
	local gidx=$1 glabel=$2 path=$3 name=$4 p
	[[ -d $path && ! -L $path ]] || return 0
	p=$(phys "$path") || return 0
	add_item "$EXTRAS_TSV" "$gidx" "$glabel" "@${5:-1024}" "$(age_days "$p")" "$name" "$p" rm "${p%/*}"
}

scan_installers() {
	local root f
	[[ -d $HOME/Downloads ]] || return 0
	root=$(phys "$HOME/Downloads") || return 0
	while IFS= read -r f; do
		add_item "$EXTRAS_TSV" 1 "Installers in Downloads · ~/Downloads" @1 "$(age_days "$f")" "${f#"$root"/}" "$f" rm "$root"
	done < <(find "$root" -maxdepth 2 -type f \( -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.mpkg' -o -iname '*.iso' \
		-o -iname '*.deb' -o -iname '*.rpm' -o -iname '*.appimage' -o -iname '*.msi' -o -iname '*.exe' -o -iname '*.xip' \) \
		! -name "$NL_GLOB" 2>/dev/null)
}

scan_trash() {
	local t p
	if [[ $OS == mac ]]; then t="$HOME/.Trash"; else t="$HOME/.local/share/Trash"; fi
	[[ -d $t ]] || return 0
	p=$(phys "$t") || return 0
	if ! ls -A "$p" >/dev/null 2>&1; then
		add_item "$EXTRAS_TSV" 2 "Trash" -1 -1 "$(tilde "$t")" "$p" empty-dir "${p%/*}" "no access: give your terminal Full Disk Access" 1
	elif [[ -n $(ls -A "$p") ]]; then
		add_item "$EXTRAS_TSV" 2 "Trash" @1 -1 "$(tilde "$t") (empty it)" "$p" empty-dir "${p%/*}"
	fi
}

# Folders under the cache roots that other parts of this script handle (models, tool-pruned caches).
handled_cache() {
	case $1 in
	com.apple.* | CloudKit | "Cleanup At Startup" | huggingface | dreamprox | dreamprox-* | lm-studio | llama.cpp | torch | \
		whisper | modelscope | go-build | pip | uv | pnpm | yarn | Yarn | Homebrew | vmlx-engine | vllm | bun) return 0 ;;
	esac
	return 1
}

scan_app_caches() {
	local roots=("$XDG_CACHE") r d label="App caches (rebuilt when needed)"
	[[ $OS == mac ]] && roots=("$HOME/Library/Caches" "$XDG_CACHE")
	for r in "${roots[@]}"; do
		[[ -d $r ]] || continue
		r=$(phys "$r") || continue
		for d in "$r"/*; do
			[[ -d $d && ! -L $d ]] || continue
			handled_cache "${d##*/}" && continue
			add_item "$EXTRAS_TSV" 3 "$label" "@$((MIN_MB * 1024))" "$(age_days "$d")" "$(tilde "$d")" "$d" rm "$r"
		done
	done
	add_dir_extra 3 "$label" "$HOME/pinokio/cache" "$(tilde "$HOME/pinokio/cache")"
}

scan_inference_caches() {
	local label="Inference and compile caches (models load slower once)" llama hf
	llama=$(llama_cache_dir)
	hf=$(hf_home)
	add_dir_extra 4 "$label" "$HOME/.omlx/cache" "oMLX KV cache  ~/.omlx/cache"
	add_dir_extra 4 "$label" "$XDG_CACHE/vmlx-engine" "vMLX prompt/block cache  $(tilde "$XDG_CACHE/vmlx-engine")"
	add_dir_extra 4 "$label" "$XDG_CACHE/vllm" "vLLM compile cache  $(tilde "$XDG_CACHE/vllm")"
	add_dir_extra 4 "$label" "$llama/slots" "llama.cpp saved slots  $(tilde "$llama/slots")"
	add_dir_extra 4 "$label" "$HOME/.triton/cache" "Triton kernels  ~/.triton/cache"
	add_dir_extra 4 "$label" "$hf/xet" "Hugging Face xet chunks  $(tilde "$hf/xet")"
	add_dir_extra 4 "$label" "$hf/datasets" "Hugging Face datasets cache  $(tilde "$hf/datasets")"
	[[ $OS == linux ]] && add_dir_extra 4 "$label" "/tmp/torchinductor_$USER_NAME" "TorchInductor  /tmp/torchinductor_$USER_NAME"
	return 0
}

scan_dev_caches() {
	local label="Developer caches (downloaded again on next build)" c flag block
	if command -v go >/dev/null 2>&1; then
		c=$(go env GOMODCACHE 2>/dev/null)
		if [[ -n $c && -d $c ]]; then
			flag=-
			block=0
			if pgrep -u "$USER_NAME" -x go >/dev/null 2>&1; then
				flag="go is running"
				block=1
			fi
			add_item "$EXTRAS_TSV" 5 "$label" @1 -1 "Go module cache  $(tilde "$c")" "$c" go-modcache go "$flag" "$block"
		fi
	fi
	if command -v uv >/dev/null 2>&1; then
		c=$(uv cache dir 2>/dev/null)
		if [[ -n $c && -d $c ]]; then
			flag=-
			block=0
			if pgrep -u "$USER_NAME" -x 'uvx?' >/dev/null 2>&1; then
				flag="uv is running"
				block=1
			fi
			add_item "$EXTRAS_TSV" 5 "$label" @1 -1 "uv cache, all of it  $(tilde "$c")" "$c" uv-clean uv "$flag" "$block"
		fi
	fi
	add_dir_extra 5 "$label" "$HOME/.cargo/registry/cache" "Cargo crate downloads  ~/.cargo/registry/cache"
	add_dir_extra 5 "$label" "$HOME/.cargo/registry/src" "Cargo unpacked crates  ~/.cargo/registry/src"
	add_dir_extra 5 "$label" "$HOME/.cargo/git/checkouts" "Cargo git checkouts  ~/.cargo/git/checkouts"
	add_dir_extra 5 "$label" "$HOME/.gradle/caches" "Gradle caches  ~/.gradle/caches"
	add_dir_extra 5 "$label" "$HOME/.gradle/wrapper/dists" "Gradle distributions  ~/.gradle/wrapper/dists"
	if [[ $OS == mac ]]; then
		add_dir_extra 5 "$label" "$HOME/Library/Developer/Xcode/DerivedData" "Xcode DerivedData"
		add_dir_extra 5 "$label" "$HOME/Library/Developer/Xcode/iOS DeviceSupport" "Xcode iOS DeviceSupport"
		add_dir_extra 5 "$label" "$HOME/Library/Developer/CoreSimulator/Caches" "Simulator caches"
	fi
	return 0
}

scan_avd_snapshots() {
	local avd
	for avd in "$HOME"/.android/avd/*.avd; do
		[[ -d $avd/snapshots ]] || continue
		add_dir_extra 6 "Android emulator quick-boot snapshots (next boot is a cold boot)" "$avd/snapshots" \
			"$(basename "$avd" .avd)"
	done
}

scan_docker_extras() {
	local images build
	((DOCKER_OK)) || return 0
	if ! run_timeout 60 docker system df --format '{{.Type}}|{{.Reclaimable}}' >"$WORK/dockerdf" 2>&1; then
		warn "docker system df did not answer within 60s, so Docker items are not listed."
		return 0
	fi
	images=$(human_to_kb "$(awk -F'|' '$1 == "Images" { split($2, a, " "); print a[1] }' "$WORK/dockerdf")")
	build=$(human_to_kb "$(awk -F'|' '$1 == "Build Cache" { split($2, a, " "); print a[1] }' "$WORK/dockerdf")")
	((images > 0)) && add_item "$EXTRAS_TSV" 7 "Docker" "$images" -1 "Images no container uses (pulled again when needed)" \
		docker docker-images docker
	((build > 0)) && add_item "$EXTRAS_TSV" 7 "Docker" "$build" -1 "All unused build cache (next builds start cold)" \
		docker docker-builder docker
	return 0
}

scan_packages() {
	local label="Packages nothing depends on" n snapfile name rev
	if command -v brew >/dev/null 2>&1 && brew autoremove --dry-run 2>/dev/null | grep -q 'Would autoremove'; then
		add_item "$EXTRAS_TSV" 8 "$label" -1 -1 "brew autoremove (formulae installed only as dependencies)" brew brew-autoremove brew
	fi
	[[ $OS == linux ]] || return 0
	if command -v apt-get >/dev/null 2>&1; then
		n=$(apt-get -s autoremove 2>/dev/null | grep -c '^Remv ')
		((n > 0)) && add_item "$EXTRAS_TSV" 8 "$label" -1 -1 "apt autoremove ($n packages, old kernels included)" apt apt-autoremove apt
	fi
	if command -v snap >/dev/null 2>&1; then
		while read -r name rev; do
			snapfile="/var/lib/snapd/snaps/${name}_${rev}.snap"
			[[ -f $snapfile ]] || continue
			add_item "$EXTRAS_TSV" 8 "$label" @1 -1 "snap $name, old revision $rev" "$snapfile" snap-rev /var/lib/snapd/snaps
		done < <(snap list --all 2>/dev/null | awk 'NR > 1 && /disabled/ { print $1, $3 }')
	fi
	return 0
}

scan_extras() {
	info "Scanning optional extras"
	: >"$EXTRAS_TSV"
	scan_installers
	scan_trash
	scan_app_caches
	scan_inference_caches
	scan_dev_caches
	scan_avd_snapshots
	scan_docker_extras
	scan_packages
	measure_items "$EXTRAS_TSV"
	annotate_in_use "$EXTRAS_TSV"
	EXTRAS_SCANNED=1
}

# ---------------------------------------------------------------- harmless tier

S_ID=()
S_DESC=()
S_SKIP=()

add_step() {
	S_ID+=("$1")
	S_DESC+=("$2")
	S_SKIP+=("${3:-}")
}

# Prints "KB<TAB>dir" for each NUL-separated dir from stdin in which nothing was modified or changed in the last
# $1 minutes and that holds no socket or pipe a live program listens on. Change time (ctime) counts because
# unpacking an archive restores old modification times but cannot backdate it. A dir find cannot fully read is
# never called idle. Sizing it right after the walk finds its metadata still cached.
idle_dirs() {
	# shellcheck disable=SC2016  # $1 and $2 belong to the child sh
	xargs -0 -r -P "$JOBS" -n 1 sh -c \
		'out=$(find "$2" \( -mmin "-$1" -o -cmin "-$1" -o -type s -o -type p \) -print -quit 2>/dev/null) && [ -z "$out" ] && du -sk "$2" 2>/dev/null' \
		idle "$1"
}

tmp_scan_root() {
	local root=$1 d name
	: >"$WORK/tmp.slow"
	: >"$WORK/tmp.fast"
	while IFS= read -r d; do
		name=${d##*/}
		case $name in
		tmux-* | ssh-* | systemd-private-* | snap-private-tmp | com.apple.* | vscode-* | lima* | colima* | krb5cc* | pulse-*) continue ;;
		go-build* | go-link-* | chromedp-runner*) printf '%s\n' "$d" >>"$WORK/tmp.fast" ;;
		*) [[ $d == "$WORK" ]] || printf '%s\n' "$d" >>"$WORK/tmp.slow" ;;
		esac
	done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -user "$USER_NAME" ! -name '.*' ! -name "$NL_GLOB" ! -name "$TAB_GLOB" 2>/dev/null)
	{
		tr '\n' '\0' <"$WORK/tmp.slow" | idle_dirs $((TEMP_DAYS * 1440))
		tr '\n' '\0' <"$WORK/tmp.fast" | idle_dirs 1440
	} >"$WORK/tmp.idle"
	# tmp.list columns: root, path, KB.
	awk -F'\t' -v r="$root" '{ print r "\t" $2 "\t" $1 }' "$WORK/tmp.idle" >>"$WORK/tmp.list"
	# pytest keeps its last three runs; finished ones are dead weight (and use RAM when /tmp is tmpfs).
	d="$root/pytest-of-$USER_NAME"
	if [[ -d $d && -O $d ]] && ! cut -f2 "$WORK/tmp.idle" | grep -Fxq -- "$d"; then
		find "$d" -mindepth 1 -maxdepth 1 -type d -name 'pytest-[0-9]*' ! -name "$TAB_GLOB" -print0 2>/dev/null |
			idle_dirs 1440 | awk -F'\t' -v r="$d" '{ print r "\t" $2 "\t" $1 }' >>"$WORK/tmp.list"
	fi
}

collect_tmp() {
	local roots=() p i j dup clone
	: >"$WORK/tmp.list"
	: >"$WORK/clones.list"
	if [[ -n ${TMPDIR:-} && -d $TMPDIR ]] && p=$(phys "$TMPDIR"); then roots+=("$p"); fi
	if p=$(phys /tmp); then roots+=("$p"); fi
	for ((i = 0; i < ${#roots[@]}; i++)); do
		dup=0
		for ((j = 0; j < i; j++)); do [[ ${roots[j]} == "${roots[i]}" ]] && dup=1; done
		((dup)) || tmp_scan_root "${roots[i]}"
	done
	# Chrome copies itself into a code_sign_clone dir each time automation launches it and rarely cleans up.
	# A clone dir's own times are its launch time; a running Chrome keeps its clone open.
	if [[ $OS == mac && -n ${TMPDIR:-} ]]; then
		for clone in "${TMPDIR%/}"/../X/*.code_sign_clone; do
			[[ -d $clone ]] || continue
			clone=$(phys "$clone") || continue
			find "$clone" -mindepth 1 -maxdepth 1 -type d -user "$USER_NAME" -mmin +1440 -cmin +1440 ! -name "$NL_GLOB" 2>/dev/null |
				awk -v r="$clone" '{ print r "\t" $0 }' >>"$WORK/clones.list"
		done
	fi
	filter_not_in_use 2 "$WORK/tmp.list" "$WORK/tmp.ok"
	filter_not_in_use 2 "$WORK/clones.list" "$WORK/clones.ok"
}

# Starts collect_tmp in the background; plan_safe waits for it.
start_tmp_scan() {
	collect_tmp &
	TMP_SCAN_PID=$!
}

collect_logs() {
	local d mins=$((LOG_DAYS * 1440)) dirs=("$HOME/.npm/_logs" "$HOME/.omlx/logs" "$HOME/.mtplx/logs"
		"$(lmstudio_home)/server-logs" "$HOME/.unsloth/studio/logs")
	[[ $OS == mac ]] && dirs+=("$HOME/Library/Logs")
	: >"$WORK/logs.list"
	for d in "${dirs[@]}"; do
		[[ -d $d ]] || continue
		d=$(phys "$d") || continue
		find "$d" -type f -mmin "+$mins" ! -name "$NL_GLOB" 2>/dev/null | awk -v r="$d" '{ print r "\t" $0 }' >>"$WORK/logs.list"
	done
	for d in "$HOME"/.gradle/daemon/*/; do
		[[ -d $d ]] || continue
		d=$(phys "$d") || continue
		find "$d" -maxdepth 1 -type f -name '*.log' -mmin "+$mins" ! -name "$NL_GLOB" 2>/dev/null |
			awk -v r="$d" '{ print r "\t" $0 }' >>"$WORK/logs.list"
	done
	filter_not_in_use 2 "$WORK/logs.list" "$WORK/logs.ok"
}

count_lines() {
	wc -l <"$1" | tr -d ' '
}

plan_safe() {
	local n c
	S_ID=()
	S_DESC=()
	S_SKIP=()
	info "Planning harmless cleanups (checking temp dirs can take a minute)"

	if ((TMP_SCAN_PID)); then
		wait "$TMP_SCAN_PID"
		TMP_SCAN_PID=0
	else
		collect_tmp
	fi
	if ((INUSE_UNKNOWN || MOUNTS_UNKNOWN)); then
		add_step tmp "Temp dirs and old logs" "there is no telling what is in use (see the warning above)"
	fi
	n=$(count_lines "$WORK/tmp.ok")
	((n > 0)) && add_step tmp "Temp dirs left by tests and tools: $n dirs, $(human "$(awk -F'\t' '{ s += $3 } END { print s + 0 }' "$WORK/tmp.ok")")"
	n=$(count_lines "$WORK/clones.ok")
	((n > 0)) && add_step clones "Chrome code-sign clones from automated runs: $n dirs (they share disk blocks, so they free far less than du shows)"

	c=$(go_cache_dir)
	[[ -n $c ]] && add_step go "Go build cache: entries unused for ${GO_CACHE_HOURS}h+ in $(tilde "$c")"

	for c in "$HOME"/.gradle/caches/build-cache-*; do
		if [[ -d $c ]]; then
			add_step gradle "Gradle build cache entries older than a day"
			break
		fi
	done

	command -v brew >/dev/null 2>&1 && add_step brew "Homebrew: old versions and downloads older than 7 days"

	if command -v npm >/dev/null 2>&1 && [[ -d $HOME/.npm/_cacache ]]; then
		if installing npm 'install|i|ci|add|update|up|upgrade'; then
			add_step npm "npm cache" "an npm install is running"
		else
			add_step npm "npm cache"
		fi
	fi
	if command -v pnpm >/dev/null 2>&1; then
		if installing pnpm 'install|i|add|update|up'; then
			add_step pnpm "pnpm store: packages no project uses" "a pnpm install is running"
		else
			add_step pnpm "pnpm store: packages no project uses"
		fi
	fi
	if command -v yarn >/dev/null 2>&1 && [[ $(yarn --version 2>/dev/null) == 1.* ]]; then
		if installing yarn 'install|add|upgrade'; then
			add_step yarn "Yarn 1 cache" "a yarn install is running"
		else
			add_step yarn "Yarn 1 cache"
		fi
	fi
	if command -v bun >/dev/null 2>&1; then
		if installing bun 'install|i|add|update'; then
			add_step bun "Bun install cache" "a bun install is running"
		else
			add_step bun "Bun install cache"
		fi
	fi
	if pip_cmd; then
		if pgrep -u "$USER_NAME" -f '(pip[0-9.]*|-m pip) (install|download|wheel)( |$)' >/dev/null 2>&1; then
			add_step pip "pip cache" "a pip install is running"
		else
			add_step pip "pip cache"
		fi
	fi
	if command -v conda >/dev/null 2>&1; then
		if installing conda 'install|create|update|env'; then
			add_step conda "conda: downloaded package tarballs and index cache" "a conda install is running"
		else
			add_step conda "conda: downloaded package tarballs and index cache"
		fi
	fi
	if command -v uv >/dev/null 2>&1; then
		# A running uv or uvx holds the cache lock, and pruning under it would break their environments.
		if pgrep -u "$USER_NAME" -x 'uvx?' >/dev/null 2>&1; then
			add_step uv "uv cache: unused entries" "uv is running; run again when it is idle"
		else
			add_step uv "uv cache: unused entries"
		fi
	fi
	if ((DOCKER_OK)); then
		if command -v colima >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
			add_step docker "Docker: build cache unused for a day and dangling images, then fstrim in Colima"
		else
			add_step docker "Docker: build cache unused for a day and dangling images"
		fi
	fi

	collect_logs
	n=$(count_lines "$WORK/logs.ok")
	((n > 0)) && add_step logs "Log files older than ${LOG_DAYS} days: $n files, $(human "$(list_kb 2 "$WORK/logs.ok")")"

	if [[ $OS == mac ]] && xcrun --find simctl >/dev/null 2>&1; then
		add_step simctl "Xcode simulators whose runtime is no longer installed"
	fi
	if [[ $OS == linux ]]; then
		command -v apt-get >/dev/null 2>&1 && add_step apt "apt package cache (sudo)"
		command -v journalctl >/dev/null 2>&1 && add_step journal "System journal older than ${JOURNAL_DAYS} days (sudo)"
	fi
	SAFE_PLANNED=1
	return 0
}

step_tmp() {
	local root path
	while IFS="$TAB" read -r root path _; do
		safe_rm "$path" "$root"
	done <"$WORK/tmp.ok"
}

step_clones() {
	local root path
	while IFS="$TAB" read -r root path; do
		safe_rm "$path" "$root"
	done <"$WORK/clones.ok"
}

step_go() {
	local c
	c=$(go_cache_dir)
	if ((DRY_RUN)); then
		say "    would remove $(find "$c" -mindepth 2 -maxdepth 2 -path "$c/[0-9a-f][0-9a-f]/*" -type f \
			-mmin "+$((GO_CACHE_HOURS * 60))" | wc -l | tr -d ' ') cache files"
		return 0
	fi
	# Go marks entries as used by touching them (at most hourly) and trims old ones itself the same way.
	find "$c" -mindepth 2 -maxdepth 2 -path "$c/[0-9a-f][0-9a-f]/*" -type f -mmin "+$((GO_CACHE_HOURS * 60))" -delete ||
		fail "Some Go cache entries could not be removed"
}

step_gradle() {
	local d
	for d in "$HOME"/.gradle/caches/build-cache-*; do
		[[ -d $d ]] || continue
		if ((DRY_RUN)); then
			say "    would remove $(find "$d" -maxdepth 1 -type f -mmin +1440 ! -name '*.lock' ! -name '*.properties' |
				wc -l | tr -d ' ') entries in $(tilde "$d")"
		else
			find "$d" -maxdepth 1 -type f -mmin +1440 ! -name '*.lock' ! -name '*.properties' -delete ||
				fail "Some Gradle build cache entries in $(tilde "$d") could not be removed"
		fi
	done
}

step_brew() { run_tool "brew cleanup" 1800 brew cleanup --prune=7; }
step_npm() { run_tool "npm cache clean" 600 npm cache clean --force; }
step_pnpm() { run_tool "pnpm store prune" 600 pnpm store prune; }
step_yarn() { run_tool "yarn cache clean" 600 yarn cache clean; }
step_bun() { run_tool "bun pm cache rm" 600 bun pm cache rm; }
step_pip() { pip_cmd && run_tool "pip cache purge" 600 "${PIP[@]}" cache purge; }
# Not --all: its --packages part breaks environments that symlink into the package cache.
step_conda() { run_tool "conda clean" 900 conda clean --tarballs --index-cache --yes; }
step_uv() { run_tool "uv cache prune" 600 uv cache prune; }
step_simctl() { run_tool "simctl delete unavailable" 600 xcrun simctl delete unavailable; }
step_apt() { run_tool "apt-get clean" 600 sudo -n apt-get clean; }
step_journal() { run_tool "journalctl vacuum" 600 sudo -n journalctl --vacuum-time="${JOURNAL_DAYS}d"; }

step_docker() {
	run_tool "docker builder prune" 1800 docker builder prune -af --filter until=24h
	run_tool "docker image prune" 1800 docker image prune -f
	colima_trim
}

step_logs() {
	if ((DRY_RUN)); then
		say "    would remove $(count_lines "$WORK/logs.ok") log files"
		return 0
	fi
	cut -f2 "$WORK/logs.ok" | tr '\n' '\0' | xargs -0 -r rm -f -- || fail "Some old log files could not be removed"
}

show_safe_plan() {
	local i n=0
	say ""
	say "${BOLD}Harmless cleanup${NC}"
	if ((${#S_ID[@]} == 0)); then
		say "  Nothing to do."
		return 0
	fi
	for ((i = 0; i < ${#S_ID[@]}; i++)); do
		if [[ -n ${S_SKIP[i]} ]]; then
			say "   -  ${DIM}${S_DESC[i]}: skipped, ${S_SKIP[i]}${NC}"
		else
			n=$((n + 1))
			printf '  %2d. %s\n' "$n" "${S_DESC[i]}"
		fi
	done
}

run_safe() {
	local i start before
	start=$(df_avail)
	for ((i = 0; i < ${#S_ID[@]}; i++)); do
		[[ -n ${S_SKIP[i]} ]] && continue
		if [[ ${S_ID[i]} == apt || ${S_ID[i]} == journal ]]; then
			ensure_sudo "${S_DESC[i]}" || continue
		fi
		info "${S_DESC[i]}"
		before=$(df_avail)
		"step_${S_ID[i]}"
		((DRY_RUN)) || say "    freed $(freed_since "$before")"
	done
	SAFE_RAN=1
	((DRY_RUN)) || info "Harmless cleanup freed $(freed_since "$start") in total (measured with df)."
}

safe_flow() {
	show_safe_plan
	((${#S_ID[@]})) || return 0
	if ((!DRY_RUN && !ASSUME_YES)); then
		[[ -t 0 ]] || die "Run with --yes to clean without a terminal."
		confirm "Run these now?" || return 0
	fi
	run_safe
}

# ---------------------------------------------------------------- report

# Sizes the caches the harmless tier trims (extras lists the others with their sizes). The Go build cache can hold
# millions of files, so each cache is measured one subfolder per du in parallel, in the background.
start_cache_sizes() {
	local p
	for p in "$(go_cache_dir)" "$HOME/.npm/_cacache" "$(pip_cmd && "${PIP[@]}" cache dir 2>/dev/null)" \
		"$(command -v brew >/dev/null 2>&1 && brew --cache 2>/dev/null)" "$HOME/Library/Logs"; do
		[[ -n $p && -d $p ]] || continue
		find "$p" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | xargs -0 -r -P "$JOBS" -n 8 du -sk 2>/dev/null |
			awk -v p="$p" '{ s += $1 } END { print s + 0 "\t" p }'
	done >"$WORK/caches.du" &
	CACHE_SIZES_PID=$!
}

report_cache_sizes() {
	local path kb
	wait "$CACHE_SIZES_PID"
	say ""
	say "${BOLD}Caches the harmless cleanup trims${NC} ${DIM}(sizes skip unreadable files)${NC}"
	sort -t "$TAB" -k1,1nr "$WORK/caches.du" | while IFS="$TAB" read -r kb path; do
		((kb > 0)) && printf '  %8s  %s\n' "$(human "$kb")" "$(tilde "$path")"
	done
}

show_report() {
	local n
	say ""
	say "${BOLD}Disk${NC}"
	df -Pk "${TRACK_PATHS[@]}" 2>/dev/null | awk 'NR > 1 && !seen[$6]++ {
		printf "  %-28s %6.0fG free of %6.0fG (%s used)\n", $6, $4 / 1048576, $2 / 1048576, $5 }'
	if [[ $OS == linux ]] && [[ $(df -P /tmp 2>/dev/null | awk 'NR == 2 { print $1 }') == tmpfs ]]; then
		say "  ${YELLOW}/tmp is in RAM (tmpfs), so temp files there use memory, not disk.${NC}"
	fi
	if [[ $OS == mac ]]; then
		n=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple')
		((n > 0)) && say "  ${YELLOW}$n local Time Machine snapshot(s) exist; deleted files keep using space until macOS thins them.${NC}"
	fi
	if ((DOCKER_OK)); then
		say ""
		say "${BOLD}Docker${NC}"
		run_timeout 60 docker system df 2>&1 | sed 's/^/  /'
	fi
	report_cache_sizes
	show_safe_plan
	load_items "$EXTRAS_TSV"
	say ""
	say "${BOLD}Optional extras${NC}"
	render_items
	load_items "$MODELS_TSV"
	say "${BOLD}AI models${NC}"
	render_items
}

# ---------------------------------------------------------------- main

summary_label() {
	local count kb
	if (($1)); then
		read -r count kb <<<"$(tsv_summary "$2")"
		printf '%s %s, %s\n' "$count" "$3" "$(human "$kb")"
	else
		printf 'not scanned yet\n'
	fi
}

main_menu() {
	local choice safe_label
	[[ -t 0 && -t 1 ]] || die "The menu needs a terminal. Use: $0 report, or $0 safe --yes"
	while true; do
		safe_label="checks temp dirs first"
		((SAFE_PLANNED)) && safe_label="${#S_ID[@]} steps"
		((SAFE_RAN)) && safe_label="done"
		say ""
		say "${BOLD}What would you like to clean?${NC}"
		say "  1) Harmless cleanup ($safe_label)"
		say "  2) Optional extras ($(summary_label "$EXTRAS_SCANNED" "$EXTRAS_TSV" items))"
		say "  3) AI models ($(summary_label "$MODELS_SCANNED" "$MODELS_TSV" models))"
		say "  4) Full report"
		say "  q) Quit"
		read -r -p "> " choice || break
		case $choice in
		1)
			if ((SAFE_RAN)); then
				info "Already done this run."
			else
				plan_safe
				safe_flow
			fi
			;;
		2)
			((EXTRAS_SCANNED)) || scan_extras
			pick "$EXTRAS_TSV" "Optional extras"
			;;
		3)
			((MODELS_SCANNED)) || scan_models
			pick "$MODELS_TSV" "AI models"
			;;
		4)
			start_cache_sizes
			((SAFE_PLANNED)) || start_tmp_scan
			((EXTRAS_SCANNED)) || scan_extras
			((MODELS_SCANNED)) || scan_models
			((SAFE_PLANNED)) || plan_safe
			show_report
			;;
		q | Q | "") break ;;
		*) warn "Pick 1-4 or q." ;;
		esac
	done
}

while (($#)); do
	case $1 in
	report | safe | extras | models) COMMAND=$1 ;;
	-y | --yes) ASSUME_YES=1 ;;
	-n | --dry-run) DRY_RUN=1 ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "Unknown argument: $1"
		;;
	esac
	shift
done

check_number CLEANUP_TEMP_DAYS "$TEMP_DAYS"
check_number CLEANUP_LOG_DAYS "$LOG_DAYS"
check_number CLEANUP_JOURNAL_DAYS "$JOURNAL_DAYS"
check_number CLEANUP_GO_CACHE_HOURS "$GO_CACHE_HOURS"
check_number CLEANUP_MIN_MB "$MIN_MB"

case $(uname -s) in
Darwin)
	OS=mac
	JOBS=$(sysctl -n hw.ncpu)
	;;
Linux)
	OS=linux
	JOBS=$(nproc)
	;;
*) die "Only macOS and Linux are supported." ;;
esac
((JOBS > 8)) && JOBS=8
((EUID == 0)) && die "Run this as your normal user. It asks for sudo itself for the few steps that need it."

USER_NAME=$(id -un)
XDG_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cleanup-disk.XXXXXX") || die "Could not create a work dir."
WORK=$(phys "$WORK")
trap 'rm -rf -- "$WORK"' EXIT
MODELS_TSV="$WORK/models.tsv"
EXTRAS_TSV="$WORK/extras.tsv"
: >"$MODELS_TSV"
: >"$EXTRAS_TSV"

track "$HOME"
track /tmp
[[ -n ${TMPDIR:-} ]] && track "$TMPDIR"
START_AVAIL=$(df_avail)
((DRY_RUN)) && info "Dry run: nothing will be removed."

info "Checking which files are in use"
build_inuse_index
check_docker
build_docker_refs

case $COMMAND in
menu) main_menu ;;
report)
	start_cache_sizes
	start_tmp_scan
	scan_extras
	scan_models
	plan_safe
	show_report
	;;
safe)
	plan_safe
	safe_flow
	;;
extras)
	scan_extras
	pick "$EXTRAS_TSV" "Optional extras"
	;;
models)
	scan_models
	pick "$MODELS_TSV" "AI models"
	;;
esac

if ((!DRY_RUN)) && [[ $COMMAND != report ]]; then
	info "Free space now $(human "$(df_avail)") (was $(human "$START_AVAIL"))."
fi
if ((FAILURES)); then
	fail "$FAILURES step(s) failed; see the messages above."
	exit 1
fi
