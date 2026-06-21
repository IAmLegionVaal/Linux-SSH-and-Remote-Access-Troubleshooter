# Linux SSH and Remote Access Troubleshooter

A Linux support toolkit for diagnosing OpenSSH server, client, authentication, permission and connectivity problems and applying selected guarded repairs.

## Diagnostic script

Local server audit:

```bash
chmod +x src/ssh_remote_access_troubleshooter.sh
sudo ./src/ssh_remote_access_troubleshooter.sh
```

Test connectivity to a remote host:

```bash
sudo ./src/ssh_remote_access_troubleshooter.sh \
  --target server.example.com \
  --port 22 \
  --user technician
```

The diagnostic script reviews OpenSSH availability, service state, effective policy, permissions, listening ports, authentication failures, DNS, routing and remote TCP connectivity. It produces text, CSV and JSON output.

## Repair script

Preview the standard server repair:

```bash
chmod +x src/ssh_remote_access_repair.sh
sudo ./src/ssh_remote_access_repair.sh --repair --dry-run
```

Back up SSH configuration, repair standard server permissions, create missing host keys, validate the configuration, enable SSH and restart the service:

```bash
sudo ./src/ssh_remote_access_repair.sh --repair
```

Repair one user's SSH directory and authorised-key permissions:

```bash
sudo ./src/ssh_remote_access_repair.sh \
  --fix-user-permissions technician
```

Run one explicit service action:

```bash
sudo ./src/ssh_remote_access_repair.sh --service-action reload
sudo ./src/ssh_remote_access_repair.sh --service-action reset-failed
```

Other server actions include `--fix-server-permissions` and `--generate-host-keys`. Use `--yes` for non-interactive confirmation and `--output DIR` to choose the evidence directory.

## What the repair does

- Detects `sshd.service` or `ssh.service` on a systemd host.
- Requires root for real changes and returns a distinct privilege exit code.
- Creates a protected archive of `/etc/ssh` before server configuration or host-key repairs.
- Corrects standard ownership and permissions on the SSH configuration tree and host keys.
- Generates only missing host keys with `ssh-keygen -A`.
- Can repair ownership and permissions for one existing non-system user's `.ssh` directory.
- Validates configuration with `sshd -t` before service changes and again afterward.
- Captures before-and-after service, policy, permission, socket and journal evidence.
- Supports dry-run, confirmation controls, action logs and clear exit codes.

## Safety and limitations

Keep an existing remote session or console path available until verification succeeds. The repair does not change authentication policy, firewall rules, accounts, passwords or SSH key contents. Backup archives can contain private host or user keys and are created with restrictive permissions; store and delete them securely.

## Requirements

- Bash 4+
- systemd for server-service actions
- OpenSSH server tools for server repairs
- Root privileges for actual repair actions

## Author

Dewald Pretorius — L2 IT Support Engineer
