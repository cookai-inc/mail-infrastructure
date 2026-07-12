# Backup and restore

Nightly backups use Restic, whose repository format encrypts file contents, names, metadata, and snapshots before they leave the host. The repository must be off-host. A private S3-compatible bucket with a key restricted to that bucket is the simplest target for this VPS; the configuration also accepts Restic's native SFTP, B2, Azure, Google Cloud Storage, or TLS-protected REST backends.

The backup includes `/etc/cookai-mail`, the deployment files from `/opt/cookai-mail`, every named volume declared by Compose, and complete PMTiles archives from `/srv/provider-dashboard/tiles`. Partial map downloads are excluded. It first creates a warm local mirror. Stalwart is then stopped, the mirror is reconciled, and Stalwart is immediately restarted before the encrypted upload begins. This produces a consistent raw RocksDB backup while keeping the SMTP interruption to the final local delta copy. A root-only staging directory is removed on success and failure.

Restic keeps seven daily, five weekly, and twelve monthly snapshots by default. Each run prunes expired data, validates repository metadata, and reads a rotating fraction of the encrypted packs so the complete repository is covered over the configured number of days.

## Initial setup

Create a private off-host bucket and a bucket-scoped read/write key. Disable public access. Provider-side versioning is recommended so an operator can recover objects deleted with a compromised VPS credential.

Store the repository password independently of both the VPS and the backup repository. It is required for disaster recovery and cannot be reset.

```bash
sudo install -d -m 700 /etc/cookai-mail/secrets
sudo install -m 600 backup.env.example /etc/cookai-mail/backup.env
sudo openssl rand -base64 48 | sudo tee /etc/cookai-mail/secrets/restic-password >/dev/null
sudo chmod 600 /etc/cookai-mail/secrets/restic-password
sudoedit /etc/cookai-mail/backup.env
sudo /opt/cookai-mail/scripts/install-backup.sh --initialize
sudo systemctl start cookai-mail-backup.service
sudo journalctl -u cookai-mail-backup.service --since today
```

Use `--initialize` only for a new empty repository. Later installs should omit it so a wrong endpoint or credential cannot accidentally create a second repository.

## Routine validation

Inspect the timer and available snapshots after initial setup and after credential changes:

```bash
systemctl list-timers cookai-mail-backup.timer
sudo systemctl start cookai-mail-backup.service
sudo systemctl status cookai-mail-backup.service
sudo bash -c 'set -a; source /etc/cookai-mail/backup.env; set +a; restic snapshots --tag cookai-mail,layout-v1'
```

Perform a non-destructive restore at least quarterly. The command cryptographically verifies restored files and validates the manifest, volume set, and Compose definition without changing the running stack:

```bash
sudo /opt/cookai-mail/scripts/restore.sh --snapshot latest --target /var/tmp/cookai-mail-restore-test
sudo rm -rf /var/tmp/cookai-mail-restore-test
```

For a full disaster-recovery rehearsal, provision an isolated VPS with no public DNS pointed at it, install Docker and the deployment revision recorded in the restored `opt/cookai-mail` directory, restore the snapshot, start the stack, and verify the Stalwart health endpoint, domains, accounts, mailboxes, queued mail, Bulwark login, TLS state, and a ranged read from the restored PMTiles archive. Never expose the rehearsal SMTP listener publicly while it contains production identities and queued messages.

## Destructive restore

Install the exact deployment files from the snapshot before applying it. The restore refuses a Compose hash mismatch or a different named-volume set. Keep the Restic repository password and provider credential outside `/etc/cookai-mail` until the snapshot has been staged, because the restored configuration cannot unlock its own encrypted repository.

```bash
sudo /opt/cookai-mail/scripts/restore.sh \
  --snapshot latest \
  --apply \
  --confirm-host "$(hostname --fqdn)"
```

The apply path verifies the snapshot before taking anything down, stops the Compose project, replaces `/etc/cookai-mail` and every named volume, then starts the stack. If copying fails after shutdown, it deliberately leaves the services stopped instead of booting a partially restored database. Review `docker compose ps` and the external delivery checks before changing DNS or accepting new mail.
