# CookAI Mail Infrastructure

Self-hosted company mail for `cookai-inc.com`.

The stack uses Stalwart for SMTP, IMAP, JMAP, account administration, filtering, and storage; Bulwark for webmail; and Caddy for HTTPS termination. Caddy also serves the separately built, authenticated provider-operations dashboard from an immutable host directory. Public mail protocols connect directly to Stalwart so the original peer address is preserved.

## Public services

- `https://email.cookai-inc.com` — webmail
- `https://mail.cookai-inc.com` — JMAP and client auto-configuration
- `https://providers.cookai-inc.com` — authenticated provider-operations dashboard
- `mail.cookai-inc.com:25` — server-to-server SMTP
- `mail.cookai-inc.com:465` — implicit TLS submission
- `mail.cookai-inc.com:587` — STARTTLS submission
- `mail.cookai-inc.com:993` — IMAPS

Host access to ports `3000` and `8080` is bound only to the VPS loopback interface. Port `3000` is reserved for Bulwark administration; port `8080` provides Stalwart bootstrap and recovery access while remaining reachable by Caddy on the Compose network for HTTP-01 challenges. POP3, plaintext IMAP, and externally exposed ManageSieve are intentionally omitted.

## Host bootstrap

Run the host bootstrap once the replacement VPS is reachable. It accepts only Ubuntu 24.04, installs Docker CE from Docker's official repository, enables unattended security upgrades, configures Docker log rotation and live restore, creates a 2 GiB swap file only when the host has no swap, and replaces the UFW rules with the required public ports.

```bash
sudo ./scripts/bootstrap-host.sh mail.cookai-inc.com
```

The resulting inbound policy rate-limits SSH on port `22` and permits only TCP ports `25`, `80`, `443`, `465`, `587`, and `993`. The script is idempotent, but resetting UFW means it should not be used on a host that serves unrelated workloads.

The bootstrap deliberately does not change root login or password authentication. Harden SSH only after the operator account and public key have been installed and a second session has successfully verified both key login and passwordless `sudo`. Keep the original session open, add the SSH policy in `/etc/ssh/sshd_config.d`, run `sudo sshd -t`, reload `ssh.service`, and verify a third new session before disabling root or password login.

## Deployment

The host keeps runtime configuration under `/etc/cookai-mail`, while the deployment files live under `/opt/cookai-mail`.

```bash
sudo install -d -m 700 /etc/cookai-mail/secrets
sudo install -m 600 stalwart.env.example /etc/cookai-mail/stalwart.env
sudo install -m 600 bulwark.env.example /etc/cookai-mail/bulwark.env
read -r -s -p 'Provider dashboard password: ' PROVIDER_DASHBOARD_PASSWORD
printf '\n'
PROVIDER_DASHBOARD_PASSWORD_HASH="$(printf '%s\n' "$PROVIDER_DASHBOARD_PASSWORD" | sudo docker run --rm -i caddy:2.11.4-alpine caddy hash-password --algorithm bcrypt)"
printf 'PROVIDER_DASHBOARD_PASSWORD_HASH=%s\n' "$PROVIDER_DASHBOARD_PASSWORD_HASH" | sudo install -m 600 /dev/stdin /etc/cookai-mail/caddy.env
unset PROVIDER_DASHBOARD_PASSWORD PROVIDER_DASHBOARD_PASSWORD_HASH
sudo openssl rand -hex -out /etc/cookai-mail/secrets/bulwark-session 48
sudo chmod 600 /etc/cookai-mail/secrets/bulwark-session
sudo docker compose pull
sudo docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile
sudo docker compose up -d caddy stalwart
```

On its first start, Stalwart listens on the loopback-bound recovery port and prints a one-time administrator password. It intentionally remains `unhealthy` until production HTTPS is configured. Complete its setup through an SSH tunnel to `http://127.0.0.1:8080/admin`. The permanent configuration is written to the `stalwart-config` volume and invalidates the temporary account.

The Stalwart setup must provide all of the following:

- primary hostname and public URL set to `mail.cookai-inc.com`
- HTTP listener kept on internal port `8080` for administration, recovery, and ACME challenges
- HTTPS listener on internal port `443`
- SMTP listeners on `25`, `465`, and `587`, plus IMAPS on `993`
- ACME certificate issuance using HTTP-01 through the internal HTTP listener
- a valid certificate for `mail.cookai-inc.com`
- `Http.usePermissiveCors` enabled for Bulwark's separate origin
- `Http.useXForwarded` enabled so Stalwart receives the original web client address
- a global outbound MTA throttle of at most 20 messages per minute
- the default outbound connection strategy using `mail.cookai-inc.com` as its EHLO hostname
- the default MX route restricted to IPv4 delivery when IPv6 PTR and SPF are not published

Caddy owns public ports `80` and `443` throughout setup and production. It forwards `/.well-known/acme-challenge/*` on the mail-service hostnames to Stalwart on internal port `8080`, allowing Stalwart to complete HTTP-01 issuance without publishing its own web listeners. After issuance, Caddy validates the internal Stalwart certificate with SNI `mail.cookai-inc.com` when proxying HTTPS requests. Stalwart's port `443` remains private to the Compose network.

Set a strong `ADMIN_PASSWORD` only in the root-owned `/etc/cookai-mail/bulwark.env`. Because `JMAP_SERVER_URL` is fixed in that file, Bulwark uses immutable environment-driven configuration and does not run its setup wizard.

After Stalwart is configured and listening on its internal HTTPS port, start the complete production stack:

```bash
sudo docker compose up -d
```

Production mounts the Bulwark administrator configuration read-only and blocks `/admin` and `/api/admin` at the public proxy. For later administration, tunnel the loopback-only Bulwark port over SSH and use `http://127.0.0.1:3000/admin`. Long-lived credentials and API tokens are never committed.

The provider dashboard is built and deployed from `cookai-inc/provider-operations`. Its forced-command deploy user
writes versioned releases below `/srv/provider-dashboard` and atomically changes the `current` symlink. Set
`PROVIDER_DASHBOARD_PASSWORD_HASH` in `/etc/cookai-mail/caddy.env` to a Caddy-compatible hash; the plaintext dashboard
password belongs only in the operator secret store. Caddy authenticates every dashboard asset, applies a dashboard-only
Content Security Policy, and marks application responses private and non-cacheable.

Pinned PMTiles archives live below `/srv/provider-dashboard/tiles` and are served through the same authenticated
origin. They remain outside immutable dashboard releases so a routine dashboard deployment cannot remove the map
dataset selected by the dashboard build. Their versioned URLs use a private immutable browser cache; shared edge caches
cannot store an authenticated response.

When the restricted deployment account is installed, keep it in the SSH allowlist without granting sudo or Docker:

```bash
sudo ./scripts/harden-host-access.sh lockdown chelokot provider-dashboard
```

The initial MX switch is permitted only after the host has a matching PTR, direct outbound TCP/25 succeeds, all DNS authentication records resolve, and external send/receive tests pass.

## DNS cutover

`scripts/configure-dns.sh` reconciles only the six mail-service A records, the two active Stalwart DKIM records, the apex SPF record, `_mta-sts`, `_smtp._tls`, an optional `DMARC_RECORD` value, and, in `post-mx` mode, the apex MX. The A records are always DNS-only. Existing DMARC is preserved when `DMARC_RECORD` is unset; ACME authorization, verification, Resend DKIM, `send.*`, subdomain MX, and every other record remain untouched.

Give the script a zone-restricted Cloudflare token with DNS read and write access. This token is used only by the DNS reconciliation command; it is not installed or mounted into the mail stack. `DKIM_ED25519_RECORD` and `DKIM_RSA_RECORD` are the complete TXT values from Stalwart. Their selectors default to the active `v1-ed25519-20260712` and `v1-rsa-20260712` selectors and can be overridden. `SPF_RECORD` is the complete authoritative apex SPF policy; its default authorizes only `MAIL_IPV4`. Change `MTA_STS_ID` whenever the published MTA-STS policy changes.

```bash
set -a
source /secure/source/cookai-mail-dns.env
set +a
./scripts/configure-dns.sh pre-mx
```

`pre-mx` never creates, updates, or deletes an MX record. After pre-cutover verification and external delivery tests pass, run `post-mx`; it deliberately makes `10 mail.cookai-inc.com` the single apex MX while continuing to preserve MX records at every subdomain.

## Operations

```bash
sudo docker compose ps
sudo docker compose logs --since 30m
sudo docker compose pull
sudo docker compose up -d
DKIM_SELECTORS=actual-ed25519-selector,actual-rsa-selector ./scripts/verify.sh pre-mx
```

Run `pre-mx` on the VPS before publishing the apex MX. It verifies the staged DNS records, PTR/FCrDNS, public TLS endpoints, SMTP/IMAP/JMAP protocols, CORS, MTA-STS, and direct outbound port 25; set `EXPECTED_IPV4` to pin the intended server address. After publishing the single `10 mail.cookai-inc.com` MX, run the same command with `post-mx`. Post-MX mode requires every DNS authentication and transport-security record and requires MTA-STS `enforce` mode. `DKIM_SELECTORS` must contain the active comma-separated selectors shown by Stalwart's domain DNS record view.

For an actual two-way delivery gate, use `roundtrip` with local and external test addresses plus four executable hook paths: `ROUNDTRIP_OUTBOUND_SEND_HOOK`, `ROUNDTRIP_EXTERNAL_WAIT_HOOK`, `ROUNDTRIP_INBOUND_SEND_HOOK`, and `ROUNDTRIP_LOCAL_WAIT_HOOK`. Each hook receives `VERIFY_LOCAL_ADDRESS`, `VERIFY_EXTERNAL_ADDRESS`, `VERIFY_OUTBOUND_SUBJECT`, `VERIFY_OUTBOUND_MESSAGE_ID`, `VERIFY_INBOUND_SUBJECT`, `VERIFY_INBOUND_MESSAGE_ID`, `VERIFY_ROUNDTRIP_ID`, and `VERIFY_ROUNDTRIP_TIMEOUT`; the external wait hook also enforces the comma-separated results in `VERIFY_EXPECT_AUTHENTICATION`. Send hooks submit the matching message and wait hooks poll the corresponding inbox, returning zero only after the exact marker is found. Hooks obtain their own SMTP/IMAP or provider credentials from the host secret store; no credentials or shell command strings are accepted by the verifier.

Container image versions and Linux AMD64 digests are pinned. Upgrades are deliberate and must be followed by the external protocol and delivery checks.

## Backups

Nightly backups are encrypted before leaving the host and sent to an operator-owned off-host Restic repository. The backup covers `/etc/cookai-mail`, the deployed stack, every Compose named volume, and the pinned provider PMTiles archive. Stalwart is stopped only for the final local RocksDB reconciliation and is restarted before upload, retention, and repository validation.

Setup, recovery, and disaster-recovery rehearsal instructions are in [docs/backup-restore.md](docs/backup-restore.md). The Restic password and storage credentials must be stored under `/etc/cookai-mail` with root-only permissions and must never be committed.
