#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_directory=$(realpath "$script_directory/..")
# shellcheck source=scripts/lib/backup-common.sh
source "$script_directory/lib/backup-common.sh"

initialize_repository=false
if [[ $# -gt 1 ]]; then
	fail "Usage: $0 [--initialize]"
fi
if [[ $# -eq 1 ]]; then
	[[ $1 == --initialize ]] || fail "Usage: $0 [--initialize]"
	initialize_repository=true
fi

require_root
[[ $repository_directory == /opt/cookai-mail ]] || fail 'Install the deployment at /opt/cookai-mail before enabling backups.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y jq restic rsync

require_commands docker restic rsync jq flock
load_backup_environment
install -d -m 0700 "$backup_work_directory" "$RESTIC_CACHE_DIR"

if ! restic cat config >/dev/null 2>&1; then
	[[ $initialize_repository == true ]] || fail 'Restic repository is unavailable or uninitialized. Verify its credentials or rerun with --initialize for a new empty repository.'
	restic init
fi

install -m 0644 "$repository_directory/systemd/cookai-mail-backup.service" /etc/systemd/system/cookai-mail-backup.service
install -m 0644 "$repository_directory/systemd/cookai-mail-backup.timer" /etc/systemd/system/cookai-mail-backup.timer
systemctl daemon-reload
systemctl enable --now cookai-mail-backup.timer
systemctl list-timers cookai-mail-backup.timer
