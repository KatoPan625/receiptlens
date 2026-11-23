# Creates a throwaway "empty Linux server" for the Ansible playbook: a fresh WSL Ubuntu distro
# with nothing on it but an SSH server and one sudo user, reachable from the control distro.
# This stands in for a new VM; the playbook (deploy/ansible) does everything else.
#
#   powershell -File scripts/new-wsl-target.ps1 [-Name rl-target] [-Control Ubuntu] [-Port 2222]
#
# Remove it afterwards with:  wsl --unregister rl-target   (deletes the distro and all its data)
param(
    [string]$Name = 'rl-target',     # distro to create (Ubuntu 24.04)
    [string]$Control = 'Ubuntu',     # distro that runs Ansible; its ~/.ssh/id_ed25519.pub is authorised
    [int]$Port = 2222                # sshd port (WSL distros share one network namespace)
)
$ErrorActionPreference = 'Stop'

$exists = (wsl.exe -l -q) -replace "`0", '' | Where-Object { $_.Trim() -eq $Name }
if (-not $exists) { wsl.exe --install Ubuntu-24.04 --name $Name --no-launch }

$pub = (wsl.exe -d $Control -- bash -c 'cat ~/.ssh/id_ed25519.pub').Trim()
if ($pub -notmatch '^ssh-ed25519 ') { throw "No ~/.ssh/id_ed25519.pub in distro '$Control' (create one with ssh-keygen -t ed25519)." }

# Only the public key crosses over. The deploy user's sudo is password-less because this is a
# disposable test box driven by Ansible; do not copy that to a real server.
$setup = @"
set -eu
id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
echo '$pub' > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys; chmod 600 /home/deploy/.ssh/authorized_keys
echo 'deploy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/deploy; chmod 440 /etc/sudoers.d/deploy
printf '[boot]\nsystemd=true\n[user]\ndefault=deploy\n' > /etc/wsl.conf
export DEBIAN_FRONTEND=noninteractive
command -v sshd >/dev/null || { apt-get update -q; apt-get install -y -q openssh-server; }
mkdir -p /etc/ssh/sshd_config.d
printf 'Port $Port\nPasswordAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-receiptlens.conf
systemctl enable ssh >/dev/null 2>&1 || true
"@
$setup -replace "`r", '' | wsl.exe -d $Name -u root -- bash -s
if ($LASTEXITCODE) { throw "Setup inside $Name failed." }

wsl.exe --terminate $Name | Out-Null   # restart so systemd + the new wsl.conf take effect
# WSL stops an idle distro; a sleeping process keeps it (and sshd) up until `wsl --terminate`.
Start-Process -WindowStyle Hidden wsl.exe -ArgumentList '-d', $Name, '-u', 'root', '--', 'sleep', 'infinity'
Start-Sleep -Seconds 8
wsl.exe -d $Name -u root -- systemctl restart ssh
wsl.exe -d $Control -- ssh-keygen -R "[localhost]:$Port" 2>$null | Out-Null   # a re-created target has a new host key
wsl.exe -d $Control -- bash -c "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -p $Port deploy@localhost 'echo ssh ok: `$(hostname)'"
if ($LASTEXITCODE) { throw "SSH from $Control to $Name on port $Port failed." }
