# Mac Backup Destination Setup

This configures a dedicated Mac user that accepts only key-based SFTP for the Restic repository.

## 1. Enable SSH on the Mac

```bash
sudo systemsetup -setremotelogin on
```

## 2. Create the restricted backup user

Use a strong random password even though SSH password login will be disabled for this user.

```bash
BACKUP_USER=resticbackup
BACKUP_PASS="$(openssl rand -base64 32)"

sudo sysadminctl -addUser "$BACKUP_USER" \
  -fullName "Restic Backup" \
  -password "$BACKUP_PASS" \
  -home "/Users/$BACKUP_USER"

sudo mkdir -p "/Users/$BACKUP_USER/.ssh" "/Users/$BACKUP_USER/restic/raspberrypi"
sudo chown -R "$BACKUP_USER":staff "/Users/$BACKUP_USER/.ssh" "/Users/$BACKUP_USER/restic"
sudo chmod 700 "/Users/$BACKUP_USER/.ssh" "/Users/$BACKUP_USER/restic" "/Users/$BACKUP_USER/restic/raspberrypi"
```

## 3. Install the Raspberry Pi public key

On the Raspberry Pi, create the dedicated key:

```bash
sudo install -d -o root -g root -m 700 /etc/raspberry-backup/ssh
sudo ssh-keygen -t ed25519 -f /etc/raspberry-backup/ssh/raspberry-backup-ed25519 -N '' -C raspberry-backup
sudo chmod 600 /etc/raspberry-backup/ssh/raspberry-backup-ed25519
sudo cat /etc/raspberry-backup/ssh/raspberry-backup-ed25519.pub
```

Append that public key to the Mac user:

```bash
BACKUP_USER=resticbackup
sudo tee -a "/Users/$BACKUP_USER/.ssh/authorized_keys" >/dev/null <<'EOF'
PASTE_RASPBERRY_PI_PUBLIC_KEY_HERE
EOF
sudo chown "$BACKUP_USER":staff "/Users/$BACKUP_USER/.ssh/authorized_keys"
sudo chmod 600 "/Users/$BACKUP_USER/.ssh/authorized_keys"
```

## 4. Restrict the Mac user to SFTP

Edit `/etc/ssh/sshd_config` on the Mac and add:

```sshconfig
Match User resticbackup
    PasswordAuthentication no
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    AllowTcpForwarding no
    X11Forwarding no
    PermitTTY no
    ForceCommand internal-sftp -d /Users/resticbackup/restic
```

Restart SSH:

```bash
sudo launchctl kickstart -k system/com.openssh.sshd
```

## 5. Pin the Mac host key on the Raspberry Pi

Replace `mac.local` with the Mac hostname or static IP.

```bash
sudo install -d -o root -g root -m 700 /etc/raspberry-backup/ssh
ssh-keyscan -H mac.local | sudo tee /etc/raspberry-backup/ssh/known_hosts >/dev/null
sudo chown root:root /etc/raspberry-backup/ssh/known_hosts
sudo chmod 600 /etc/raspberry-backup/ssh/known_hosts
```

## 6. Test SFTP from the Raspberry Pi

```bash
sftp -i /etc/raspberry-backup/ssh/raspberry-backup-ed25519 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/etc/raspberry-backup/ssh/known_hosts \
  resticbackup@mac.local
```

## 7. Restic repository value

Use this in `/etc/raspberry-backup/backup.env` on the Raspberry Pi:

```bash
RESTIC_REPOSITORY='sftp:resticbackup@mac.local:/Users/resticbackup/restic/raspberrypi'
SSH_KEY_FILE='/etc/raspberry-backup/ssh/raspberry-backup-ed25519'
SSH_KNOWN_HOSTS_FILE='/etc/raspberry-backup/ssh/known_hosts'
SSH_PORT='22'
```

The backup scripts pass the dedicated key and known-hosts file to Restic through Restic's SFTP command option.
