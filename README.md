# Linux SSH and Remote Access Troubleshooter

A read-only Bash toolkit for diagnosing OpenSSH server, client, authentication, permissions, firewall, listening-port, and connectivity problems.

## Purpose

This project helps support engineers collect repeatable evidence for SSH incidents without restarting services or modifying access controls.

## Checks performed

- OpenSSH client and server package availability
- `sshd` service state, enablement, and recent journal events
- Effective server configuration from `sshd -T`
- Root login, password authentication, public-key authentication, and allowed-user settings
- SSH configuration, host-key, `.ssh`, and `authorized_keys` permissions
- Listening sockets and firewall context
- Authentication failures and invalid-user events
- DNS, route, TCP port, host-key scan, and client configuration tests for an optional target
- Text, CSV, and JSON output

## Usage

Local server audit:

```bash
chmod +x src/ssh_remote_access_troubleshooter.sh
sudo ./src/ssh_remote_access_troubleshooter.sh
```

Test connectivity to a remote host:

```bash
sudo ./src/ssh_remote_access_troubleshooter.sh --target server.example.com --port 22 --user technician
```

## Safety

The toolkit never changes `sshd_config`, keys, firewall rules, accounts, permissions, or services. It does not attempt password authentication or brute-force credentials.

## Privacy

Reports may contain usernames, hostnames, IP addresses, public-key fingerprints, and access-policy information. Review output before sharing.

## Requirements

- Bash 4+
- OpenSSH client tools
- Root privileges for complete server log and permission evidence

## Validation ideas

- Working SSH server
- Closed TCP port
- DNS failure
- Incorrect `.ssh` permissions
- Disabled password authentication
- Missing OpenSSH server package

## Author

Dewald Pretorius — L2 IT Support Engineer
