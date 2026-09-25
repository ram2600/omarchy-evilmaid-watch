# Testing EvilMaid Watch

## Read this first: do not test the lock screen the obvious way

`/etc/pam.d/omarchy-lock-password` ships Arch's default
`pam_faillock deny=10 unlock_time=120`. Typing wrong passwords to test the
failed-unlock trigger spends that budget, and two things make it worse than it
sounds:

- Attempts made **during** a lockout still count, and the 120-second timer runs
  from the *most recent* attempt. Retrying keeps you locked out.
- The lock screen reports a lockout the same way it reports a wrong password,
  so a correct password being rejected looks like you mistyping it.

If it ever stops accepting a password you know is right: **stop typing for two
minutes.** Tallies live in `/var/run/faillock` (tmpfs), so a reboot also clears
them — but waiting is faster than the reboot that testing this cost once.

Use `--simulate` instead. If you do want a live run, type exactly three wrong
passwords — the EMW threshold, well under faillock's ten — then take your hands
off the keyboard.

## `--simulate`

```bash
sudo omarchy-emw-faillock --simulate --dry              # matcher + tally only, no incident
sudo omarchy-emw-faillock --simulate                    # + escalation through the real trigger
sudo omarchy-emw-faillock --simulate --live             # + journald and the deployed daemon
sudo omarchy-emw-faillock --simulate --live --delay 15  # + lock the screen first
```

**Lock the screen, or the alert path is not tested.** This trigger means
"someone failed at the lock screen", so running it against an unlocked session
is a contradiction: the verdict is `attended`, and with the default
`ALERT_WHEN_UNLOCKED=false` there is no toast and no remote alert. That is
correct behaviour and looks exactly like a broken run. `--delay <seconds>`
gives you time to lock the screen before the failures are injected; the
simulation also prints the current lock state up front so a silent run is never
a mystery.

All three start with a matcher self-test over synthetic lines copied from real
journal output, including the cases that must **not** fire:

| Case | Expected |
|---|---|
| Lock screen `pam_unix` authentication failure | fire |
| Lock screen `pam_faillock` lockout notice | fire |
| Lock screen audit `AUDIT1100 … res=failed` | fire |
| `sudo` mistyped password (`pam_unix` form) | ignore |
| `sudo` mistyped password (audit form) | ignore |
| Normal session start | ignore |
| Successful unlock | ignore |
| Lock screen starting up | ignore |

The simulation drives `consume_line` — the same function the daemon's read loop
calls. It is deliberately not a reimplementation of the tally: a test that
reimplements its subject only proves the reimplementation works.

`--live` writes lines tagged `omarchy-emw-simulate` whose text says
`SIMULATED`. They carry the strings the matcher keys on, so the running daemon
reacts exactly as it would to a real failure, but they can never be mistaken
for genuine PAM failures by whoever reads that journal afterwards. It then
waits `GRACE_SECONDS + 20` for the verdict rather than reporting early.

## `--probe`

```bash
sudo omarchy-emw-faillock --probe 120
```

Prints every line the watcher would act on (`MATCH`) and every line merely
mentioning the lock PAM service (`near`), firing nothing. Use it when the
matcher needs to be checked against a distribution or lock screen whose wording
differs.

## The wake trigger

```bash
sudo omarchy-emw-wakewatch --simulate                     # state machine self-test
sudo omarchy-emw-wakewatch --simulate --live --delay 20   # + drive the running watcher
sudo omarchy-emw-wakewatch --probe 300                    # print its decision per line
```

The self-test replays verbatim journal lines through the same `consume_line`
the daemon uses, and the must-not-fire cases matter as much as the rest: shell
startup, a repeated `active`, a 140 ms idle flap, and a shell restart that
happened while the machine was idle.

**The real acceptance test needs a locked screen and patience.** Lock it, then
do not touch the machine for more than 150s (`min(screensaver, lock)`) until
`journalctl -f | grep idle-monitor` shows `idle-monitor: idle`. Wait
`WAKE_MIN_IDLE_SECONDS` more, nudge the trackpad, and leave it at the lock
screen past `GRACE_SECONDS`. Expect `wake: woken after Ns idle` →
`locked at trigger: yes` → `intruder` → toast with photo → Telegram.

Confirm `process-start: wake` is **absent** from that window. That absence is
the proof the original matcher could never have fired.

## The boot trigger

Reboot and log in promptly: expect one incident, `boot: session_seen=yes`,
verdict `benign`, silence. The `boot-wait` file in the incident directory
records which shape it was.

For the unattended path without rebooting, point the trigger at a user with no
seated session (`lib/emw-common.sh` honours `EMW_CONFIG_FILE`):

```bash
sudo install -m600 /etc/omarchy/emw.conf /root/emw-boot-test.conf
sudo sed -i 's/^EMW_USER=.*/EMW_USER=nobody/; s/^BOOT_LOGIN_GRACE_SECONDS=.*/BOOT_LOGIN_GRACE_SECONDS=20/' /root/emw-boot-test.conf
sudo env EMW_CONFIG_FILE=/root/emw-boot-test.conf omarchy-emw-trigger boot
```

## USB at boot

Reboot and confirm `coldplug Ns after boot … ignoring` in the journal with no
incident, then plug a device in while awake and confirm a normal incident.

## Other trigger paths

```bash
sudo omarchy-emw-trigger manual     # full incident, no lock screen involved
```

Lid and resume are best tested for real: lock the screen, close the lid, wait
past `GRACE_SECONDS`. Both firing at once is expected and should produce **one**
incident — the journal will say `coalesced into …`.

## Testing the alert fallback

The spool path is what saves an alert raised with no network. To exercise it,
blackhole the API and send:

```bash
echo "127.0.0.1 api.telegram.org" >> /etc/hosts
sudo omarchy-emw-alert /var/lib/omarchy-emw/incidents/<id> --verdict intruder
# expect: "telegram send failed" then "spooled to …"
```

Then restore `/etc/hosts` and drain:

```bash
sudo systemctl stop omarchy-emw-spool.timer
sudo omarchy-emw-spool     # expect: "sent via telegram", "1/1 delivered"
sudo systemctl start omarchy-emw-spool.timer
```

Two traps, both of which produced false failures the first time:

1. **`nsswitch.conf` puts `resolve` ahead of `files` with `[!UNAVAIL=return]`,**
   so lookups go through systemd-resolved's in-memory copy of `/etc/hosts`.
   `resolvectl flush-caches` empties the DNS cache without forcing a re-read of
   that file, so a send fired immediately after the revert still sees the
   blackhole. Wait until `getent hosts api.telegram.org` returns a real address.
2. **`systemctl start` on an already-running oneshot joins the in-flight run**
   rather than starting a fresh one. If the timer's own pass is mid-flight, its
   result gets reported as yours. Stop the timer for the duration, or call
   `omarchy-emw-spool` directly.

## Verifying the toast photo

The image argument must be a `file://` URI; a bare path is silently dropped by
the notification server. To re-check that on a future Quickshell version, send
one notification each way and read the persisted JSON:

```bash
N=~/.local/state/omarchy/notifications
omarchy-notification-send --image "/path/to.png"        "probe A" "bare path"
omarchy-notification-send --image "file:///path/to.png" "probe B" "file URI"
jq -c '{summary,image,appIcon}' "$(ls -t $N/*.json $N/history/*.json | head -1)"
ls $N/images/
```

A working form leaves a non-empty `image` and a copy in `images/`. On screen,
`NotificationCard.qml` shows the glyph only while the image has not loaded, so
glyph → thumbnail is the load succeeding.


The toast thumbnail is staged outside the 0700 evidence directory, so an
incident should leave a readable copy:

```bash
ls -l /run/omarchy-emw/toast-<incident-id>.jpg   # 0600, owned by the desktop user
```

The directory is mode 0711 — openable by path, not listable — so `ls` of the
directory itself failing is correct behaviour, not an error.
