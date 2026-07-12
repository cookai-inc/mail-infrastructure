#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/backup-common.sh
source "$script_directory/lib/backup-common.sh"

usage() {
	printf 'Usage: %s [--snapshot <id|latest>] [--target <empty-directory>] [--apply --confirm-host <hostname>]\n' "$0" >&2
	exit 1
}

snapshot=latest
restore_target=
apply_restore=false
confirmed_hostname=
while [[ $# -gt 0 ]]; do
	case $1 in
	--snapshot)
		[[ $# -ge 2 ]] || usage
		snapshot=$2
		shift 2
		;;
	--target)
		[[ $# -ge 2 ]] || usage
		restore_target=$2
		shift 2
		;;
	--apply)
		apply_restore=true
		shift
		;;
	--confirm-host)
		[[ $# -ge 2 ]] || usage
		confirmed_hostname=$2
		shift 2
		;;
	*) usage ;;
	esac
done

require_root
require_commands docker restic rsync jq flock sha256sum tar find
load_backup_environment

install -d -m 0700 "$backup_work_directory" "$RESTIC_CACHE_DIR"
exec 9>"$backup_lock_file"
flock --nonblock 9 || fail 'Another CookAI mail backup or restore is already running.'

if [[ $apply_restore == true ]]; then
	[[ -z $restore_target ]] || fail '--target cannot be combined with --apply.'
	current_hostname=$(hostname --fqdn)
	[[ -n $confirmed_hostname && $confirmed_hostname == "$current_hostname" ]] || fail "Destructive restore requires --confirm-host $current_hostname"
	restore_target=$(mktemp --directory "$backup_work_directory/restore.XXXXXXXX")
	remove_restore_target=true
else
	[[ -n $restore_target ]] || fail 'A validation-only restore requires --target <empty-directory>.'
	[[ $restore_target == /* ]] || fail '--target must be an absolute path.'
	if [[ -e $restore_target ]]; then
		[[ ! -L $restore_target && -d $restore_target && -z $(find "$restore_target" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail '--target must be an empty real directory.'
		[[ $(stat --format=%u "$restore_target") -eq 0 ]] || fail '--target must be owned by root.'
		chmod 0700 "$restore_target"
	else
		install -d -m 0700 "$restore_target"
	fi
	remove_restore_target=false
fi

cleanup() {
	local result=$?
	trap - EXIT INT TERM
	if [[ $remove_restore_target == true ]]; then
		rm -rf -- "$restore_target"
	fi
	exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $snapshot == latest ]]; then
	snapshot=$(restic snapshots --json --tag cookai-mail,layout-v1 | jq --raw-output 'sort_by(.time) | last | .id // empty')
	[[ $snapshot =~ ^[0-9a-f]+$ ]] || fail 'No CookAI mail backup snapshots are available.'
fi

snapshot_metadata=$(restic cat snapshot "$snapshot")
jq --exit-status '
	(.tags | index("cookai-mail")) != null and
	(.tags | index("layout-v1")) != null
' <<<"$snapshot_metadata" >/dev/null || fail 'The selected snapshot is not a CookAI mail layout-v1 backup.'

restic restore "$snapshot" --target "$restore_target" --verify

mapfile -d '' restored_manifests < <(find "$restore_target" -type f -path '*/snapshot/manifest.json' -print0)
[[ ${#restored_manifests[@]} -eq 1 ]] || fail "Expected one restored manifest; found ${#restored_manifests[@]}."
manifest_path=${restored_manifests[0]}
restored_root=$(dirname "$manifest_path")

jq --exit-status '
	.schema == 1 and
	(.created_at | type == "string") and
	(.hostname | type == "string") and
	(.compose_project | type == "string") and
	(.compose_sha256 | test("^[0-9a-f]{64}$")) and
	(.deployment_sha256 | test("^[0-9a-f]{64}$")) and
	(.volumes | type == "array" and length > 0)
' "$manifest_path" >/dev/null || fail 'The restored manifest is invalid.'

manifest_project=$(jq --raw-output '.compose_project' "$manifest_path")
[[ $manifest_project == "$COMPOSE_PROJECT_NAME" ]] || fail "Snapshot project $manifest_project does not match $COMPOSE_PROJECT_NAME."

mapfile -t expected_volumes < <(list_compose_volumes)
mapfile -t restored_volumes < <(jq --raw-output '.volumes[]' "$manifest_path" | LC_ALL=C sort)
expected_volume_list=$(printf '%s\n' "${expected_volumes[@]}")
restored_volume_list=$(printf '%s\n' "${restored_volumes[@]}")
[[ $expected_volume_list == "$restored_volume_list" ]] || fail 'Snapshot volumes do not exactly match the current Compose definition.'

[[ -d $restored_root/etc/cookai-mail ]] || fail 'Snapshot does not contain /etc/cookai-mail.'
[[ -d $restored_root/opt/cookai-mail ]] || fail 'Snapshot does not contain the deployment files.'
for logical_volume in "${expected_volumes[@]}"; do
	[[ -d $restored_root/volumes/$logical_volume ]] || fail "Snapshot is missing volume: $logical_volume"
done

manifest_compose_sha256=$(jq --raw-output '.compose_sha256' "$manifest_path")
current_compose_sha256=$(sha256sum "$COMPOSE_DIRECTORY/$COMPOSE_FILE" | awk '{ print $1 }')
manifest_deployment_sha256=$(jq --raw-output '.deployment_sha256' "$manifest_path")
current_deployment_sha256=$(calculate_deployment_sha256 "$COMPOSE_DIRECTORY")
if [[ $manifest_compose_sha256 != "$current_compose_sha256" || $manifest_deployment_sha256 != "$current_deployment_sha256" ]]; then
	if [[ $apply_restore == true ]]; then
		fail 'Compose definition differs from the backup. Run a validation-only restore to a persistent target, install its deployment files, then rerun this command.'
	fi
	printf 'Warning: the current Compose definition differs from the validated backup.\n' >&2
fi

if [[ $apply_restore == false ]]; then
	printf 'Snapshot %s restored and verified at %s\n' "$snapshot" "$restored_root"
	exit 0
fi

mapfile -t project_containers < <(
	docker container ls \
		--all \
		--quiet \
		--filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME"
)
if [[ ${#project_containers[@]} -gt 0 ]]; then
	docker container stop --time "$STALWART_STOP_TIMEOUT_SECONDS" "${project_containers[@]}"
fi

install -d -m 0700 /etc/cookai-mail
rsync --archive --hard-links --acls --xattrs --sparse --numeric-ids --delete -- "$restored_root/etc/cookai-mail/" /etc/cookai-mail/
compose config --quiet
compose down --remove-orphans
compose create

for logical_volume in "${expected_volumes[@]}"; do
	volume_name=$(volume_name_for "$logical_volume")
	volume_mountpoint=$(volume_mountpoint_for "$volume_name")
	rsync \
		--archive \
		--hard-links \
		--acls \
		--xattrs \
		--sparse \
		--numeric-ids \
		--delete \
		-- "$restored_root/volumes/$logical_volume/" "$volume_mountpoint/"
done

compose up --detach
compose ps
printf 'CookAI mail snapshot %s restored successfully.\n' "$snapshot"
