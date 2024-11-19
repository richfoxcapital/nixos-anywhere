#!/usr/bin/env bash

set -uex -o pipefail

if [ "$#" -ne 5 ]; then
  echo "USAGE: $0 NIXOS_SYSTEM TARGET_USER TARGET_HOST TARGET_PORT IGNORE_SYSTEMD_ERRORS" >&2
  exit 1
fi

NIXOS_SYSTEM=$1
TARGET_USER=$2
TARGET_HOST=$3
TARGET_PORT=$4
IGNORE_SYSTEMD_ERRORS=$5
shift 3

workDir=$(mktemp -d)
trap 'rm -rf "$workDir"' EXIT

sshConfigFile="$workDir/ssh_config"
cat >"$sshConfigFile" <<EOF
Host $TARGET_HOST
    User $TARGET_USER
    Port $TARGET_PORT
$(echo "$SSH_OPTIONS" | jq -r 'to_entries[] | "    \(.key) \(.value)"')
EOF

set +x
if [[ -n ${SSH_KEY+x} && ${SSH_KEY} != "-" ]]; then
  sshPrivateKeyFile="$workDir/ssh_key"
  # Create the file with 0700 - umask calculation: 777 - 700 = 077
  (
    umask 077
    echo "$SSH_KEY" >"$sshPrivateKeyFile"
  )
  unset SSH_AUTH_SOCK # don't use system agent if key was supplied
  echo "    IdentityFile ${sshPrivateKeyFile}" >>"$sshConfigFile"
fi
set -x

try=1
until NIX_SSHOPTS="-F $sshConfigFile" nix copy -s --experimental-features nix-command --to "ssh://$TARGET_HOST" "$NIXOS_SYSTEM"; do
  if [[ $try -gt 10 ]]; then
    echo "retries exhausted" >&2
    exit 1
  fi
  sleep 10
  try=$((try + 1))
done

switchCommand="nix-env -p /nix/var/nix/profiles/system --set $(printf "%q" "$NIXOS_SYSTEM"); /nix/var/nix/profiles/system/bin/switch-to-configuration switch"
if [[ $TARGET_USER != "root" ]]; then
  switchCommand="sudo bash -c '$switchCommand'"
fi
deploy_status=0
# shellcheck disable=SC2029
ssh -F "$sshConfigFile" "$TARGET_HOST" "$switchCommand" || deploy_status="$?"
if [[ $IGNORE_SYSTEMD_ERRORS == "true" && $deploy_status == "4" ]]; then
  exit 0
fi
exit "$deploy_status"
