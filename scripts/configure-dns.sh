#!/usr/bin/env bash
set -euo pipefail
set +x

usage() {
	cat <<'EOF'
Usage: configure-dns.sh <pre-mx|post-mx>

Required environment:
  CLOUDFLARE_API_TOKEN
  CLOUDFLARE_ZONE_ID
  MAIL_IPV4
  DKIM_ED25519_RECORD
  DKIM_RSA_RECORD
  MTA_STS_ID

Optional environment:
  DOMAIN                    DNS zone name (default: cookai-inc.com)
  DNS_TTL                   Managed record TTL (default: 300)
  DKIM_ED25519_SELECTOR     Default: v1-ed25519-20260712
  DKIM_RSA_SELECTOR         Default: v1-rsa-20260712
  SPF_RECORD                Default: v=spf1 ip4:<MAIL_IPV4> -all
  DMARC_RECORD              Optional authoritative DMARC TXT value
  TLS_RPT_RECORD            Default: v=TLSRPTv1; rua=mailto:postmaster@<DOMAIN>
  MX_PRIORITY               Default: 10
EOF
}

if [[ $# -ne 1 ]]; then
	usage >&2
	exit 2
fi

mode=$1
case $mode in
pre-mx | post-mx) ;;
-h | --help)
	usage
	exit 0
	;;
*)
	usage >&2
	exit 2
	;;
esac

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ZONE_ID:?CLOUDFLARE_ZONE_ID is required}"
: "${MAIL_IPV4:?MAIL_IPV4 is required}"
: "${DKIM_ED25519_RECORD:?DKIM_ED25519_RECORD is required}"
: "${DKIM_RSA_RECORD:?DKIM_RSA_RECORD is required}"
: "${MTA_STS_ID:?MTA_STS_ID is required}"

domain=${DOMAIN:-cookai-inc.com}
dns_ttl=${DNS_TTL:-300}
dkim_ed25519_selector=${DKIM_ED25519_SELECTOR:-v1-ed25519-20260712}
dkim_rsa_selector=${DKIM_RSA_SELECTOR:-v1-rsa-20260712}
spf_record=${SPF_RECORD:-v=spf1 ip4:$MAIL_IPV4 -all}
dmarc_record=${DMARC_RECORD:-}
tls_rpt_record=${TLS_RPT_RECORD:-v=TLSRPTv1; rua=mailto:postmaster@$domain}
mx_priority=${MX_PRIORITY:-10}
mail_host=mail.$domain
cloudflare_api=https://api.cloudflare.com/client/v4

fail() {
	printf '%s\n' "$1" >&2
	exit 1
}

validate_ipv4() {
	local address=$1
	local first_octet second_octet third_octet fourth_octet extra octet

	IFS=. read -r first_octet second_octet third_octet fourth_octet extra <<<"$address"
	[[ -z ${extra:-} && -n ${fourth_octet:-} ]] || return 1
	for octet in "$first_octet" "$second_octet" "$third_octet" "$fourth_octet"; do
		[[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
		((10#$octet <= 255)) || return 1
	done
}

validate_selector() {
	[[ $1 =~ ^[a-z0-9]([a-z0-9_-]{0,61}[a-z0-9])?$ ]]
}

[[ $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] ||
	fail "Invalid DOMAIN: $domain"
[[ $CLOUDFLARE_ZONE_ID =~ ^[a-f0-9]{32}$ ]] || fail 'CLOUDFLARE_ZONE_ID must be a 32-character hexadecimal identifier.'
[[ $CLOUDFLARE_API_TOKEN =~ ^[A-Za-z0-9_-]{20,}$ ]] || fail 'CLOUDFLARE_API_TOKEN has an invalid format.'
validate_ipv4 "$MAIL_IPV4" || fail "Invalid MAIL_IPV4: $MAIL_IPV4"
[[ $dns_ttl == 1 || $dns_ttl =~ ^[1-9][0-9]*$ && $dns_ttl -ge 60 && $dns_ttl -le 86400 ]] ||
	fail 'DNS_TTL must be 1 or an integer from 60 through 86400.'
[[ $mx_priority =~ ^(0|[1-9][0-9]*)$ && $mx_priority -le 65535 ]] ||
	fail 'MX_PRIORITY must be an integer from 0 through 65535.'
validate_selector "$dkim_ed25519_selector" || fail "Invalid DKIM_ED25519_SELECTOR: $dkim_ed25519_selector"
validate_selector "$dkim_rsa_selector" || fail "Invalid DKIM_RSA_SELECTOR: $dkim_rsa_selector"
[[ $dkim_ed25519_selector != "$dkim_rsa_selector" ]] || fail 'DKIM selectors must be distinct.'
[[ ${DKIM_ED25519_RECORD,,} == v=dkim1\;* && ${DKIM_ED25519_RECORD,,} == *k=ed25519* && ${DKIM_ED25519_RECORD,,} == *p=* ]] ||
	fail 'DKIM_ED25519_RECORD must be a complete ed25519 DKIM TXT value.'
[[ ${DKIM_RSA_RECORD,,} == v=dkim1\;* && ${DKIM_RSA_RECORD,,} == *k=rsa* && ${DKIM_RSA_RECORD,,} == *p=* ]] ||
	fail 'DKIM_RSA_RECORD must be a complete RSA DKIM TXT value.'
[[ ${spf_record,,} == v=spf1 || ${spf_record,,} == v=spf1\ * ]] ||
	fail 'SPF_RECORD must be a complete SPF TXT value.'
if [[ -n $dmarc_record && ${dmarc_record,,} != v=dmarc1\;* ]]; then
	fail 'DMARC_RECORD must be a complete DMARC TXT value.'
fi
[[ $MTA_STS_ID =~ ^[A-Za-z0-9._-]{1,32}$ ]] || fail 'MTA_STS_ID must contain 1 through 32 letters, digits, dots, underscores, or hyphens.'
[[ ${tls_rpt_record,,} == v=tlsrptv1\;* ]] || fail 'TLS_RPT_RECORD must be a complete TLS reporting TXT value.'

for required_command in curl jq mktemp; do
	command -v "$required_command" >/dev/null || fail "Required command is unavailable: $required_command"
done

temporary_directory=$(mktemp -d)
chmod 700 "$temporary_directory"
cleanup() {
	rm -rf "$temporary_directory"
}
trap cleanup EXIT

curl_config=$temporary_directory/curl.conf
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$CLOUDFLARE_API_TOKEN" >"$curl_config"
chmod 600 "$curl_config"

request_number=0
cloudflare_request() {
	local method=$1
	local path=$2
	local payload=${3:-}
	local response_file request_file http_status
	local -a curl_arguments

	((request_number += 1))
	response_file=$temporary_directory/response-$request_number.json
	curl_arguments=(
		--config "$curl_config"
		--silent
		--show-error
		--proto '=https'
		--tlsv1.2
		--request "$method"
		--url "$cloudflare_api$path"
		--output "$response_file"
		--write-out '%{http_code}'
	)
	if [[ -n $payload ]]; then
		request_file=$temporary_directory/request-$request_number.json
		printf '%s' "$payload" >"$request_file"
		curl_arguments+=(--data-binary "@$request_file")
	fi

	if ! http_status=$(curl "${curl_arguments[@]}"); then
		fail "Cloudflare API request failed: $method $path"
	fi
	if ! jq --exit-status '.success == true' "$response_file" >/dev/null; then
		printf 'Cloudflare API request failed: %s %s (HTTP %s)\n' "$method" "$path" "$http_status" >&2
		jq --raw-output '.errors[]? | "  \(.code): \(.message)"' "$response_file" >&2
		exit 1
	fi
	cat "$response_file"
}

list_records() {
	local record_type=$1
	local record_name=$2
	local page=1 total_pages=1 response
	local records='[]'

	while ((page <= total_pages)); do
		response=$(cloudflare_request GET "/zones/$CLOUDFLARE_ZONE_ID/dns_records?type=$record_type&name=$record_name&per_page=100&page=$page")
		records=$(jq --compact-output \
			--arg record_type "$record_type" \
			--arg record_name "$record_name" \
			--argjson records "$records" \
			'$records + [.result[] | select(.type == $record_type and .name == $record_name)]' <<<"$response")
		total_pages=$(jq --raw-output '.result_info.total_pages // 1' <<<"$response")
		((page += 1))
	done
	printf '%s\n' "$records"
}

record_matches_payload() {
	local record=$1
	local payload=$2

	jq --exit-status --argjson desired "$payload" '
    .type == $desired.type
    and .name == $desired.name
    and (
      if $desired.type == "MX"
      then (.content | ascii_downcase | rtrimstr(".")) == ($desired.content | ascii_downcase | rtrimstr("."))
      else .content == $desired.content
      end
    )
    and .ttl == $desired.ttl
    and (if $desired.type == "A" then .proxied == false else true end)
    and (if $desired.type == "MX" then .priority == $desired.priority else true end)
  ' <<<"$record" >/dev/null
}

reconcile_singleton() {
	local record_type=$1
	local record_name=$2
	local content_prefix=$3
	local payload=$4
	local records managed_records primary_record primary_id record_id

	records=$(list_records "$record_type" "$record_name")
	if [[ -n $content_prefix ]]; then
		managed_records=$(jq --compact-output --arg prefix "${content_prefix,,}" \
			'[.[] | select((.content | ascii_downcase) | startswith($prefix))] | sort_by(.id)' <<<"$records")
	else
		managed_records=$(jq --compact-output 'sort_by(.id)' <<<"$records")
	fi

	if [[ $(jq 'length' <<<"$managed_records") -eq 0 ]]; then
		cloudflare_request POST "/zones/$CLOUDFLARE_ZONE_ID/dns_records" "$payload" >/dev/null
		printf 'Created %s %s\n' "$record_type" "$record_name"
		return
	fi

	primary_record=$(jq --compact-output '.[0]' <<<"$managed_records")
	primary_id=$(jq --raw-output '.id' <<<"$primary_record")
	if record_matches_payload "$primary_record" "$payload"; then
		printf 'Unchanged %s %s\n' "$record_type" "$record_name"
	else
		cloudflare_request PUT "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$primary_id" "$payload" >/dev/null
		printf 'Updated %s %s\n' "$record_type" "$record_name"
	fi

	while IFS= read -r record_id; do
		cloudflare_request DELETE "/zones/$CLOUDFLARE_ZONE_ID/dns_records/$record_id" >/dev/null
		printf 'Removed duplicate %s %s\n' "$record_type" "$record_name"
	done < <(jq --raw-output '.[1:][] | .id' <<<"$managed_records")
}

ensure_no_cname() {
	local record_name=$1
	local records

	records=$(list_records CNAME "$record_name")
	[[ $(jq 'length' <<<"$records") -eq 0 ]] || fail "$record_name has a CNAME record that must be resolved manually."
}

a_record_payload() {
	local record_name=$1

	jq --compact-output --null-input \
		--arg name "$record_name" \
		--arg content "$MAIL_IPV4" \
		--argjson ttl "$dns_ttl" \
		'{type: "A", name: $name, content: $content, ttl: $ttl, proxied: false}'
}

txt_record_payload() {
	local record_name=$1
	local record_content=$2

	jq --compact-output --null-input \
		--arg name "$record_name" \
		--arg content "$record_content" \
		--argjson ttl "$dns_ttl" \
		'{type: "TXT", name: $name, content: $content, ttl: $ttl}'
}

mx_record_payload() {
	jq --compact-output --null-input \
		--arg name "$domain" \
		--arg content "$mail_host" \
		--argjson ttl "$dns_ttl" \
		--argjson priority "$mx_priority" \
		'{type: "MX", name: $name, content: $content, ttl: $ttl, priority: $priority}'
}

a_record_names=(
	"mail.$domain"
	"email.$domain"
	"autoconfig.$domain"
	"autodiscover.$domain"
	"mta-sts.$domain"
	"ua-auto-config.$domain"
)
dkim_ed25519_name=$dkim_ed25519_selector._domainkey.$domain
dkim_rsa_name=$dkim_rsa_selector._domainkey.$domain

for record_name in "${a_record_names[@]}" "$dkim_ed25519_name" "$dkim_rsa_name" "_dmarc.$domain" "_mta-sts.$domain" "_smtp._tls.$domain"; do
	ensure_no_cname "$record_name"
done

for record_name in "${a_record_names[@]}"; do
	reconcile_singleton A "$record_name" '' "$(a_record_payload "$record_name")"
done

reconcile_singleton TXT "$dkim_ed25519_name" 'v=DKIM1;' \
	"$(txt_record_payload "$dkim_ed25519_name" "$DKIM_ED25519_RECORD")"
reconcile_singleton TXT "$dkim_rsa_name" 'v=DKIM1;' \
	"$(txt_record_payload "$dkim_rsa_name" "$DKIM_RSA_RECORD")"
reconcile_singleton TXT "$domain" 'v=spf1' "$(txt_record_payload "$domain" "$spf_record")"
if [[ -n $dmarc_record ]]; then
	reconcile_singleton TXT "_dmarc.$domain" 'v=DMARC1;' \
		"$(txt_record_payload "_dmarc.$domain" "$dmarc_record")"
fi
reconcile_singleton TXT "_mta-sts.$domain" 'v=STSv1;' \
	"$(txt_record_payload "_mta-sts.$domain" "v=STSv1; id=$MTA_STS_ID")"
reconcile_singleton TXT "_smtp._tls.$domain" 'v=TLSRPTv1;' \
	"$(txt_record_payload "_smtp._tls.$domain" "$tls_rpt_record")"

if [[ $mode == post-mx ]]; then
	reconcile_singleton MX "$domain" '' "$(mx_record_payload)"
else
	printf 'Left all MX records unchanged in pre-mx mode\n'
fi
