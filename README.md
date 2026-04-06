# backup-restore-debian-dckr-prtnr

Configuration-focused backup and restore tooling for Debian hosts running Docker Swarm and Portainer stacks.

This project backs up stack deployment definitions and recovery metadata, not application data volumes.

## What This Backs Up

Configuration-only scope:

- Docker and Swarm inventory and metadata (info, version, stack/service/network/config/secret metadata)
- Stack definition files discovered in configured filesystem paths
- Portainer stack definitions exported through the Portainer API (when configured)
- Optional bind-mounted configuration files from explicitly configured paths

## What This Does Not Back Up

This project does not back up runtime application data.

- No generic Docker volume backup
- No full database dumps
- No archive of /var/lib/docker

Service inspect and metadata output are recovery references, not a replacement for original compose files.

## Prerequisites

- Debian host
- Root access
- Docker CLI with access to the local engine/swarm
- restic
- curl
- jq
- systemd
- sshpass (optional, only for non-interactive SSH password auth)

Install dependencies on Debian:

~~~bash
sudo apt update
sudo apt install -y restic docker.io curl jq ca-certificates
# Optional for password-based SFTP auth in automation:
sudo apt install -y sshpass
~~~

## Hetzner Storage Box Example (restic SFTP)

Repository format example:

~~~text
sftp:u123456-sub1@u123456-sub1.your-storagebox.de:/./restic-repo
~~~

Set that as RESTIC_REPOSITORY in the setup script.

Authentication notes:

- RESTIC_PASSWORD protects repository encryption (restic data key)
- SFTP/SSH login to Storage Box is separate authentication
- Recommended for systemd timer: SSH key authentication for root
- Optional password-based automation is supported with RESTIC_SFTP_PASSWORD (uses sshpass and derives SSH user/host from RESTIC_REPOSITORY)

If Portainer uses a self-signed TLS certificate, set PORTAINER_INSECURE_SKIP_VERIFY=true in /etc/backup-restore.env (or install a trusted certificate).

## Quick Start

1. Clone the repository.
2. Run the interactive environment setup.
3. Install the nightly schedule.

~~~bash
sudo ./scripts/setup-env.sh
sudo ./scripts/install-schedule.sh
~~~

The setup script writes runtime variables to /etc/backup-restore.env with mode 600. systemd service execution always loads this file.

## Backup Flow

Run a backup manually:

~~~bash
sudo ./scripts/backup.sh
~~~

Nightly schedule:

- Timer runs daily at 03:00
- Persistent=true ensures missed runs execute after reboot
- RandomizedDelaySec=5m reduces synchronized load

## Restore Flow

Restore requires explicit typed confirmation and never defaults to /. Default target is /restore-output.

~~~bash
sudo ./scripts/restore.sh
~~~

Optional snapshot and target:

~~~bash
sudo ./scripts/restore.sh latest /restore-output
~~~

The script shows available snapshots, prints a warning, and requires typing RESTORE before proceeding.

## Integrity Check and Maintenance

Run repository checks:

~~~bash
sudo ./scripts/check.sh
~~~

With subset data read check:

~~~bash
sudo ./scripts/check.sh --read-data-subset=5%
~~~

Unlock stale locks only when explicitly requested:

~~~bash
sudo ./scripts/check.sh --unlock
~~~

## Portainer API Export

When PORTAINER_URL, PORTAINER_USERNAME, and PORTAINER_PASSWORD are set:

- The backup authenticates to Portainer
- Lists stacks from /api/stacks
- Exports each stack definition from /api/stacks/{id}/file
- Stores stack file content and metadata in the backup workspace

If Portainer API is not configured or unavailable, backup continues with Docker/Swarm metadata and filesystem exports.

## Filesystem Stack Export

STACK_CONFIG_PATHS is a colon-separated list of source directories (for example /opt/stacks:/srv/stacks).

The backup script copies likely stack and configuration files while preserving relative structure per source path where practical.

Patterns include:

- docker-compose*.yml / docker-compose*.yaml
- compose*.yml / compose*.yaml
- .env / .env.*
- *.conf / *.cfg / *.yaml / *.yml

## Schedule Install/Uninstall

Install schedule:

~~~bash
sudo ./scripts/install-schedule.sh
~~~

Uninstall schedule:

~~~bash
sudo ./scripts/uninstall-schedule.sh
~~~

## Environment Variables

See .env.example for complete documentation.

Important: Runtime values must be stored in /etc/backup-restore.env. The setup script creates and updates that file.

## Notifications

If SLACK_WEBHOOK_URL is configured, scripts send a webhook notification on backup/restore/check success or failure.

Optional SLACK_NOTIFY_CHANNEL can be set for payload metadata.

## Security Notes

- /etc/backup-restore.env includes secrets and is created with mode 600
- Run scripts as root only
- Use least-privilege network access for Storage Box and Portainer API
- Treat exported stack files and metadata as sensitive operational data

## Restore Testing Recommendation

Perform periodic test restores to an isolated path (default /restore-output) and verify that stack definitions and metadata are sufficient for your redeployment process.

## Repository Layout

~~~text
.
├── .env.example
├── .gitignore
├── README.md
├── restic-excludes.txt
├── scripts
│   ├── backup.sh
│   ├── check.sh
│   ├── common.sh
│   ├── install-schedule.sh
│   ├── restore.sh
│   ├── setup-env.sh
│   └── uninstall-schedule.sh
└── systemd
	├── restic-docker-backup.service
	└── restic-docker-backup.timer
~~~
