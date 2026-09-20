# Omarchy EvilMaid Watch (EMW)

Physical-access detection for an Omarchy/Arch laptop. When someone opens the
lid, wakes the machine, plugs in a USB device, or fails at your lock screen,
EMW photographs whoever is in front of the camera, records an incident, and
tells you about it — on the machine and on your phone.

Physical access — the "evil maid" attack — is one of the hardest threats to
defend against, and the realistic goal is not prevention but **detection with
evidence**: knowing it happened, when, and having a photo.

Built and tested on an Apple Silicon MacBook Air running Asahi/Omarchy.

## Threat model

**What it detects.** Someone physically interacting with your laptop while you
are not at it: opening the lid, waking it, guessing at the lock screen, or
attaching a USB device.

**What it does not do.**

- It does not stop an attacker. It records one.
- It does not defend against an attacker who already has root. Root can stop
  the units and remove the evidence, `chattr -a` included.
- It does not protect against an attacker who takes the machine away. Evidence
  lives locally; the remote alert is what survives that, so configure one.
- It is not anti-theft or device tracking.

The camera LED lights during capture. That is hardware-wired on Apple silicon
and cannot be suppressed — and it is wanted: a visible deterrent, and a sign to
you that the shutter fired.

## How an incident works

```
trigger ──► debounce ──► capture ──► lock state ──► grace ──► verdict ──► outputs
 lid                     photo       locked?       wait for            events.log
 resume                  (~3s)                     trusted             toast
 faillock                                          unlock              telegram/ntfy
 usb                                                                   root hooks
 manual
```

1. **Trigger.** One of five sources fires (see below).
2. **Debounce.** Triggers within `DEBOUNCE_SECONDS` coalesce into one incident.
   Opening the lid after a suspend genuinely fires both the lid watcher and the
   resume unit, so this is required, not an optimisation.
3. **Capture.** A still is taken immediately — before any waiting — so evidence
   exists even if the machine is shut or carried off seconds later.
4. **Lock state and grace.** If the session was locked, EMW waits
   `GRACE_SECONDS` for a *trusted unlock*. You unlocking in time means the
   incident was you. This stands in for a biometric unlock, which Asahi has no
   working fingerprint reader for; if one ever lands, it slots in here as an
   additional trusted-unlock signal rather than replacing this one. The
   grace window is measured from the **trigger**, not from when the lid was
   closed — time spent away with the lid shut does not count.
5. **Verdict.** One of:

   | Verdict | Meaning |
   |---|---|
   | `intruder` | Locked, and nobody unlocked it within the grace window |
   | `benign` | Locked, and you unlocked it in time |
   | `attended` | Not locked, and `ALERT_WHEN_UNLOCKED=false` — you were using it |
   | `unattended` | Lock state could not be determined |

6. **Outputs.** Always the local record; on `intruder`, also a desktop toast, a
   remote alert, and any root hooks you have installed.

## Triggers

| Source | Mechanism |
|---|---|
| `lid` | `lidwatch.py` reads the lid switch from `/dev/input` |
| `resume` | oneshot unit ordered `After=suspend.target` and friends |
| `faillock` | journal watcher matching failed unlocks at the lock screen |
| `usb` | udev rule on `ACTION=="add", SUBSYSTEM=="usb"` |
| `manual` | `omarchy-emw-trigger manual`, for testing |

Enable the subset you want with `TRIGGERS` in the config.

## Install

```bash
git clone https://github.com/<you>/omarchy-evilmaid-watch
cd omarchy-evilmaid-watch
sudo ./install.sh          # idempotent: safe to re-run after an edit
sudo omarchy-emw-setup     # configure Telegram or ntfy alerts
```

`install.sh` deploys to `/usr/local` rather than into the Omarchy checkout, so
`omarchy update` cannot clobber it. It **preserves an existing
`/etc/omarchy/emw.conf`**, so re-running never overwrites your tokens — a
changed default in the template will not reach a config you already have.

## Commands

| Command | Purpose |
|---|---|
| `sudo omarchy-emw-setup` | Configure remote alerts interactively |
| `sudo omarchy-emw-setup set KEY VALUE` | Change one tunable without editing the file |
| `sudo omarchy-emw-show` | Show the latest incident and open its photo |
| `sudo omarchy-emw-trigger manual` | Raise a real incident on demand |
| `sudo omarchy-emw-faillock --simulate` | Test the failed-unlock path without wrong passwords |
| `sudo omarchy-emw-faillock --probe 120` | Print what the watcher would match, firing nothing |
| `sudo omarchy-emw-spool` | Retry queued alerts now |
| `sudo omarchy-emw-prune --dry-run` | Show which evidence has expired, deleting nothing |
| `journalctl -u omarchy-emw -f` | Watch it live |

## Configuration

`/etc/omarchy/emw.conf`, mode 0600 root:root because it holds API tokens.
Parsed, never sourced: a value like `x; rm -rf /` is just an odd string.
Quote values with spaces, no trailing comments on a value line.

**Settings are never migrated forward.** `install.sh` preserves an existing
config — it holds your tokens — and reports any key this version knows that
your config does not, along with the default it is running on. When a change
cannot be expressed as a new key with a safe default, `CONFIG_VERSION` is
bumped and the installer *refuses* rather than reinterpreting what you wrote:

```bash
sudo cp /etc/omarchy/emw.conf /etc/omarchy/emw.conf.bak
sudo ./uninstall.sh --purge-config
sudo ./install.sh && sudo omarchy-emw-setup
```

A security tool inheriting settings across a breaking change is how a machine
ends up armed differently than its owner believes. `--force-keep-config`
overrides the refusal when you need the machine working now.

The settings most worth knowing:

| Key | Default | Notes |
|---|---|---|
| `ENABLED` | `true` | Master switch |
| `TRIGGERS` | `lid,resume,faillock,usb` | Which sources are live |
| `GRACE_SECONDS` | `20` | How long a trusted unlock has to arrive |
| `ALERT_WHEN_UNLOCKED` | `false` | Alert when the machine was not locked |
| `AUTH_FAILURE_THRESHOLD` | `3` | Failed unlocks that make an incident |
| `AUTH_FAILURE_WINDOW` | `120` | …within this many seconds |
| `ALERT_CHANNEL` | `none` | `none`, `telegram`, `ntfy`, `both` |
| `PASSIVE_MODE` | `false` | Log only: no alerts, no hooks |
| `NOTIFY_ON_BENIGN` | `false` | Toast even when it turned out to be you |
| `RETAIN_DAYS` | `7` | Evidence retention: intruder, unattended, undecided |
| `BENIGN_RETAIN_DAYS` | `2` | Evidence retention once it turned out to be you |
| `DEBOUNCE_SECONDS` | `20` | Coalesce window |

`NOTIFY_ON_BENIGN` is off deliberately: a toast for every lid open you make
yourself trains you to dismiss them, and then the one that matters is the one
you swipe away out of habit.

## Evidence

```
/var/lib/omarchy-emw/            0700 root:root
├── events.log                   append-only (chattr +a) one-line-per-event log
├── incidents/<timestamp>-<pid>/
│   ├── photo.jpg                the capture
│   ├── sources                  triggers coalesced into this incident
│   ├── locked-at-trigger        lock state when it fired
│   ├── lock-status.json         raw lock probe output
│   ├── capture.log              camera diagnostics
│   └── verdict.json             incident, verdict, sources, photo, closed
└── spool/                       alerts awaiting delivery
```

`events.log` is `chattr +a` where the filesystem supports it. That stops
non-root tampering; it does **not** stop a root attacker, who can simply
`chattr -a`.

### Retention

The photo is taken *before* the grace period can tell you from an intruder, so
a `benign` incident still holds a picture of you. Those expire on a short clock
(`BENIGN_RETAIN_DAYS`, default 2 days) while real evidence keeps the long one
(`RETAIN_DAYS`, default 7). An incident with no verdict — still running, or cut
short by a power loss — gets the long clock, because deleting evidence over a
crash is the wrong bias. Either setting at `0` keeps that class forever.

This trades away one case worth naming: if someone knew or coerced your
password and unlocked inside the grace window, the verdict is `benign` and that
photo expires early.

Pruning runs from `omarchy-emw-spool.timer` — on a clock rather than only when
a new incident arrives, so the last photo of you does not sit there until
something else happens. Only the evidence directory is removed; `events.log`
keeps the record of every incident permanently.

## Remote alerts

Telegram or ntfy, configured with `omarchy-emw-setup`. If a send fails — which
is exactly what happens when the lid is shut somewhere unfamiliar with no
network — the alert is **spooled** and retried every 120s for up to
`SPOOL_MAX_AGE_HOURS`. The credential is read at send time and never written
into the spool file.

## Hooks

Every executable in `/etc/omarchy/emw-hooks.d` runs as root on an `intruder`
verdict, with `EMW_INCIDENT_DIR`, `EMW_SOURCE` and `EMW_VERDICT` in the
environment. Hooks must be root-owned and not group/world-writable or they are
skipped — this directory runs code as root, so a user-writable hook would be a
straight privilege escalation.

## Uninstall

```bash
sudo ./uninstall.sh                    # stop and remove the software
sudo ./uninstall.sh --purge-config     # also remove /etc/omarchy/emw.conf
sudo ./uninstall.sh --purge-evidence   # also remove /var/lib/omarchy-emw
sudo ./uninstall.sh --purge            # both
```

Config and evidence are kept unless asked for: removing the software should
never be the thing that destroys the photographs it took. Units are stopped
before they are disabled, so nothing keeps watching the lid until reboot.

## Testing

See [docs/testing.md](docs/testing.md). Short version: use
`sudo omarchy-emw-faillock --simulate` rather than typing wrong passwords at
your lock screen. `pam_faillock` locks the account after 10 failures, and
retrying *during* the lockout restarts its 120-second timer — testing the
obvious way can lock you out of your own machine.

## Why this is not an Omarchy plugin

Omarchy plugins are QML that runs inside the long-lived `omarchy-shell`
process. Per Omarchy's own manual, `omarchy plugin add` "never runs anything
from the plugin, never executes an install hook, and never asks for sudo."

EMW is root systemd units, a udev rule, `/dev/input` access, a journal watcher
and root-owned append-only evidence. The plugin mechanism cannot install any of
that, and should not be able to. EMW therefore installs as an ordinary system
service. A bar indicator *would* be a legitimate plugin, and is a possible
companion later — see [docs/architecture.md](docs/architecture.md).

## Requirements

Arch-based system with systemd and Omarchy's `omarchy-lock-password` PAM
service. A V4L2 webcam. Binaries used: `ffmpeg` (capture), `v4l2-ctl` from
`v4l-utils` (device probing), `jq`, `python3`, `curl`, and `logger`. Written
against Hyprland + Quickshell (`omarchy-shell`) for lock state and toasts.

## Status

Pre-release. Working and in daily use on one machine; the trigger paths,
alerting, spool retry and evidence store are all exercised by real and
simulated incidents. Interfaces may still change.
