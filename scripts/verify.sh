#!/usr/bin/env bash
set -uo pipefail

usage() {
	cat <<'EOF'
Usage: verify.sh <pre-mx|post-mx|roundtrip>

Required environment:
  DKIM_SELECTORS                 Comma-separated selectors published by Stalwart

Optional environment:
  DOMAIN                         Mail domain (default: cookai-inc.com)
  EXPECTED_IPV4                  Require mail.<domain> to resolve to this IPv4
  EXPECTED_MX_PREFERENCE         Expected MX preference (default: 10)
  DNS_RESOLVER                   Recursive DNS resolver (default: 1.1.1.1)
  OUTBOUND_SMTP_PROBE_HOST       Remote port 25 probe (default: gmail-smtp-in.l.google.com)
  PROBE_TIMEOUT                  Network timeout in seconds (default: 15)

Roundtrip mode also requires:
  ROUNDTRIP_LOCAL_ADDRESS
  ROUNDTRIP_EXTERNAL_ADDRESS
  ROUNDTRIP_OUTBOUND_SEND_HOOK
  ROUNDTRIP_EXTERNAL_WAIT_HOOK
  ROUNDTRIP_INBOUND_SEND_HOOK
  ROUNDTRIP_LOCAL_WAIT_HOOK
EOF
}

if [[ $# -ne 1 ]]; then
	usage >&2
	exit 2
fi

mode=$1
case $mode in
pre-mx | post-mx | roundtrip) ;;
-h | --help)
	usage
	exit 0
	;;
*)
	usage >&2
	exit 2
	;;
esac

domain=${DOMAIN:-cookai-inc.com}
mail_host=mail.$domain
webmail_host=email.$domain
mta_sts_host=mta-sts.$domain
webmail_origin=https://$webmail_host
expected_ipv4=${EXPECTED_IPV4:-}
expected_mx_preference=${EXPECTED_MX_PREFERENCE:-10}
dns_resolver=${DNS_RESOLVER:-1.1.1.1}
outbound_smtp_probe_host=${OUTBOUND_SMTP_PROBE_HOST:-gmail-smtp-in.l.google.com}
probe_timeout=${PROBE_TIMEOUT:-15}
dkim_selectors_value=${DKIM_SELECTORS:-}

failures=0
warnings=0

pass() {
	printf '[PASS] %s\n' "$1"
}

fail() {
	printf '[FAIL] %s\n' "$1" >&2
	((failures += 1))
}

warn() {
	printf '[WARN] %s\n' "$1" >&2
	((warnings += 1))
}

ipv4_is_valid() {
	local address=$1
	local first_octet second_octet third_octet fourth_octet extra

	IFS=. read -r first_octet second_octet third_octet fourth_octet extra <<<"$address"
	[[ -z ${extra:-} && -n ${fourth_octet:-} ]] || return 1
	for octet in "$first_octet" "$second_octet" "$third_octet" "$fourth_octet"; do
		[[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
		((10#$octet <= 255)) || return 1
	done
}

if [[ ! $domain =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; then
	printf 'Invalid DOMAIN: %s\n' "$domain" >&2
	exit 2
fi
if [[ ! $expected_mx_preference =~ ^[0-9]+$ ]]; then
	printf 'EXPECTED_MX_PREFERENCE must be a non-negative integer.\n' >&2
	exit 2
fi
if [[ ! $probe_timeout =~ ^[1-9][0-9]*$ ]]; then
	printf 'PROBE_TIMEOUT must be a positive integer.\n' >&2
	exit 2
fi
if [[ ! $dns_resolver =~ ^[A-Za-z0-9:.%-]+$ ]]; then
	printf 'Invalid DNS_RESOLVER: %s\n' "$dns_resolver" >&2
	exit 2
fi
if [[ -n $expected_ipv4 ]] && ! ipv4_is_valid "$expected_ipv4"; then
	printf 'Invalid EXPECTED_IPV4: %s\n' "$expected_ipv4" >&2
	exit 2
fi
if [[ -z $dkim_selectors_value ]]; then
	printf 'DKIM_SELECTORS is required; copy the active selectors from the Stalwart domain DNS records.\n' >&2
	exit 2
fi

for required_command in awk curl dig grep jq mktemp openssl sed sort timeout tr; do
	if ! command -v "$required_command" >/dev/null; then
		printf 'Required command is unavailable: %s\n' "$required_command" >&2
		exit 2
	fi
done

if [[ $mode == roundtrip ]]; then
	roundtrip_timeout=${ROUNDTRIP_TIMEOUT:-300}
	if [[ ! $roundtrip_timeout =~ ^[1-9][0-9]*$ ]]; then
		printf 'ROUNDTRIP_TIMEOUT must be a positive integer.\n' >&2
		exit 2
	fi
	if [[ -z ${ROUNDTRIP_LOCAL_ADDRESS:-} || -z ${ROUNDTRIP_EXTERNAL_ADDRESS:-} ]]; then
		printf 'Roundtrip mode requires ROUNDTRIP_LOCAL_ADDRESS and ROUNDTRIP_EXTERNAL_ADDRESS.\n' >&2
		exit 2
	fi
	for hook_name in \
		ROUNDTRIP_OUTBOUND_SEND_HOOK \
		ROUNDTRIP_EXTERNAL_WAIT_HOOK \
		ROUNDTRIP_INBOUND_SEND_HOOK \
		ROUNDTRIP_LOCAL_WAIT_HOOK; do
		hook_path=${!hook_name:-}
		if [[ -z $hook_path || ! -x $hook_path ]]; then
			printf '%s must point to an executable hook.\n' "$hook_name" >&2
			exit 2
		fi
	done
fi

temporary_directory=$(mktemp -d)
cleanup() {
	rm -rf "$temporary_directory"
}
trap cleanup EXIT

dns_ipv4_records() {
	dig "@$dns_resolver" +time=3 +tries=1 +short A "$1" 2>/dev/null | awk '/^[0-9]+(\.[0-9]+){3}$/ { print }' | sort -u
}

dns_txt_records() {
	dig "@$dns_resolver" +time=3 +tries=1 +short TXT "$1" 2>/dev/null |
		sed -E 's/"[[:space:]]*"//g; s/^"//; s/"$//'
}

txt_records_with_prefix() {
	local record_name=$1
	local prefix=$2

	dns_txt_records "$record_name" | awk -v prefix="$prefix" 'index(tolower($0), tolower(prefix)) == 1 { print }'
}

header_value() {
	local headers_file=$1
	local header_name=$2

	awk -F: -v header_name="$header_name" '
		tolower($1) == tolower(header_name) {
			sub(/^[^:]*:[[:space:]]*/, "")
			gsub(/\r$/, "")
			value = $0
		}
		END { print value }
	' "$headers_file"
}

contains_token_case_insensitive() {
	local value=$1
	local expected_token=$2

	awk '{ gsub(/[[:space:],]+/, "\n"); print }' <<<"$value" |
		grep --quiet --ignore-case --fixed-strings --line-regexp "$expected_token"
}

check_host_ipv4() {
	local hostname=$1
	local expected_address=$2
	local -a addresses=()

	mapfile -t addresses < <(dns_ipv4_records "$hostname")
	if [[ ${#addresses[@]} -eq 0 ]]; then
		fail "$hostname has no IPv4 A answer"
		return
	fi
	if printf '%s\n' "${addresses[@]}" | grep --quiet --fixed-strings --line-regexp "$expected_address"; then
		pass "$hostname resolves to $expected_address"
	else
		fail "$hostname does not resolve to the mail server IPv4 ($expected_address)"
	fi
}

probe_tls_service() {
	local label=$1
	local port=$2
	local starttls_protocol=$3
	local input=$4
	local application_pattern=$5
	local output_file=$temporary_directory/tls-$port.txt
	local -a openssl_arguments=(
		s_client
		-brief
		-crlf
		-connect "$mail_host:$port"
		-servername "$mail_host"
		-verify_hostname "$mail_host"
		-verify_return_error
		-CApath /etc/ssl/certs
	)

	if [[ -n $starttls_protocol ]]; then
		openssl_arguments+=(-starttls "$starttls_protocol" -name verify.invalid)
	fi

	printf '%s' "$input" |
		timeout "$probe_timeout" openssl "${openssl_arguments[@]}" -quiet >"$output_file" 2>&1 || true
	if ! grep --quiet --fixed-strings 'Verification: OK' "$output_file"; then
		fail "$label did not verify the certificate chain and hostname"
		return
	fi
	if ! grep --quiet --extended-regexp "$application_pattern" "$output_file"; then
		fail "$label completed TLS but did not speak the expected protocol"
		return
	fi
	pass "$label protocol and TLS certificate chain/hostname"
}

probe_outbound_smtp25() {
	local output_file=$temporary_directory/outbound-smtp25.txt

	printf 'QUIT\n' |
		timeout "$probe_timeout" openssl s_client \
			-brief \
			-crlf \
			-starttls smtp \
			-4 \
			-connect "$outbound_smtp_probe_host:25" \
			-name verify.invalid \
			-servername "$outbound_smtp_probe_host" \
			>"$output_file" 2>&1 || return 1
	grep --quiet --fixed-strings 'CONNECTION ESTABLISHED' "$output_file"
}

printf 'CookAI mail verification mode: %s\n' "$mode"

mapfile -t mail_ipv4s < <(dns_ipv4_records "$mail_host")
if [[ ${#mail_ipv4s[@]} -ne 1 ]]; then
	fail "$mail_host must have exactly one IPv4 A answer"
	mail_ipv4=${mail_ipv4s[0]:-}
else
	mail_ipv4=${mail_ipv4s[0]}
	pass "$mail_host has one IPv4 A answer ($mail_ipv4)"
fi

if [[ -n $expected_ipv4 && $mail_ipv4 != "$expected_ipv4" ]]; then
	fail "$mail_host does not resolve to EXPECTED_IPV4 ($expected_ipv4)"
elif [[ -n $expected_ipv4 ]]; then
	pass "$mail_host matches EXPECTED_IPV4"
fi

if [[ -n $mail_ipv4 ]]; then
	mapfile -t ptr_records < <(dig "@$dns_resolver" +time=3 +tries=1 +short -x "$mail_ipv4" 2>/dev/null | sed 's/\.$//' | sort -u)
	if [[ ${#ptr_records[@]} -eq 1 && ${ptr_records[0],,} == "$mail_host" ]]; then
		pass "PTR for $mail_ipv4 is $mail_host"
		ptr_matches_mail_host=true
	else
		fail "PTR for $mail_ipv4 must be exactly $mail_host"
		ptr_matches_mail_host=false
	fi

	mapfile -t forward_confirmed_addresses < <(dns_ipv4_records "${ptr_records[0]:-$mail_host}")
	if [[ $ptr_matches_mail_host == true ]] &&
		printf '%s\n' "${forward_confirmed_addresses[@]}" | grep --quiet --fixed-strings --line-regexp "$mail_ipv4"; then
		pass "FCrDNS maps $mail_host back to $mail_ipv4"
	else
		fail "FCrDNS does not map $mail_ipv4 through $mail_host and back"
	fi

	for required_host in "$webmail_host" "autoconfig.$domain" "autodiscover.$domain" "$mta_sts_host" "ua-auto-config.$domain"; do
		check_host_ipv4 "$required_host" "$mail_ipv4"
	done
fi

mapfile -t mx_records < <(dig "@$dns_resolver" +time=3 +tries=1 +short MX "$domain" 2>/dev/null | sed 's/\.$//' | sort -n -k1,1 -k2,2)
expected_mx_record="$expected_mx_preference $mail_host"
if [[ $mode == pre-mx ]]; then
	if [[ ${#mx_records[@]} -eq 0 ]]; then
		pass 'Apex MX is not published before cutover'
	elif [[ ${#mx_records[@]} -eq 1 && ${mx_records[0],,} == "$expected_mx_record" ]]; then
		warn "Apex MX is already cut over to $expected_mx_record"
	else
		warn 'Apex MX still points elsewhere; post-mx mode will require the final record'
	fi
elif [[ ${#mx_records[@]} -eq 1 && ${mx_records[0],,} == "$expected_mx_record" ]]; then
	pass "Apex MX is exactly $expected_mx_record"
else
	fail "Apex MX must be exactly $expected_mx_record"
fi

mapfile -t spf_records < <(txt_records_with_prefix "$domain" 'v=spf1')
if [[ ${#spf_records[@]} -ne 1 ]]; then
	fail "$domain must publish exactly one SPF record"
elif [[ -z $mail_ipv4 ]]; then
	fail 'SPF cannot be checked without the mail server IPv4'
else
	spf_record=${spf_records[0],,}
	spf_ip_pattern=${mail_ipv4//./\\.}
	spf_mail_host_pattern=${mail_host//./\\.}
	if [[ ! $spf_record =~ (^|[[:space:]])-all$ ]]; then
		fail 'SPF must end with -all'
	elif [[ $spf_record =~ (^|[[:space:]])\+?ip4:$spf_ip_pattern(/32)?([[:space:]]|$) ]] ||
		[[ $spf_record =~ (^|[[:space:]])\+?a:$spf_mail_host_pattern(/32)?([[:space:]]|$) ]] ||
		[[ $spf_record =~ (^|[[:space:]])\+?mx([[:space:]]|$) ]]; then
		pass 'SPF authorizes the mail server and ends with -all'
	else
		fail "SPF does not authorize $mail_ipv4 or $mail_host"
	fi
fi

IFS=, read -r -a dkim_selectors <<<"$dkim_selectors_value"
for selector_value in "${dkim_selectors[@]}"; do
	selector=$(tr -d '[:space:]' <<<"$selector_value")
	if [[ ! $selector =~ ^[A-Za-z0-9_-]{1,63}$ ]]; then
		fail "Invalid DKIM selector in DKIM_SELECTORS: $selector_value"
		continue
	fi
	dkim_name=$selector._domainkey.$domain
	mapfile -t dkim_records < <(txt_records_with_prefix "$dkim_name" 'v=DKIM1')
	if [[ ${#dkim_records[@]} -ne 1 ]]; then
		fail "$dkim_name must publish exactly one DKIM record"
		continue
	fi
	dkim_record=${dkim_records[0],,}
	if [[ ! $dkim_record =~ (^|\;)[[:space:]]*k=(rsa|ed25519)(\;|[[:space:]]|$) ]]; then
		fail "$dkim_name has no supported DKIM key algorithm"
	elif [[ ! $dkim_record =~ (^|\;)[[:space:]]*p=[^\;[:space:]]+ ]]; then
		fail "$dkim_name has no DKIM public key"
	else
		pass "$dkim_name publishes a usable DKIM public key"
	fi
done

mapfile -t dmarc_records < <(txt_records_with_prefix "_dmarc.$domain" 'v=DMARC1')
if [[ ${#dmarc_records[@]} -ne 1 ]]; then
	fail "_dmarc.$domain must publish exactly one DMARC record"
elif [[ ${dmarc_records[0],,} =~ (^|\;)[[:space:]]*p=(none|quarantine|reject)(\;|[[:space:]]|$) ]]; then
	pass 'DMARC publishes a valid domain policy'
else
	fail 'DMARC does not contain a valid p policy'
fi

mapfile -t mta_sts_dns_records < <(txt_records_with_prefix "_mta-sts.$domain" 'v=STSv1')
if [[ ${#mta_sts_dns_records[@]} -ne 1 ]]; then
	fail "_mta-sts.$domain must publish exactly one MTA-STS record"
elif [[ ${mta_sts_dns_records[0]} =~ (^|\;)[[:space:]]*id=[A-Za-z0-9._-]{1,32}([[:space:]]|$|\;) ]]; then
	pass 'MTA-STS DNS record has a policy id'
else
	fail 'MTA-STS DNS record has no valid policy id'
fi

mapfile -t tls_rpt_records < <(txt_records_with_prefix "_smtp._tls.$domain" 'v=TLSRPTv1')
if [[ ${#tls_rpt_records[@]} -ne 1 ]]; then
	fail "_smtp._tls.$domain must publish exactly one TLS-RPT record"
elif [[ ${tls_rpt_records[0],,} =~ (^|\;)[[:space:]]*rua=(mailto|https):[^\;[:space:]]+ ]]; then
	pass 'TLS-RPT publishes an aggregate report destination'
else
	fail 'TLS-RPT has no valid rua destination'
fi

if curl --fail --silent --show-error --connect-timeout "$probe_timeout" --max-time "$probe_timeout" \
	"https://$mail_host/healthz/live" >/dev/null; then
	pass 'Stalwart HTTPS health and TLS certificate chain/hostname'
else
	fail 'Stalwart HTTPS health or TLS certificate validation failed'
fi

if curl --fail --silent --show-error --connect-timeout "$probe_timeout" --max-time "$probe_timeout" \
	"https://$webmail_host/api/health" >/dev/null; then
	pass 'Webmail HTTPS health and TLS certificate chain/hostname'
else
	fail 'Webmail HTTPS health or TLS certificate validation failed'
fi

jmap_headers=$temporary_directory/jmap-headers.txt
jmap_body=$temporary_directory/jmap-body.json
jmap_status=$(curl --silent --show-error --connect-timeout "$probe_timeout" --max-time "$probe_timeout" \
	--location \
	--max-redirs 3 \
	--dump-header "$jmap_headers" \
	--output "$jmap_body" \
	--write-out '%{http_code}' \
	--header "Origin: $webmail_origin" \
	"https://$mail_host/.well-known/jmap" 2>/dev/null) || jmap_status=000
jmap_allow_origin=$(header_value "$jmap_headers" Access-Control-Allow-Origin)
if [[ $jmap_status == 200 ]] && jq --exit-status --arg prefix "https://$mail_host/" \
	'type == "object" and (.apiUrl | type == "string" and startswith($prefix)) and (.capabilities | type == "object")' \
	"$jmap_body" >/dev/null 2>&1; then
	pass 'JMAP discovery returns a valid session document'
elif [[ $jmap_status == 401 && -n $(header_value "$jmap_headers" WWW-Authenticate) ]]; then
	pass 'JMAP discovery requires authentication and advertises an auth scheme'
else
	fail "JMAP discovery returned an unexpected response (HTTP $jmap_status)"
fi
if [[ $jmap_allow_origin == '*' || $jmap_allow_origin == "$webmail_origin" ]]; then
	pass 'JMAP discovery permits the webmail origin'
else
	fail 'JMAP discovery does not permit the webmail origin'
fi

cors_headers=$temporary_directory/cors-headers.txt
cors_status=$(curl --silent --show-error --connect-timeout "$probe_timeout" --max-time "$probe_timeout" \
	--request OPTIONS \
	--dump-header "$cors_headers" \
	--output /dev/null \
	--write-out '%{http_code}' \
	--header "Origin: $webmail_origin" \
	--header 'Access-Control-Request-Method: POST' \
	--header 'Access-Control-Request-Headers: authorization,content-type' \
	"https://$mail_host/jmap" 2>/dev/null) || cors_status=000
cors_allow_origin=$(header_value "$cors_headers" Access-Control-Allow-Origin)
cors_allow_methods=$(header_value "$cors_headers" Access-Control-Allow-Methods)
cors_allow_headers=$(header_value "$cors_headers" Access-Control-Allow-Headers)
if [[ ! $cors_status =~ ^2[0-9][0-9]$ ]]; then
	fail "JMAP CORS preflight failed (HTTP $cors_status)"
elif [[ $cors_allow_origin != '*' && $cors_allow_origin != "$webmail_origin" ]]; then
	fail 'JMAP CORS preflight rejects the webmail origin'
elif ! contains_token_case_insensitive "$cors_allow_methods" POST && [[ $cors_allow_methods != '*' ]]; then
	fail 'JMAP CORS preflight does not permit POST'
elif [[ $cors_allow_headers != '*' ]] &&
	{ ! contains_token_case_insensitive "$cors_allow_headers" authorization ||
		! contains_token_case_insensitive "$cors_allow_headers" content-type; }; then
	fail 'JMAP CORS preflight does not permit authorization and content-type headers'
else
	pass 'JMAP CORS preflight permits authenticated webmail requests'
fi

mta_sts_policy=$temporary_directory/mta-sts.txt
mta_sts_headers=$temporary_directory/mta-sts-headers.txt
if curl --fail --silent --show-error --connect-timeout "$probe_timeout" --max-time "$probe_timeout" \
	--dump-header "$mta_sts_headers" \
	"https://$mta_sts_host/.well-known/mta-sts.txt" --output "$mta_sts_policy"; then
	mta_sts_content_type=$(header_value "$mta_sts_headers" Content-Type)
	mapfile -t mta_sts_versions < <(awk -F: 'tolower($1) == "version" { value = tolower($2); gsub(/[[:space:]\r]/, "", value); print value }' "$mta_sts_policy")
	mapfile -t mta_sts_modes < <(awk -F: 'tolower($1) == "mode" { value = tolower($2); gsub(/[[:space:]\r]/, "", value); print value }' "$mta_sts_policy")
	mapfile -t mta_sts_mx_hosts < <(awk -F: 'tolower($1) == "mx" { value = tolower($2); gsub(/[[:space:]\r]/, "", value); print value }' "$mta_sts_policy")
	mapfile -t mta_sts_max_ages < <(awk -F: 'tolower($1) == "max_age" { value = $2; gsub(/[[:space:]\r]/, "", value); print value }' "$mta_sts_policy")
	if [[ ${mta_sts_content_type,,} == text/plain* &&
		${#mta_sts_versions[@]} -eq 1 && ${mta_sts_versions[0]:-} == stsv1 &&
		${#mta_sts_modes[@]} -eq 1 &&
		${#mta_sts_mx_hosts[@]} -eq 1 && ${mta_sts_mx_hosts[0]:-} == "$mail_host" &&
		${#mta_sts_max_ages[@]} -eq 1 && ${mta_sts_max_ages[0]:-} =~ ^[1-9][0-9]*$ ]]; then
		mta_sts_mode=${mta_sts_modes[0]}
		mta_sts_max_age=${mta_sts_max_ages[0]}
		if [[ $mode != pre-mx && $mta_sts_mode != enforce ]]; then
			fail 'Post-cutover MTA-STS policy mode must be enforce'
		elif [[ $mode == pre-mx && $mta_sts_mode != testing && $mta_sts_mode != enforce ]]; then
			fail 'Pre-cutover MTA-STS policy mode must be testing or enforce'
		elif [[ $mode != pre-mx ]] && ((10#$mta_sts_max_age < 86400)); then
			fail 'Post-cutover MTA-STS max_age must be at least 86400 seconds'
		else
			pass 'MTA-STS HTTPS policy, TLS certificate, MX host, mode, and max_age'
		fi
	else
		fail 'MTA-STS HTTPS policy is incomplete or malformed'
	fi
else
	fail 'MTA-STS HTTPS policy or TLS certificate validation failed'
fi

probe_tls_service 'SMTP STARTTLS on port 25' 25 smtp $'EHLO verify.invalid\nQUIT\n' '(^|[[:space:]])250[- ]'
probe_tls_service 'SMTPS on port 465' 465 '' $'EHLO verify.invalid\nQUIT\n' '(^|[[:space:]])250[- ]'
probe_tls_service 'Submission STARTTLS on port 587' 587 smtp $'EHLO verify.invalid\nQUIT\n' '(^|[[:space:]])250[- ]'
probe_tls_service 'IMAPS on port 993' 993 '' $'a1 CAPABILITY\na2 LOGOUT\n' '^\* CAPABILITY .*IMAP'

if probe_outbound_smtp25; then
	pass "Direct outbound TCP/25 reaches $outbound_smtp_probe_host"
else
	fail "Direct outbound TCP/25 cannot reach $outbound_smtp_probe_host from this machine"
fi

if [[ $mode == roundtrip && $failures -eq 0 ]]; then
	verify_roundtrip_id=$(openssl rand -hex 12)
	export VERIFY_ROUNDTRIP_ID=$verify_roundtrip_id
	export VERIFY_OUTBOUND_SUBJECT="CookAI outbound roundtrip $verify_roundtrip_id"
	export VERIFY_OUTBOUND_MESSAGE_ID="<outbound.$verify_roundtrip_id@verification.invalid>"
	export VERIFY_INBOUND_SUBJECT="CookAI inbound roundtrip $verify_roundtrip_id"
	export VERIFY_INBOUND_MESSAGE_ID="<inbound.$verify_roundtrip_id@verification.invalid>"
	export VERIFY_LOCAL_ADDRESS=$ROUNDTRIP_LOCAL_ADDRESS
	export VERIFY_EXTERNAL_ADDRESS=$ROUNDTRIP_EXTERNAL_ADDRESS
	export VERIFY_ROUNDTRIP_TIMEOUT=$roundtrip_timeout
	export VERIFY_EXPECT_AUTHENTICATION=spf,dkim,dmarc

	if timeout "$roundtrip_timeout" "$ROUNDTRIP_OUTBOUND_SEND_HOOK"; then
		pass 'Hosted mailbox submitted the outbound roundtrip message'
		outbound_message_sent=true
	else
		fail 'Outbound roundtrip send hook failed'
		outbound_message_sent=false
	fi
	if [[ $outbound_message_sent == true ]] && timeout "$roundtrip_timeout" "$ROUNDTRIP_EXTERNAL_WAIT_HOOK"; then
		pass 'External mailbox received the outbound message with SPF, DKIM, and DMARC results'
	else
		fail 'External mailbox did not verify the outbound roundtrip message'
	fi
	if timeout "$roundtrip_timeout" "$ROUNDTRIP_INBOUND_SEND_HOOK"; then
		pass 'External mailbox submitted the inbound roundtrip message'
		inbound_message_sent=true
	else
		fail 'Inbound roundtrip send hook failed'
		inbound_message_sent=false
	fi
	if [[ $inbound_message_sent == true ]] && timeout "$roundtrip_timeout" "$ROUNDTRIP_LOCAL_WAIT_HOOK"; then
		pass 'Hosted mailbox received the inbound roundtrip message'
	else
		fail 'Hosted mailbox did not receive the inbound roundtrip message'
	fi
elif [[ $mode == roundtrip ]]; then
	warn 'Roundtrip hooks were skipped because static cutover checks failed'
fi

printf '\nVerification finished: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
if ((failures > 0)); then
	exit 1
fi
