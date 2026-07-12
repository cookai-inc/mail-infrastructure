#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	printf 'Run this script as root.\n' >&2
	exit 1
fi

if [[ $# -lt 2 ]]; then
	printf 'Usage: %s <prepare|lockdown> <admin-username> [additional-allowed-user ...]\n' "$0" >&2
	exit 1
fi

mode=$1
admin_username=$2
shift 2
additional_allowed_users=("$@")
for username in "$admin_username" "${additional_allowed_users[@]}"; do
	if [[ ! $username =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
		printf 'Invalid username: %s\n' "$username" >&2
		exit 1
	fi
done

prepare_admin() {
	if ((${#additional_allowed_users[@]} > 0)); then
		printf 'Additional allowed users apply only to lockdown mode.\n' >&2
		exit 1
	fi
	IFS= read -r public_key
	if [[ ! $public_key =~ ^ssh-(ed25519|rsa)[[:space:]] ]]; then
		printf 'A valid SSH public key is required on standard input.\n' >&2
		exit 1
	fi

	if ! id "$admin_username" >/dev/null 2>&1; then
		useradd --create-home --shell /bin/bash "$admin_username"
	fi
	getent group docker >/dev/null
	usermod --append --groups sudo,docker "$admin_username"

	admin_home=$(getent passwd "$admin_username" | cut -d: -f6)
	admin_group=$(id --group --name "$admin_username")
	install -d -m 0700 -o "$admin_username" -g "$admin_group" "$admin_home/.ssh"
	temporary_key=$(mktemp)
	trap 'rm -f "$temporary_key"' RETURN
	printf '%s\n' "$public_key" >"$temporary_key"
	ssh-keygen -l -f "$temporary_key" >/dev/null
	install -m 0600 -o "$admin_username" -g "$admin_group" "$temporary_key" "$admin_home/.ssh/authorized_keys"

	temporary_sudoers=$(mktemp)
	trap 'rm -f "$temporary_key" "$temporary_sudoers"' RETURN
	printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$admin_username" >"$temporary_sudoers"
	visudo --check --file "$temporary_sudoers" >/dev/null
	install -m 0440 "$temporary_sudoers" "/etc/sudoers.d/90-$admin_username"
}

lock_down_sshd() {
	id "$admin_username" >/dev/null
	for username in "${additional_allowed_users[@]}"; do
		id "$username" >/dev/null
	done
	admin_home=$(getent passwd "$admin_username" | cut -d: -f6)
	test -s "$admin_home/.ssh/authorized_keys"

	temporary_config=$(mktemp)
	trap 'rm -f "$temporary_config"' RETURN
	cat >"$temporary_config" <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PubkeyAuthentication yes
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $admin_username ${additional_allowed_users[*]}
EOF
	install -m 0644 "$temporary_config" /etc/ssh/sshd_config.d/00-cookai-hardening.conf
	sshd -t
	systemctl reload ssh
	sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|authenticationmethods|allowusers|allowtcpforwarding) '
}

case $mode in
prepare)
	prepare_admin
	;;
lockdown)
	lock_down_sshd
	;;
*)
	printf 'Unknown mode: %s\n' "$mode" >&2
	exit 1
	;;
esac
