# Loads the SELinux policy if none is loaded yet, and labels the filesystem.
#
# Runs in two places:
#   - in the initrd, chrooted into the new root, before NixOS activation, so
#     that everything activation creates is labelled correctly;
#   - from the activation script on `nixos-rebuild switch`, to label store
#     paths that arrived since the last run.
#
# Nix is not involved. Nix leaves `security.selinux` attributes alone
# (its `ignored-acls` default), so labels set here stay in place.

set -euo pipefail

store=/nix/store
marker=trusted.nixos-selinux
stateDir=/var/lib/selinux-nixos
stamp=$stateDir/labelled-at

saved_args=("$@")

policy=
spec=
rev=
mutable_rev=
exact_rev=
exact_file=
remounted=
relabel_mutable=
record=1
preinstall=
force=
exact=()
relabel=()
persistent=()

while [ $# -gt 0 ]; do
  case "$1" in
    --policy) policy=$2; shift 2 ;;
    --spec) spec=$2; shift 2 ;;
    --rev) rev=$2; shift 2 ;;
    --mutable-rev) mutable_rev=$2; shift 2 ;;
    --exact-rev) exact_rev=$2; shift 2 ;;
    --exact) exact+=("$2"); shift 2 ;;
    --exact-file) exact_file=$2; shift 2 ;;
    --relabel) relabel+=("$2"); shift 2 ;;
    --remounted) remounted=1; shift ;;
    --relabel-mutable) relabel_mutable=1; shift ;;
    --relabel-mutable-early) relabel_mutable=1; record=; shift ;;
    --persistent-root) persistent+=("$2"); shift 2 ;;
    --force) force=1; shift ;;
    --preinstall) preinstall=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

: "${mutable_rev:=$rev}"

log() { echo "selinux-setup: $*"; }

if [ -n "$remounted" ]; then
  mount -o remount,bind,rw "$store"
fi

active=
if [ -e /sys/fs/selinux/load ]; then active=1; fi

if [ -n "$preinstall" ]; then
  # A generation is being installed without being activated: label now,
  # while the machine is up, what its first boot would otherwise label.
  # A kernel without SELinux stores labels as they are given, so on a
  # system that is about to enable it, that is every file. A kernel with
  # SELinux already has the mutable paths right; only the store is new.
  record=
  if [ -z "$active" ]; then relabel_mutable=1; else relabel_mutable=; fi
elif [ -z "$active" ]; then
  log "SELinux is not active in the running kernel, nothing to do"
  exit 0
fi

# After the re-execution for a writable store (below), only the store is
# left to do.
if [ -n "$remounted" ]; then relabel_mutable=; fi

if [ -z "$preinstall" ]; then

# --- Policy -------------------------------------------------------------------

# Before the first policy load every process runs in the context "kernel".
current=$(tr -d '\0' < /proc/self/attr/current)
if [ "$current" = kernel ]; then
  # The kernel takes the whole policy in a single write.
  dd if="$policy" of=/sys/fs/selinux/load bs=256M status=none
  log "loaded policy $policy"
fi

fi # not --preinstall

label_one() {
  # Label a single path without descending into it, by the rules for the
  # second argument if there is one.
  local path=$1 context
  context=$(selabel_lookup -b file -f "$spec" -k "${2:-$path}" 2>/dev/null \
    | sed -n 's/^Default context: //p' || true)
  if [ -n "$context" ] && [ "$context" != "<<none>>" ]; then
    setfilecon "$context" "$path" 2>/dev/null || true
  fi
}

# --- Mutable paths ------------------------------------------------------------

# Top-level directories, every time. New files take their parent
# directory's type, so this alone gets most of what activation creates
# right. On a fresh root some of them do not exist yet. Stage 2 and
# activation would create them a moment later, with these same modes, but
# then they would inherit the root directory's type.
[ -d /etc ] || install -d -m 0755 /etc
[ -d /var ] || install -d -m 0755 /var
[ -d /home ] || install -d -m 0755 /home
[ -d /root ] || install -d -m 0700 /root
[ -d /tmp ] || install -d -m 1777 /tmp
[ -d /var/lib ] || install -d -m 0755 /var/lib
[ -d /var/log ] || install -d -m 0755 /var/log
for dir in / /etc /var /var/lib /var/log /nix /nix/var "$store" /home /root /tmp /boot /bin /usr /usr/bin; do
  if [ -d "$dir" ]; then label_one "$dir"; fi
done

# Persistent storage of an ephemeral root (impermanence): /persist/var/log
# is the same directory as /var/log and gets the same label. Its top
# levels are labelled every time for the same reason as above.
for root in "${persistent[@]}"; do
  if [ -d "$root" ]; then label_one "$root" /; fi
  for dir in /etc /var /var/lib /var/log /home /root; do
    if [ -d "$root$dir" ]; then label_one "$root$dir" "$dir"; fi
  done
done

# Symlinks that activation creates under /run and every domain follows.
for link in /run/current-system /run/booted-system; do
  if [ -L "$link" ]; then setfiles -F "$spec" "$link" 2>/dev/null || true; fi
done

# A full pass over the mutable paths, when asked to and only if the
# labelling rules changed since the last one.
#
# It runs twice in a boot. Early, in the initrd: on a system that has
# files but no labels yet (SELinux was just enabled, or it was booted
# without), nothing may start before they are labelled. And again after
# activation, to correct what inheritance alone got wrong in the files
# activation made. Only the second one records that the pass is done.
if [ -n "$relabel_mutable" ]; then
  persistent_devs=" "
  for root in "${persistent[@]}"; do
    if [ -d "$root" ]; then persistent_devs+="$(stat -c %d "$root") "; fi
  done

  if [ -n "$force" ] || [ "$(cat "$stateDir/relabelled" 2>/dev/null || true)" != "$mutable_rev" ]; then
    existing=()
    for path in "${relabel[@]}"; do
      if [ -e "$path" ]; then existing+=("$path"); fi
    done
    # setfiles stays on the filesystem of each path it is given, so add
    # the disk filesystems mounted below them: a separate /home, a
    # bind-mounted file. Not the store and not persistent storage, which
    # have their own passes.
    while read -r target fstype; do
      case "$fstype" in
        ext2 | ext3 | ext4 | xfs | btrfs | f2fs | bcachefs | jfs | zfs) ;;
        *) continue ;;
      esac
      case "$target" in "$store" | "$store"/*) continue ;; esac
      if [[ $persistent_devs == *" $(stat -c %d "$target") "* ]]; then continue; fi
      for path in "${existing[@]}"; do
        if [[ $path == / || $target == "$path"/* ]]; then
          existing+=("$target")
          break
        fi
      done
    done < <(findmnt -rno TARGET,FSTYPE | grep -v '^/ ')
    exclude=(-e "$store")
    for root in "${persistent[@]}"; do
      if [ -d "$root" ]; then exclude+=(-e "$root"); fi
    done
    if [ ${#existing[@]} -gt 0 ]; then
      # A full pass reads every file, about half a minute per million.
      # It leaves a note of when it started and what it covered, so that
      # the next pass, later in the same boot or on the first boot after
      # an install, only looks at files changed since. The note is not
      # trusted if the clock is behind it.
      covered=()
      if [ -z "$force" ] \
        && [ "$(head -n 1 "$stamp" 2>/dev/null || true)" = "$mutable_rev" ] \
        && [ "$(date +%s)" -ge "$(stat -c %Y "$stamp")" ]; then
        mapfile -t covered < <(tail -n +2 "$stamp")
      fi
      full=()
      changed=()
      for path in "${existing[@]}"; do
        if printf '%s\n' "${covered[@]}" | grep -qxF -- "$path"; then
          changed+=("$path")
        else
          full+=("$path")
        fi
      done
      mkdir -p "$stateDir"
      {
        echo "$mutable_rev"
        printf '%s\n' "${existing[@]}"
      } > "$stamp.new"

      # NixOS makes /var/empty immutable, which forbids a new label too.
      locked=
      if lsattr -d /var/empty 2>/dev/null | cut -d' ' -f1 | grep -q i; then
        chattr -i /var/empty && locked=1
      fi
      # A file that cannot be relabelled must not stop the boot. The
      # pass is not recorded as done then, and is tried again.
      failed=
      if [ ${#full[@]} -gt 0 ]; then
        log "relabelling ${full[*]}"
        setfiles -F "${exclude[@]}" "$spec" "${full[@]}" || failed=1
      fi
      if [ ${#changed[@]} -gt 0 ]; then
        log "relabelling what changed in ${changed[*]}"
        prune=(-path "$store")
        for root in "${persistent[@]}"; do prune+=(-o -path "$root"); done
        find "${changed[@]}" -xdev \( "${prune[@]}" \) -prune -o -newercm "$stamp" -print0 \
          > "$stamp.changed"
        # setfiles descends into directories, so those are looked up and
        # set here, all in one go.
        : > "$stamp.dirs"
        while IFS= read -r -d "" path; do
          if [ -d "$path" ] && [ ! -L "$path" ]; then
            printf '%s\n' "$path" >> "$stamp.dirs"
          else
            printf '%s\0' "$path"
          fi
        done < "$stamp.changed" > "$stamp.files"
        if [ -s "$stamp.files" ]; then
          setfiles -0 -F -f "$stamp.files" "$spec" || failed=1
        fi
        xargs -a "$stamp.dirs" -d '\n' -r matchpathcon -f "$spec" \
          | awk -F'\t' '$2 != "<<none>>" { print $2 "\t" $1 }' > "$stamp.contexts" || true
        cut -f1 "$stamp.contexts" | sort -u | while IFS= read -r context; do
          awk -F'\t' -v context="$context" '$1 == context { print $2 }' "$stamp.contexts" \
            | xargs -d '\n' -r setfilecon "$context" || true
        done
        rm -f "$stamp.changed" "$stamp.files" "$stamp.dirs" "$stamp.contexts"
      fi
      if [ -n "$failed" ]; then
        log "some files could not be relabelled"
        record=
        rm -f "$stamp.new"
      else
        # A note that covers more than this pass saw (filesystems that
        # are not mounted yet in the initrd) stays as it is.
        keep=
        for path in "${covered[@]}"; do
          if ! printf '%s\n' "${existing[@]}" | grep -qxF -- "$path"; then keep=1; fi
        done
        if [ -n "$keep" ]; then rm -f "$stamp.new"; else mv "$stamp.new" "$stamp"; fi
      fi
      if [ -n "$locked" ]; then chattr +i /var/empty; fi
      # The rules leave the content of temporary directories alone.
      # Leftovers from before SELinux have no label at all there; give
      # them their directory's.
      for dir in /tmp /var/tmp; do
        if [ ! -d "$dir" ] || [ -L "$dir" ]; then continue; fi
        context=$(getfattr -h --only-values -n security.selinux "$dir" 2>/dev/null | tr -d '\0' || true)
        if [ -z "$context" ]; then continue; fi
        find "$dir" -xdev -mindepth 1 ! -type l -print0 \
          | xargs -0 -r getfattr -h --absolute-names -n security.selinux 2>&1 \
          | awk '
              /^# file: / { file = substr($0, 9) }
              /^security.selinux=.*:unlabeled_t:/ { print file }
              /: security.selinux: No such attribute$/ {
                sub(/: security.selinux: No such attribute$/, "")
                print
              }
            ' \
          | xargs -d '\n' -r setfilecon "$context" || true
      done
    fi
    if [ -n "$record" ]; then
      mkdir -p "$stateDir"
      echo "$mutable_rev" > "$stateDir/relabelled.tmp"
      mv "$stateDir/relabelled.tmp" "$stateDir/relabelled"
      rm -f "$stamp"
    fi
  fi

  # Persistent storage keeps its own record, because the one above is
  # gone on every boot of an ephemeral root.
  for root in "${persistent[@]}"; do
    [ -d "$root" ] || continue
    if [ -n "$force" ] || [ "$(cat "$root$stateDir/relabelled" 2>/dev/null || true)" != "$mutable_rev" ]; then
      log "relabelling $root as /"
      mkdir -p "$root$stateDir"
      if ! setfiles -F -r "$root" "$spec" "$root"; then
        log "some files in $root could not be relabelled"
      elif [ -n "$record" ]; then
        echo "$mutable_rev" > "$root$stateDir/relabelled.tmp"
        mv "$root$stateDir/relabelled.tmp" "$root$stateDir/relabelled"
      fi
    fi
  done
fi

# --- Nix store ----------------------------------------------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every top-level store path. Names starting with a dot are not store
# paths: the hard-link farm of the optimiser and its short-lived temporary
# links, which can vanish while this runs.
find "$store" -mindepth 1 -maxdepth 1 ! -name '.*' -print | sort > "$work/all"

# Store paths that hold a file with an exact rule. Their labels depend on
# those rules as well as on the generic ones.
: > "$work/exact"
: > "$work/exact-files"
{
  if [ ${#exact[@]} -gt 0 ]; then printf '%s\n' "${exact[@]}"; fi
  if [ -n "$exact_file" ] && [ -e "$exact_file" ]; then cat "$exact_file"; fi
} | while IFS= read -r path; do
  root=$(echo "$path" | cut -d/ -f1-4)
  if [ -e "$root" ]; then echo "$root" >> "$work/exact"; fi
  if [ -e "$path" ]; then echo "$path" >> "$work/exact-files"; fi
done
sort -u -o "$work/exact" "$work/exact"

# Store paths already labelled under the current rules carry a marker on
# their top-level inode. A path that is garbage collected and fetched again
# is a new inode without a marker, so it is picked up again by itself.
{
  xargs -a "$work/all" -d '\n' -r \
    getfattr -h --absolute-names -n "$marker" -e text 2>/dev/null || true
} | awk -v plain="$marker=\"$rev\"" -v full="$marker=\"$rev+$exact_rev\"" '
    /^# file: / { file = substr($0, 9) }
    $0 == plain { print file > "'"$work/plain"'" }
    $0 == full { print file > "'"$work/full"'" }
  '
touch "$work/plain" "$work/full"
sort -o "$work/plain" "$work/plain"
sort -o "$work/full" "$work/full"

# Done: marked under the generic rules and without exact rules, or marked
# under both.
{
  comm -23 "$work/plain" "$work/exact"
  comm -12 "$work/full" "$work/exact"
} | sort > "$work/done"

comm -23 "$work/all" "$work/done" > "$work/todo"

# Files with exact rules are checked on every run, whatever the markers
# say. With store optimisation, a file of identical content in another
# store path is the same inode, and labelling that other path under the
# generic rules takes the exact label away. Exact rules are applied last
# so that they win.
drift=
if [ -s "$work/exact-files" ]; then
  drift=$(xargs -a "$work/exact-files" -d '\n' -r setfiles -n -v -F "$spec" 2>/dev/null \
    | grep -c '^Would relabel' || true)
  if [ "$drift" = 0 ]; then drift=; fi
fi

count=$(wc -l < "$work/todo")
if [ "$count" -eq 0 ] && [ -z "$drift" ]; then
  log "store labels are up to date"
  exit 0
fi

# The store is normally mounted read-only. Make it writable in a private
# mount namespace, the same way the Nix daemon does, and start over there.
if [ ! -w "$store" ]; then
  if [ -n "$remounted" ]; then
    echo "selinux-setup: cannot make $store writable" >&2
    exit 1
  fi
  exec unshare --mount -- "$0" --remounted "${saved_args[@]}"
fi

start=$(date +%s)
if [ "$count" -gt 0 ]; then
  log "labelling $count store paths"
  setfiles -F -f "$work/todo" "$spec"
fi
if [ -s "$work/exact-files" ]; then
  if [ -n "$drift" ]; then log "restoring $drift exact labels"; fi
  xargs -a "$work/exact-files" -d '\n' -r setfiles -F "$spec"
fi

# Mark the paths only once all of them are labelled, so an interrupted run
# is repeated in full.
comm -23 "$work/todo" "$work/exact" > "$work/mark-plain"
comm -12 "$work/todo" "$work/exact" > "$work/mark-full"
xargs -a "$work/mark-plain" -d '\n' -r \
  setfattr -h -n "$marker" -v "$rev" 2>/dev/null || true
xargs -a "$work/mark-full" -d '\n' -r \
  setfattr -h -n "$marker" -v "$rev+$exact_rev" 2>/dev/null || true

log "labelled $count store paths in $(( $(date +%s) - start ))s"
