#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	printf 'Run this script as root.\n' >&2
	exit 1
fi

if [[ $# -ne 1 ]]; then
	printf 'Usage: %s <fully-qualified-hostname>\n' "$0" >&2
	exit 1
fi

hostname_fqdn=$1
if [[ ! $hostname_fqdn =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
	printf 'Invalid fully-qualified hostname: %s\n' "$hostname_fqdn" >&2
	exit 1
fi

source /etc/os-release
: "${ID:?Missing operating system ID}"
: "${VERSION_ID:?Missing operating system version}"
: "${VERSION_CODENAME:?Missing Ubuntu codename}"

if [[ $ID != ubuntu || $VERSION_ID != 24.04 ]]; then
	printf 'Ubuntu 24.04 is required; found %s %s.\n' "$ID" "$VERSION_ID" >&2
	exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

temporary_directory=$(mktemp -d)
swap_candidate=
cleanup() {
	rm -rf "$temporary_directory"
	[[ -z $swap_candidate ]] || rm -f "$swap_candidate"
}
trap cleanup EXIT

hostname_short=${hostname_fqdn%%.*}
hostnamectl set-hostname "$hostname_fqdn"
awk -v fqdn="$hostname_fqdn" -v short="$hostname_short" '
  BEGIN { written = 0 }
  $1 == "127.0.1.1" {
    if (!written) {
      print "127.0.1.1\t" fqdn " " short
      written = 1
    }
    next
  }
  { print }
  END {
    if (!written) {
      print "127.0.1.1\t" fqdn " " short
    }
  }
' /etc/hosts >"$temporary_directory/hosts"
if ! cmp -s "$temporary_directory/hosts" /etc/hosts; then
	install -m 0644 "$temporary_directory/hosts" /etc/hosts
fi

apt-get update
apt-get install -y ca-certificates curl dnsutils jq openssl ufw unattended-upgrades

install -d -m 0755 /etc/apt/keyrings
curl --fail --silent --show-error --location \
	https://download.docker.com/linux/ubuntu/gpg \
	--output "$temporary_directory/docker.asc"
if ! cmp -s "$temporary_directory/docker.asc" /etc/apt/keyrings/docker.asc; then
	install -m 0644 "$temporary_directory/docker.asc" /etc/apt/keyrings/docker.asc
fi

architecture=$(dpkg --print-architecture)
cat >"$temporary_directory/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $VERSION_CODENAME
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
if ! cmp -s "$temporary_directory/docker.sources" /etc/apt/sources.list.d/docker.sources; then
	install -m 0644 "$temporary_directory/docker.sources" /etc/apt/sources.list.d/docker.sources
fi

apt-get update
apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

install -d -m 0755 /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
	jq '
    if type != "object" then error("Docker daemon configuration must be an object") else . end
    | .["log-driver"] = "json-file"
    | .["log-opts"] = ((.["log-opts"] // {}) + {"max-size": "10m", "max-file": "3"})
    | .["live-restore"] = true
  ' /etc/docker/daemon.json >"$temporary_directory/daemon.json"
else
	jq --null-input '{
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"},
    "live-restore": true
  }' >"$temporary_directory/daemon.json"
fi

docker_restart_required=false
if ! cmp -s "$temporary_directory/daemon.json" /etc/docker/daemon.json; then
	install -m 0644 "$temporary_directory/daemon.json" /etc/docker/daemon.json
	docker_restart_required=true
fi
systemctl enable --now docker
if [[ $docker_restart_required == true ]]; then
	systemctl restart docker
fi

cat >"$temporary_directory/20auto-upgrades" <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
if ! cmp -s "$temporary_directory/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades; then
	install -m 0644 "$temporary_directory/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
fi
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service

if ! swapon --noheadings --show=NAME | grep --quiet .; then
	if [[ -e /swapfile ]]; then
		if [[ $(blkid -p -s TYPE -o value /swapfile || true) != swap ]]; then
			printf '/swapfile exists but is not a swap file.\n' >&2
			exit 1
		fi
	else
		swap_candidate=$(mktemp /swapfile.bootstrap.XXXXXX)
		fallocate --length 2G "$swap_candidate"
		chmod 0600 "$swap_candidate"
		mkswap "$swap_candidate"
		mv "$swap_candidate" /swapfile
		swap_candidate=
	fi
	if ! awk '$1 == "/swapfile" && $3 == "swap" { found = 1 } END { exit !found }' /etc/fstab; then
		printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
	fi
	swapon /swapfile
fi

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw limit 22/tcp comment 'SSH rate limit'
for public_port in 25 80 443 465 587 993; do
	ufw allow "$public_port/tcp"
done
ufw logging low
ufw --force enable

docker info >/dev/null
docker compose version
ufw status verbose
swapon --show
