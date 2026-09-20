# Architecture

## Components

| Piece | Kind | Role |
|---|---|---|
| `omarchy-emw.service` → `omarchy-emw-watch` → `lidwatch.py` | long-running unit | Reads the lid switch from `/dev/input` |
| `omarchy-emw-resume.service` | oneshot, `WantedBy=suspend.target` | Reports resume from suspend |
| `omarchy-emw-faillock.service` | long-running unit | Follows the journal for failed unlocks |
| `99-omarchy-emw-usb.rules` | udev rule | Fires on USB device add |
| `omarchy-emw-trigger` | per-event process | The state machine: debounce, capture, classify, output |
| `omarchy-emw-capture` | helper | `ffmpeg` still from the first real V4L2 capture device |
| `omarchy-emw-notify` | helper | Root → desktop session bridge for toasts |
| `omarchy-emw-alert` | helper | Telegram/ntfy send, spooling on failure |
| `omarchy-emw-spool` + `.timer` | oneshot every 120s | Drains queued alerts |
| `omarchy-emw-show`, `omarchy-emw-setup` | CLI | Read incidents; configure |

The watchers deliberately do almost nothing: each one detects its event and
execs `omarchy-emw-trigger <source>`. All policy lives in the trigger, so
adding a source is a matter of calling it.

## Why root, and how root is fenced in

Root cannot be dropped: `/dev/input/event0` is `root:input` 0640 and the
desktop user is in neither `input` nor `video`. Adding them to those groups to
run unprivileged would widen the attack surface more than the sandbox narrows
it. So the units stay root and are confined instead:

```
ProtectSystem=strict          ReadWritePaths=/var/lib/omarchy-emw
ProtectHome=read-only         RuntimeDirectory=omarchy-emw (mode 0711)
PrivateTmp=yes                ProtectKernelModules=yes
ProtectControlGroups=yes      ProtectHostname=yes, RestrictRealtime=yes
```

## Integration constraints worth knowing

These are the non-obvious findings that shaped the code. Each one produced a
silent failure first.

**`/run/user/$uid` is read-only inside the units' namespace.** The toast photo
cannot be staged there. `ReadWritePaths=/run/user` does not help: logind mounts
the per-user tmpfs *after* the unit starts, and that submount arrives read-only
regardless of the parent's write permission. The failure is invisible because
`connect()`ing to the session bus socket under the same path still works — a
socket connect is not a filesystem write — so toasts were delivered with the
photo silently missing. Staging now uses `RuntimeDirectory=omarchy-emw`
(`/run/omarchy-emw`, mode 0711, file 0600 owned by the desktop user), which
systemd guarantees writable inside the namespace. Verify with:

```bash
systemd-run --property=ProtectSystem=strict --property=ReadWritePaths=/run/user \
  /bin/sh -c 'findmnt -no TARGET,OPTIONS /run/user/1000'
```

**A system service has no session bus.** `omarchy-notification-send` talks over
`busctl --user`. `omarchy-emw-notify` resolves the seated, `Class=user` login
session — not merely the first row from `loginctl` — and re-enters it as that
user with the right bus address.

**Toasts keep the default app name on purpose.** Only two senders punch through
the user's do-not-disturb mode, and `omarchy-action` is one of them. A tamper
alert that do-not-disturb swallows is worse than none, because it is trusted.

**Failed-unlock matching must be scoped to the lock screen's PAM service.**
Without the `omarchy-lock-password` filter, every mistyped `sudo` password
raises an intruder incident — and mistyping sudo is routine. Audit records
carry no PAM service name, so those are matched on `AUDIT1100` + `res=failed`
and discriminated by `exe=`. journald renders `USER_AUTH` as `AUDIT1100`, not
as the string `USER_AUTH`.

**The lid and the resume unit both fire on one lid open.** `DEBOUNCE_SECONDS`
coalescing is required for correctness, not tidiness — without it every lid
open produced two incidents and two alerts.

**Re-installing needs `systemctl restart`, not `enable --now`.** `--now` only
*starts* a stopped unit, so a re-install left the old long-running watcher
executing the previous `lidwatch.py` while the freshly installed trigger ran
alongside it — a version mismatch that is easy to miss because the trigger is
re-exec'd per event and does pick up changes.

**Dropping to the user: choose on availability, not on exit status.** The
fallback from `setpriv` to `runuser` must be gated on `command -v setpriv`.
Gating on the *exit status of the command setpriv ran* meant every failed poll
during the grace window re-ran the same doomed call through `runuser`, doubling
the work and flooding the journal with PAM sessions.

**`pam_faillock` is the system's, not ours.** Arch ships
`deny=10 unlock_time=120` in `/etc/pam.d/omarchy-lock-password`. EMW's own
threshold (3 failures) is far below it, but attempts made *during* a lockout
still count and push the unlock deadline forward, so a person who keeps
retrying stays locked out indefinitely. This is why `--simulate` exists.

## Alert delivery

An evil-maid event is most likely to happen exactly when the machine has no
network. So `omarchy-emw-alert` treats a failed send as normal: the alert is
written to `/var/lib/omarchy-emw/spool/<incident>.json` and retried by
`omarchy-emw-spool.timer` every 120s until `SPOOL_MAX_AGE_HOURS` expires. A
three-day-old "someone opened your laptop" is noise, and the age bound also
stops an undrainable spool growing without limit.

The bot token is read from the config **at send time** and never written to the
spool file, so the queue never becomes a second place a credential lives.
`flock` around the drain keeps the timer and a manual run from double-sending.

## Retention

`omarchy-emw-prune` runs from the spool timer and expires evidence on two
clocks: `BENIGN_RETAIN_DAYS` for `benign`/`attended`, `RETAIN_DAYS` for
everything else including undecided incidents. The split exists because
capture is unconditional and happens before the verdict, so routine use of your
own laptop accumulates photographs of you at ~105 KB each.

It rides the existing timer rather than firing at the end of an incident:
retention has to be time-based, or the last benign photo would sit there
indefinitely once incidents stopped arriving. The loop refuses any directory
whose name is not `YYYYMMDDTHHMMSSZ-<pid>` before calling `rm -rf`, so a stray
file or a mangled `EVIDENCE_DIR` cannot widen what it deletes.

## Trusted unlock and Touch ID

`TRUSTED_UNLOCK` + `GRACE_SECONDS` stand in for a biometric unlock, which
Asahi cannot offer because there is no working fingerprint reader. The
grace loop asks one question — "did the session become unlocked in time?" — so
a future biometric would enter as an additional signal answering the same
question, not as a replacement for it. The verdict logic would not change.

## A companion shell plugin

A bar indicator — armed/disarmed, last incident, click to open it — is the one
part of this that genuinely belongs in Omarchy's plugin system, since it is QML
inside `omarchy-shell`. It would read state through `omarchy-emw-show` or the
evidence directory rather than being the service itself. Not built yet.

## Data

`verdict.json`, written when an incident closes:

```json
{
  "incident": "20260918T005255Z-32572",
  "verdict": "intruder",
  "locked_at_trigger": "yes",
  "sources": "faillock",
  "photo": "/var/lib/omarchy-emw/incidents/20260918T005255Z-32572/photo.jpg",
  "closed": "2026-09-17T20:53:19-04:00"
}
```
