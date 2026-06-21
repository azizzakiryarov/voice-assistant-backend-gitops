#!/usr/bin/env bash
set -euo pipefail

PI_USER="${PI_USER:-azizzakiryarov}"
PI_HOST="${PI_HOST:-voice-assistant.duckdns.org}"
PI_PORT="${PI_PORT:-2222}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/voice_assistant_pi_ed25519}"
REMOTE_PASSWORD_FILE="${REMOTE_PASSWORD_FILE:-/etc/raspberry-backup/restic-password}"
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-raspberry-pi-restic-password}"
KEYCHAIN_ACCOUNT="${KEYCHAIN_ACCOUNT:-resticbackup}"

mode="${1:---from-pi}"
remote_tmp=""
local_tmp=""

usage() {
  cat <<USAGE
Usage:
  $0 [--from-pi|--manual|--verify]

Modes:
  --from-pi   Read $REMOTE_PASSWORD_FILE from the Pi via SSH/SFTP and save it
              to macOS Keychain. This may ask for the Pi sudo password.
  --manual    Prompt for the Restic repository password locally and save it to
              macOS Keychain. The password is not echoed.
  --verify    Verify that the expected Keychain item exists without printing it.

Environment overrides:
  PI_USER, PI_HOST, PI_PORT, SSH_KEY, REMOTE_PASSWORD_FILE,
  KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT
USAGE
}

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

cleanup() {
  if [[ -n "$local_tmp" ]]; then
    rm -f "$local_tmp"
  fi
  if [[ -n "$remote_tmp" ]]; then
    ssh -i "$SSH_KEY" -p "$PI_PORT" "$PI_USER@$PI_HOST" \
      "rm -f $(shell_quote "$remote_tmp")" >/dev/null 2>&1 || true
  fi
}

verify_keychain_item() {
  security find-generic-password \
    -s "$KEYCHAIN_SERVICE" \
    -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1
}

save_file_to_keychain() {
  if [[ ! -s "$local_tmp" ]]; then
    die "Refusing to save an empty Restic password."
  fi

  log "Saving Restic password to macOS Keychain item: service=$KEYCHAIN_SERVICE account=$KEYCHAIN_ACCOUNT"
  security add-generic-password \
    -a "$KEYCHAIN_ACCOUNT" \
    -s "$KEYCHAIN_SERVICE" \
    -l "Raspberry Pi Restic repository password" \
    -j "Restic password for /Users/resticbackup/restic/raspberrypi" \
    -U \
    -T "" \
    -w < "$local_tmp"

  verify_keychain_item || die "The password was not found in Keychain after saving."
  log "Saved and verified in macOS Keychain."
}

fetch_password_from_pi() {
  require_command ssh
  require_command scp

  if [[ ! -r "$SSH_KEY" ]]; then
    die "SSH key not readable: $SSH_KEY"
  fi

  remote_tmp="/tmp/raspberry-restic-password.$$"

  log "Reading Restic password from the Pi."
  log "If prompted, enter the Pi sudo password in this terminal."

  ssh -tt -i "$SSH_KEY" -p "$PI_PORT" "$PI_USER@$PI_HOST" \
    "sudo install -m 600 -o $(shell_quote "$PI_USER") -g $(shell_quote "$PI_USER") $(shell_quote "$REMOTE_PASSWORD_FILE") $(shell_quote "$remote_tmp")" || return 1

  scp -q -P "$PI_PORT" -i "$SSH_KEY" "$PI_USER@$PI_HOST:$remote_tmp" "$local_tmp" || return 1

  [[ -s "$local_tmp" ]] || return 1
}

prompt_password_locally() {
  local password

  if [[ ! -t 0 ]]; then
    die "--manual must be run from an interactive terminal."
  fi

  printf 'Enter Restic repository password: ' >&2
  IFS= read -r -s password
  printf '\n' >&2

  if [[ -z "$password" ]]; then
    die "Refusing to save an empty Restic password."
  fi

  printf '%s\n' "$password" > "$local_tmp"
  unset password
}

case "$mode" in
  --from-pi)
    ;;
  --manual)
    ;;
  --verify)
    require_command security
    if verify_keychain_item; then
      log "Restic password exists in macOS Keychain: service=$KEYCHAIN_SERVICE account=$KEYCHAIN_ACCOUNT"
      exit 0
    fi
    die "Restic password is not saved in macOS Keychain: service=$KEYCHAIN_SERVICE account=$KEYCHAIN_ACCOUNT"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "Unknown mode: $mode"
    ;;
esac

require_command security
local_tmp="$(mktemp -t raspberry-restic-password.XXXXXX)"
chmod 600 "$local_tmp"
trap cleanup EXIT

case "$mode" in
  --from-pi)
    if ! fetch_password_from_pi; then
      log "Could not read the password from the Pi."
      log "Run this instead if you know the Restic repository password:"
      log "  $0 --manual"
      exit 1
    fi
    ;;
  --manual)
    prompt_password_locally
    ;;
esac

save_file_to_keychain
