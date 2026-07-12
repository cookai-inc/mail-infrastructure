#!/usr/bin/env bash
set -euo pipefail

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/backup-common.sh
source "$script_directory/lib/backup-common.sh"

require_root
require_commands docker restic rsync jq flock sha256sum tar du df sync find
load_backup_environment

provider_tiles_directory=/srv/provider-dashboard/tiles
find "$provider_tiles_directory" -maxdepth 1 -type f -name '*.pmtiles' -print -quit | grep --quiet . || fail 'No complete provider PMTiles archive is available for backup.'

install -d -m 0700 "$backup_work_directory" "$RESTIC_CACHE_DIR"
exec 9>"$backup_lock_file"
flock --nonblock 9 || fail 'Another CookAI mail backup or restore is already running.'

restic snapshots --json --latest 1 >/dev/null

mapfile -t logical_volumes < <(list_compose_volumes)
[[ ${#logical_volumes[@]} -gt 0 ]] || fail 'The Compose project does not define any named volumes.'

declare -A volume_mountpoints
for logical_volume in "${logical_volumes[@]}"; do
	volume_name=$(volume_name_for "$logical_volume")
	volume_mountpoints["$logical_volume"]=$(volume_mountpoint_for "$volume_name")
done

compose config --services | grep --fixed-strings --line-regexp stalwart >/dev/null || fail 'The Compose project does not define the Stalwart service.'
mapfile -t stalwart_volumes < <(
	compose config --format json | jq --raw-output '.services.stalwart.volumes[] | select(.type == "volume") | .source' | LC_ALL=C sort
)
[[ ${#stalwart_volumes[@]} -gt 0 ]] || fail 'The Stalwart service does not use a named volume.'
declare -A stalwart_volume_set
for stalwart_volume in "${stalwart_volumes[@]}"; do
	[[ -v volume_mountpoints["$stalwart_volume"] ]] || fail "Stalwart references an unknown named volume: $stalwart_volume"
	stalwart_volume_set["$stalwart_volume"]=true
done

rm -rf -- "$backup_snapshot_directory"
source_allocated_bytes=$(du --summarize --block-size=1 /etc/cookai-mail "$COMPOSE_DIRECTORY" "$provider_tiles_directory" "${volume_mountpoints[@]}" | awk '{ total += $1 } END { print total + 0 }')
available_bytes=$(df --output=avail --block-size=1 "$backup_work_directory" | tail --lines=1 | tr --delete ' ')
minimum_headroom_bytes=$((512 * 1024 * 1024))
percentage_headroom_bytes=$((source_allocated_bytes / 10))
if ((percentage_headroom_bytes > minimum_headroom_bytes)); then
	minimum_headroom_bytes=$percentage_headroom_bytes
fi
required_bytes=$((source_allocated_bytes + minimum_headroom_bytes))
((available_bytes >= required_bytes)) || fail "Insufficient space for a consistent local snapshot: need $required_bytes bytes, have $available_bytes bytes."

install -d -m 0700 \
	"$backup_snapshot_directory/etc/cookai-mail" \
	"$backup_snapshot_directory/opt/cookai-mail" \
	"$backup_snapshot_directory/srv/provider-dashboard/tiles" \
	"$backup_snapshot_directory/volumes"

stalwart_restart_required=false
backup_summary_file=$backup_work_directory/backup-summary.jsonl
cleanup() {
	local result=$?
	trap - EXIT INT TERM
	if [[ $stalwart_restart_required == true ]]; then
		if ! compose start stalwart; then
			printf 'Failed to restart Stalwart during backup cleanup.\n' >&2
			result=1
		fi
	fi
	rm -rf -- "$backup_snapshot_directory"
	rm -f -- "$backup_summary_file"
	exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sync_tree() {
	local source_directory=$1
	local destination_directory=$2
	local copy_mode=$3
	local attempt=1
	local rsync_result
	shift 3

	install -d -m 0700 "$destination_directory"
	while true; do
		set +e
		rsync \
			--archive \
			--hard-links \
			--acls \
			--xattrs \
			--sparse \
			--numeric-ids \
			--delete \
			"$@" \
			-- "$source_directory/" "$destination_directory/"
		rsync_result=$?
		set -e
		[[ $rsync_result -eq 0 ]] && return 0
		[[ $rsync_result -eq 24 && $copy_mode != strict ]] || return "$rsync_result"
		if [[ $copy_mode == warm ]]; then
			printf 'Source files changed during warm copy of %s; the final reconciliation remains authoritative.\n' "$source_directory" >&2
			return 0
		fi
		((attempt < 3)) || return "$rsync_result"
		printf 'Source files changed while copying %s; retrying final live-volume reconciliation.\n' "$source_directory" >&2
		((attempt += 1))
		sleep 1
	done
}

sync_all_sources() {
	local warm_copy=$1
	local copy_mode=strict
	local logical_volume

	if [[ $warm_copy == true ]]; then
		copy_mode=warm
	fi
	sync_tree /etc/cookai-mail "$backup_snapshot_directory/etc/cookai-mail" "$copy_mode"
	sync_tree "$COMPOSE_DIRECTORY" "$backup_snapshot_directory/opt/cookai-mail" "$copy_mode" --exclude=/.git/
	sync_tree "$provider_tiles_directory" "$backup_snapshot_directory/srv/provider-dashboard/tiles" "$copy_mode" --exclude='*.partial' --exclude='.*.chunks/'
	for logical_volume in "${logical_volumes[@]}"; do
		copy_mode=strict
		if [[ $warm_copy == true ]]; then
			copy_mode=warm
		fi
		if [[ $warm_copy == false && ! -v stalwart_volume_set["$logical_volume"] ]]; then
			copy_mode=live
		fi
		sync_tree "${volume_mountpoints[$logical_volume]}" "$backup_snapshot_directory/volumes/$logical_volume" "$copy_mode"
	done
}

sync_all_sources true

stalwart_was_running=false
if compose ps --status running --services | grep --fixed-strings --line-regexp stalwart >/dev/null; then
	stalwart_was_running=true
	stalwart_restart_required=true
	compose stop --timeout "$STALWART_STOP_TIMEOUT_SECONDS" stalwart
fi

sync_all_sources false

created_at=$(date --utc +%Y-%m-%dT%H:%M:%SZ)
backup_hostname=$(hostname --fqdn)
compose_sha256=$(sha256sum "$backup_snapshot_directory/opt/cookai-mail/$COMPOSE_FILE" | awk '{ print $1 }')
deployment_sha256=$(calculate_deployment_sha256 "$backup_snapshot_directory/opt/cookai-mail")
printf '%s\n' "${logical_volumes[@]}" | jq \
	--raw-input \
	--slurp \
	--arg created_at "$created_at" \
	--arg hostname "$backup_hostname" \
	--arg compose_project "$COMPOSE_PROJECT_NAME" \
	--arg compose_sha256 "$compose_sha256" \
	--arg deployment_sha256 "$deployment_sha256" \
	--argjson stalwart_was_running "$stalwart_was_running" \
	--argjson provider_tiles true \
	'{
		schema: 1,
		created_at: $created_at,
		hostname: $hostname,
		compose_project: $compose_project,
		compose_sha256: $compose_sha256,
		deployment_sha256: $deployment_sha256,
		stalwart_was_running: $stalwart_was_running,
		provider_tiles: $provider_tiles,
		volumes: (split("\n") | map(select(length > 0)))
	}' >"$backup_snapshot_directory/manifest.json"

sync --file-system "$backup_snapshot_directory"

if [[ $stalwart_restart_required == true ]]; then
	compose start stalwart

	stalwart_container_id=$(compose ps --quiet stalwart)
	[[ -n $stalwart_container_id ]] || fail 'Stalwart did not create a container after the backup snapshot.'
	start_deadline=$((SECONDS + STALWART_START_TIMEOUT_SECONDS))
	while ((SECONDS < start_deadline)); do
		stalwart_status=$(docker inspect --format '{{ if .State.Health }}{{ .State.Health.Status }}{{ else if .State.Running }}running{{ else }}stopped{{ end }}' "$stalwart_container_id")
		if [[ $stalwart_status == healthy || $stalwart_status == running ]]; then
			break
		fi
		sleep 2
	done
	[[ $stalwart_status == healthy || $stalwart_status == running ]] || fail "Stalwart failed to become healthy after backup; current status: $stalwart_status"
	stalwart_restart_required=false
fi

restic backup \
	--host "$backup_hostname" \
	--tag cookai-mail \
	--tag layout-v1 \
	--json \
	"$backup_snapshot_directory" >"$backup_summary_file"
snapshot_id=$(jq --raw-output 'select(.message_type == "summary") | .snapshot_id' "$backup_summary_file" | tail --lines=1)
[[ $snapshot_id =~ ^[0-9a-f]+$ ]] || fail 'Restic did not report a valid snapshot ID.'

restic forget \
	--host "$backup_hostname" \
	--tag cookai-mail,layout-v1 \
	--keep-daily "$RESTIC_KEEP_DAILY" \
	--keep-weekly "$RESTIC_KEEP_WEEKLY" \
	--keep-monthly "$RESTIC_KEEP_MONTHLY" \
	--prune

subset_index=$((10#$(date --utc +%j) % RESTIC_CHECK_SUBSET_DIVISOR + 1))
restic check --read-data-subset "$subset_index/$RESTIC_CHECK_SUBSET_DIVISOR"

rm -f -- "$backup_summary_file"
printf 'CookAI mail backup completed: %s\n' "$snapshot_id"
