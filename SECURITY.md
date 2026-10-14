# Security policy

Foxlume Query stores database and SSH credentials and connects to servers on your behalf, so security reports
matter a lot.

## Reporting a vulnerability

Please do **not** open a public issue. Use GitHub's private vulnerability reporting instead: on the repository page,
open **Security › Report a vulnerability**. Include the version or commit, the steps to reproduce, and what an
attacker could do.

You should get a first answer within a week. Fixes are released as soon as they are ready, and the report is credited
unless you ask otherwise.

## Supported versions

Only the latest commit on `main` gets security fixes while the project is in alpha.

## How credentials are handled

- Passwords are stored in the macOS Keychain (service `com.foxlume.query.connection`), never in the connection file.
- In portable mode (`FOXLUME_DATA_DIR`), passwords are stored in `credentials.json` inside that folder with
  permissions `0600`.
- SSH tunnels use the system `ssh`; host keys are checked against a known-hosts file kept in the app's data folder.
- The app sends no telemetry and makes no network connections other than the ones you configure.
