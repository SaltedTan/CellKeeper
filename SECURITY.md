# Security policy

## Supported versions

CellKeeper is pre-release software. Only the latest commit on `main` is
supported; fixes are not backported.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub's private vulnerability reporting
("Report a vulnerability" on the repository's Security tab).
**[MAINTAINERS: enable private vulnerability reporting, or add an alternative
private contact here, before publishing the repository.]**

Please include affected versions or commits, reproduction steps, and the
impact you expect. We aim to acknowledge reports within 7 days and to agree a
disclosure timeline with you.

## Scope and threat model

CellKeeper currently runs as an ordinary, App-Sandboxed user application. It
only reads battery telemetry through public, read-only interfaces and performs
no hardware control, so its attack surface is small.

Issues we especially want to hear about:

- anything that lets CellKeeper change charging or hardware state in this
  version, or report a simulated action as a real one;
- leaks of device identifiers (serial numbers etc.) into logs, files, or the
  UI;
- weaknesses in the build or CI configuration (for example, workflow
  injection).

Future versions may add a privileged helper. Its design constraints — a
narrow, typed XPC interface with code-signing requirements on both ends, no
general command execution or raw hardware-key access, and automatic
restoration of default charging — are documented in
[docs/research/04-privileged-helper.md](docs/research/04-privileged-helper.md)
and [docs/safety.md](docs/safety.md). Any deviation from those constraints is
a security bug.
