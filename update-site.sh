#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Public GitHub repository containing site.zip in the main branch.
repository='FastCon-telegram/nginx-site'
branch='main'
target='/var/www/html'
backup_root='/var/backups/nginx-site'

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run: sudo update-site'
for dependency in curl python3 rsync flock readlink; do
  command -v "$dependency" >/dev/null || die "Missing dependency: $dependency"
done
[[ $# -le 2 ]] || die 'Usage: update-site [--rollback [BACKUP_DIRECTORY]]'
mode=${1:-update}
[[ "$mode" == update || "$mode" == --rollback ]] || die 'Usage: update-site [--rollback [BACKUP_DIRECTORY]]'
[[ "$mode" == --rollback || $# -le 1 ]] || die 'Unexpected argument.'

exec 9>/run/lock/update-nginx-site.lock
flock -n 9 || die 'Another site update is already running.'
[[ ! -L "$target" ]] || die '/var/www/html must be a directory, not a symbolic link.'
install -d -m 755 -- "$target"
[[ $(readlink -f -- "$target") == "$target" ]] || die 'Unexpected resolved web-root path.'
install -d -m 700 -- "$backup_root"
[[ $(readlink -f -- "$backup_root") == "$backup_root" ]] || die 'Unexpected resolved backup path.'

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT

save_backup() {
  backup=$(mktemp -d "$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
  mkdir -- "$backup/files"
  rsync -a --exclude='/.well-known/' "$target/" "$backup/files/"
  : > "$backup/complete"
  ln -sfn -- "$backup" "$backup_root/latest"
  printf 'Backup: %s\n' "$backup"
}

sync_site() {
  # Preserve the directory inode used by the running Docker bind mount.
  # Excluded ACME files are neither overwritten nor removed.
  if [[ "$mode" == --rollback ]]; then
    rsync -a --checksum --delay-updates --delete-delay \
      --exclude='/.well-known/' "$1/" "$target/"
  else
    rsync -rltp --checksum --delay-updates --delete-delay \
      --exclude='/.well-known/' --chmod=D755,F644 "$1/" "$target/"
  fi
}

if [[ "$mode" == --rollback ]]; then
  restore=$(readlink -f -- "${2:-$backup_root/latest}") || die 'Backup not found.'
  [[ ${restore%/*} == "$backup_root" && -f "$restore/complete" && -d "$restore/files" ]] || die 'Choose a completed backup inside /var/backups/nginx-site.'
  # Resolve the previous backup before updating the latest link.
  source="$restore/files"
  printf 'Restoring: %s\n' "$restore"
else
  curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 15 --max-time 300 --proto '=https' --tlsv1.2 \
    --output "$stage/site.zip" \
    "https://raw.githubusercontent.com/$repository/$branch/site.zip?download=$(date +%s)"

  # Extract regular files only, and locate the shallowest index.html.
  # Both index.html at archive root and site/site/index.html are accepted.
  python3 - "$stage/site.zip" "$stage/unpacked" "$stage/root.txt" <<'PYTHON_EXTRACT'
import pathlib
import shutil
import stat
import sys
import zipfile

archive, output, root_file = map(pathlib.Path, sys.argv[1:])
output.mkdir()
with zipfile.ZipFile(archive) as z:
    entries = z.infolist()
    if len(entries) > 10000 or sum(item.file_size for item in entries) > 100 * 1024 * 1024:
        raise SystemExit('Archive is too large (maximum: 10000 entries / 100 MiB unpacked).')
    seen = set()
    for item in entries:
        name = item.filename.replace('\\', '/')
        path = pathlib.PurePosixPath(name)
        if not name or name.startswith('/') or any(part in ('', '.', '..') for part in name.rstrip('/').split('/')) or ':' in name:
            raise SystemExit('Unsafe archive path.')
        if any(ord(char) < 32 for char in name):
            raise SystemExit('Invalid control character in archive path.')
        if path in seen:
            raise SystemExit('Duplicate archive path.')
        seen.add(path)
        kind = stat.S_IFMT(item.external_attr >> 16)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise SystemExit('Archive links and special files are not supported.')
        if any(part.startswith('.') for part in path.parts) or '__MACOSX' in path.parts:
            continue
        destination = output.joinpath(*path.parts)
        if item.is_dir():
            destination.mkdir(parents=True, exist_ok=True)
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            with z.open(item) as reader, destination.open('xb') as writer:
                shutil.copyfileobj(reader, writer)

indexes = [p for p in output.rglob('index.html') if p.is_file() and p.stat().st_size]
if not indexes:
    raise SystemExit('The archive has no nonempty index.html; the existing site was not replaced.')
depth = min(len(p.relative_to(output).parts) for p in indexes)
roots = [p.parent for p in indexes if len(p.relative_to(output).parts) == depth]
if len(roots) != 1:
    raise SystemExit('Several site roots found. Put the intended index.html at the archive root.')
root_file.write_text(str(roots[0]), encoding='utf-8')
print('Site archive validated.')
PYTHON_EXTRACT
  source=$(cat -- "$stage/root.txt")
fi

save_backup
if ! sync_site "$source"; then
  printf 'Update failed; restoring the previous contents from %s\n' "$backup" >&2
  if ! rsync -a --checksum --delay-updates --delete-delay --exclude='/.well-known/' "$backup/files/" "$target/"; then
    printf 'Automatic restore also failed. Backup remains at %s\n' "$backup" >&2
  fi
  exit 1
fi
printf 'Site files installed in %s. Open https://avito.business/ and refresh the browser.\n' "$target"
printf 'Previous version: %s\n' "$backup"
printf 'Rollback command: sudo update-site --rollback\n'
