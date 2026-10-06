# Security policy

## Supported versions

CellKeeper is pre-release software. Only the latest commit on `main` is
supported; fixes are not backported.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately in either of these ways:

- GitHub's private vulnerability reporting: "Report a vulnerability" on the
  [Security tab](https://github.com/SaltedTan/CellKeeper/security);
- email to **seanthz6889@gmail.com** with "CellKeeper security" in the
  subject.

Please include affected versions or commits, reproduction steps, and the
impact you expect. We aim to acknowledge reports within 7 days and to agree a
disclosure timeline with you.

## Scope and threat model

CellKeeper runs as an ordinary, App-Sandboxed user application with no
privileged helper. It reads battery telemetry through public and allowlisted
read-only interfaces, and never writes to hardware itself.

Its only control is opt-in and experimental. With the **macOS Charge Limit**
backend selected, it changes macOS's own Charge Limit (80–100%) by running
the user's "CellKeeper Set Charge Limit" shortcut with Apple's `shortcuts`
command-line tool. It confirms each change with `pmset -g battlimit`, which is
read-only and always run with those fixed arguments. It keeps a record of the
user's own limit in a file in its container, so that it can restore that
limit. The other backends change nothing.

Issues we especially want to hear about:

- anything that lets CellKeeper change charging or hardware state other than
  macOS's Charge Limit through the user's shortcut, or set any Charge Limit
  other than the user's own while another backend is selected (restoring the
  user's own limit at launch is intended);
- anything that makes CellKeeper run a command other than `shortcuts list`,
  `shortcuts run` with the user's shortcut and a number from 80 to 100 as
  input, and `pmset -g battlimit`, or pass them other arguments;
- reporting a simulated or unconfirmed change as applied, or not giving back
  the user's own Charge Limit when CellKeeper says it has;
- a malformed or tampered record file that makes CellKeeper set a limit the
  user did not choose, or crash;
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
