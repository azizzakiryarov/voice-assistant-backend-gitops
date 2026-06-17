# Raspberry Pi Backup And Restore

This repo and the live Raspberry Pi were inspected before generating the backup defaults. The GitOps app is `voice-assistant` in Argo CD namespace `argocd`, targeting namespace `voice-assistant`. The live cluster also has `voice-assistant-ci`, `cert-manager`, `ingress`, `metallb-system`, `tekton-pipelines`, and `tekton-pipelines-resolvers`. Persistent data is under MicroK8s hostpath storage at `/var/snap/microk8s/common/default-storage`, with PVCs for PostgreSQL, backend tokens, and Tekton workspaces. The chart also defines an Ollama hostPath at `/home/azizzakiryarov/ollama-models`.

## Install On The Raspberry Pi

Install dependencies:

```bash
sudo apt-get update
sudo apt-get install -y restic jq openssh-client util-linux
```

Create system directories:

```bash
sudo install -d -o root -g root -m 700 /etc/raspberry-backup /etc/raspberry-backup/ssh
sudo install -d -o root -g root -m 755 /usr/local/share/doc/raspberry-backup
```

Install files:

```bash
sudo install -o root -g root -m 0750 backup.sh /usr/local/sbin/backup.sh
sudo install -o root -g root -m 0750 restore.sh /usr/local/sbin/restore.sh
sudo install -o root -g root -m 0644 restic-excludes.txt /etc/raspberry-backup/restic-excludes.txt
sudo install -o root -g root -m 0644 RESTORE.md /usr/local/share/doc/raspberry-backup/RESTORE.md
sudo install -o root -g root -m 0644 raspberry-backup.service /etc/systemd/system/raspberry-backup.service
sudo install -o root -g root -m 0644 raspberry-backup.timer /etc/systemd/system/raspberry-backup.timer
sudo install -o root -g root -m 0644 raspberry-backup-check.service /etc/systemd/system/raspberry-backup-check.service
sudo install -o root -g root -m 0644 raspberry-backup-check.timer /etc/systemd/system/raspberry-backup-check.timer
```

Create root-only credentials:

```bash
sudo sh -c 'openssl rand -base64 48 > /etc/raspberry-backup/restic-password'
sudo chmod 600 /etc/raspberry-backup/restic-password
```

Create `/etc/raspberry-backup/backup.env`:

```bash
sudo tee /etc/raspberry-backup/backup.env >/dev/null <<'EOF'
RESTIC_REPOSITORY='sftp:resticbackup@mac.local:/Users/resticbackup/restic/raspberrypi'
RESTIC_PASSWORD_FILE='/etc/raspberry-backup/restic-password'
SSH_KEY_FILE='/etc/raspberry-backup/ssh/raspberry-backup-ed25519'
SSH_KNOWN_HOSTS_FILE='/etc/raspberry-backup/ssh/known_hosts'
SSH_PORT='22'

K8S_NAMESPACES='voice-assistant voice-assistant-ci argocd cert-manager ingress metallb-system tekton-pipelines tekton-pipelines-resolvers'
POSTGRES_NAMESPACE='voice-assistant'
POSTGRES_SELECTOR='app=postgres'
POSTGRES_CONTAINER='postgres'
POSTGRES_SECRET_NAME='postgres-secret'

CONFIG_BACKUP_PATHS='/etc /var/snap/microk8s/current/args /var/snap/microk8s/common/args'
APP_DATA_PATHS='/var/snap/microk8s/common/default-storage /home/azizzakiryarov/ollama-models /home/azizzakiryarov/openwebui-data'
HOME_BACKUP_PATHS=''
EOF
sudo chown root:root /etc/raspberry-backup/backup.env
sudo chmod 600 /etc/raspberry-backup/backup.env
```

Initialize and test:

```bash
sudo /usr/local/sbin/backup.sh init
sudo /usr/local/sbin/backup.sh backup
sudo /usr/local/sbin/backup.sh check
```

Enable timers:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now raspberry-backup.timer
sudo systemctl enable --now raspberry-backup-check.timer
systemctl list-timers 'raspberry-backup*'
```

The backup timer runs nightly at 02:00 with `Persistent=true`. The check timer runs weekly on Sunday at 03:30 with `Persistent=true`.

## What Is Backed Up

Each run creates a root-only staging directory under `/var/lib/raspberry-backup/staging/<timestamp>` and backs it up with Restic. The staging directory contains:

- PostgreSQL globals and per-database custom-format `pg_dump` files.
- Sanitized Kubernetes JSON manifests for namespaces, deployments, services, ingresses, configmaps, PVCs, Argo CD resources, Tekton resources, and related workload resources.
- Backup metadata for audit.

Restic also backs up configured application data paths, `/etc`, selected MicroK8s argument directories, and selected `/home` paths. Regenerable temporary data, logs, and container image caches are excluded by `restic-excludes.txt`.

Kubernetes secrets are exported by default into the encrypted Restic repository because a complete restore requires them. To disable that, set `EXPORT_K8S_SECRETS=false` in `/etc/raspberry-backup/backup.env`.

## Logs And Failures

Logs are JSON lines in `/var/log/raspberry-backup/backup-YYYY-MM-DD.jsonl` and the systemd journal:

```bash
journalctl -u raspberry-backup.service -n 100 --no-pager
journalctl -u raspberry-backup-check.service -n 100 --no-pager
```

The scripts exit non-zero if PostgreSQL dumps fail, Kubernetes is unreachable, Restic fails, credentials are missing or not root-only, or another run already holds `/run/raspberry-backup.lock`.

## Restore Without Overwriting Production

List snapshots:

```bash
sudo /usr/local/sbin/restore.sh list
```

Restore the latest snapshot into an isolated directory:

```bash
sudo /usr/local/sbin/restore.sh restore latest /var/lib/raspberry-backup/restore/test-latest
```

Dry-run Kubernetes manifests against the current cluster:

```bash
sudo /usr/local/sbin/restore.sh apply-k8s --target /var/lib/raspberry-backup/restore/test-latest
```

Plan a PostgreSQL restore into a new database:

```bash
sudo /usr/local/sbin/restore.sh restore-postgres \
  --target /var/lib/raspberry-backup/restore/test-latest \
  --database voiceassistant \
  --target-database voiceassistant_restore_test
```

Execute the PostgreSQL test restore into that new database:

```bash
sudo /usr/local/sbin/restore.sh restore-postgres \
  --target /var/lib/raspberry-backup/restore/test-latest \
  --database voiceassistant \
  --target-database voiceassistant_restore_test \
  --execute
```

The restore script refuses to restore into an existing PostgreSQL database. It does not copy files back into `/etc`, `/home`, or MicroK8s storage. Inspect restored files first, then use explicit `rsync --dry-run` commands before any production copy, for example:

```bash
sudo rsync -aHAXn /var/lib/raspberry-backup/restore/test-latest/etc/ /etc/
sudo rsync -aHAXn /var/lib/raspberry-backup/restore/test-latest/home/azizzakiryarov/ollama-models/ /home/azizzakiryarov/ollama-models/
```

## Disaster Recovery Outline

1. Reinstall Ubuntu/Raspberry Pi OS and MicroK8s.
2. Enable required MicroK8s add-ons such as DNS, hostpath storage, ingress, cert-manager, and MetalLB as appropriate for the cluster.
3. Install Restic, jq, OpenSSH client, `backup.sh`, `restore.sh`, credentials, and `backup.env`.
4. Restore a snapshot into `/var/lib/raspberry-backup/restore/<name>`.
5. Reinstall Argo CD and any CRDs needed by the manifests.
6. Run `restore.sh apply-k8s --target <restore-dir>` first as a dry run.
7. Apply manifests only when the dry run is clean:

```bash
sudo /usr/local/sbin/restore.sh apply-k8s --target /var/lib/raspberry-backup/restore/<name> --execute
```

8. Restore PostgreSQL into a new database, verify application behavior, then schedule a maintenance window for any production cutover.
9. Restore file data with explicit, reviewed `rsync` commands. Start with `rsync -n`.

This process intentionally avoids automatic deletion or overwriting of existing application data.
