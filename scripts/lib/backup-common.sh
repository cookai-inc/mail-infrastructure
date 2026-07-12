#!/usr/bin/env bash

backup_environment_file=${COOKAI_MAIL_BACKUP_ENV:-/etc/cookai-mail/backup.env}
backup_work_directory=/var/cache/cookai-mail-backup
backup_snapshot_directory=$backup_work_directory/snapshot
backup_lock_file=$backup_work_directory/backup.lock

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

require_root() {
	[[ $EUID -eq 0 ]] || fail 'Run this script as root.'
}

require_commands() {
	local command_name
	for command_name in "$@"; do
		command -v "$command_name" >/dev/null || fail "Required command is missing: $command_name"
	done
}

validate_private_file() {
	local file_path=$1
	local description=$2
	local permissions

	[[ -f $file_path ]] || fail "$description does not exist: $file_path"
	[[ $(stat --format=%u "$file_path") -eq 0 ]] || fail "$description must be owned by root: $file_path"
	permissions=$(stat --format=%a "$file_path")
	(((8#$permissions & 077) == 0)) || fail "$description must not be accessible by group or other users: $file_path"
}

load_backup_environment() {
	validate_private_file "$backup_environment_file" 'Backup environment file'

	set -a
	# shellcheck source=/dev/null
	source "$backup_environment_file"
	set +a

	: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required in $backup_environment_file}"
	: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is required in $backup_environment_file}"

	case $RESTIC_REPOSITORY in
	s3:https://* | sftp:* | b2:* | azure:* | gs:* | rest:https://*) ;;
	*) fail 'RESTIC_REPOSITORY must use a supported off-host encrypted transport.' ;;
	esac

	[[ $RESTIC_PASSWORD_FILE == /* ]] || fail 'RESTIC_PASSWORD_FILE must be an absolute path.'
	validate_private_file "$RESTIC_PASSWORD_FILE" 'Restic password file'

	COMPOSE_DIRECTORY=${COMPOSE_DIRECTORY:-/opt/cookai-mail}
	COMPOSE_FILE=${COMPOSE_FILE:-compose.yaml}
	COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-cookai-mail}
	RESTIC_CACHE_DIR=$backup_work_directory/restic-cache
	RESTIC_KEEP_DAILY=${RESTIC_KEEP_DAILY:-7}
	RESTIC_KEEP_WEEKLY=${RESTIC_KEEP_WEEKLY:-5}
	RESTIC_KEEP_MONTHLY=${RESTIC_KEEP_MONTHLY:-12}
	RESTIC_CHECK_SUBSET_DIVISOR=${RESTIC_CHECK_SUBSET_DIVISOR:-30}
	STALWART_STOP_TIMEOUT_SECONDS=${STALWART_STOP_TIMEOUT_SECONDS:-120}
	STALWART_START_TIMEOUT_SECONDS=${STALWART_START_TIMEOUT_SECONDS:-180}

	[[ $COMPOSE_DIRECTORY == /* ]] || fail 'COMPOSE_DIRECTORY must be an absolute path.'
	[[ -f $COMPOSE_DIRECTORY/$COMPOSE_FILE ]] || fail "Compose file does not exist: $COMPOSE_DIRECTORY/$COMPOSE_FILE"

	local numeric_value
	for numeric_value in \
		"$RESTIC_KEEP_DAILY" \
		"$RESTIC_KEEP_WEEKLY" \
		"$RESTIC_KEEP_MONTHLY" \
		"$RESTIC_CHECK_SUBSET_DIVISOR" \
		"$STALWART_STOP_TIMEOUT_SECONDS" \
		"$STALWART_START_TIMEOUT_SECONDS"; do
		[[ $numeric_value =~ ^[1-9][0-9]*$ ]] || fail 'Backup retention and timeout values must be positive integers.'
	done

	export COMPOSE_PROJECT_NAME RESTIC_CACHE_DIR
}

compose() {
	(
		cd "$COMPOSE_DIRECTORY" || exit 1
		docker compose --file "$COMPOSE_FILE" "$@"
	)
}

list_compose_volumes() {
	compose config --volumes | LC_ALL=C sort
}

volume_name_for() {
	local logical_name=$1
	local -a matching_volumes

	mapfile -t matching_volumes < <(
		docker volume ls \
			--quiet \
			--filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
			--filter "label=com.docker.compose.volume=$logical_name"
	)
	[[ ${#matching_volumes[@]} -eq 1 ]] || fail "Expected exactly one Docker volume for $logical_name; found ${#matching_volumes[@]}."
	printf '%s\n' "${matching_volumes[0]}"
}

volume_mountpoint_for() {
	local volume_name=$1
	local mountpoint

	mountpoint=$(docker volume inspect --format '{{ .Mountpoint }}' "$volume_name")
	[[ $mountpoint == /* && -d $mountpoint ]] || fail "Docker volume has an invalid mountpoint: $volume_name"
	printf '%s\n' "$mountpoint"
}

calculate_deployment_sha256() {
	local deployment_directory=$1

	tar \
		--create \
		--file=- \
		--directory="$deployment_directory" \
		--sort=name \
		--mtime='UTC 1970-01-01' \
		--owner=0 \
		--group=0 \
		--numeric-owner \
		--exclude=.git \
		. | sha256sum | awk '{ print $1 }'
}
