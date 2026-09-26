# Release notes — draft

Working draft of the GitHub release description for the first public tag.
Everything above the line is notes to ourselves; everything below is the text
that would be pasted into the release.

## Before publishing

- [x] Licence chosen: Apache-2.0 with a `NOTICE` file
- [ ] Decide the tag: `v0.1.0` assumed below
- [ ] Confirm behaviour on a non-Asahi laptop, or scope the claims to Asahi
- [x] USB default settled: on, with `BOOT_GRACE_SECONDS` suppressing the
      coldplug burst at boot that was its only real noise source
- [ ] Screenshot or sample toast + Telegram alert for the release body

---

# EvilMaid Watch v0.1.0 — first release

Physical-access detection for Omarchy laptops. If someone opens your lid, wakes
the machine, plugs in a USB device, or guesses at your lock screen while you are
away, EvilMaid Watch photographs them, records the incident, and tells you —
locally and on your phone.

The "evil maid" attack — someone with brief physical access to your machine —
is one of the threats you cannot really prevent. What you can do is make sure
it never happens *quietly*.

## What it does

- **Seven triggers** — lid, resume from suspend, failed unlock attempts, USB
  device insertion, a wake from idle, power-on, and a manual trigger for
  testing.
- **Photo first, questions later.** The camera fires within ~3 seconds of the
  trigger, before any waiting, so evidence exists even if the machine is shut
  or carried off immediately. The camera LED lights while it does — that is
  hardware-wired on Apple silicon, and it is the point: a visible deterrent.
- **It knows the difference between you and an intruder.** If the session was
  locked and someone unlocks it within the grace window, the incident is
  recorded as benign and no alert is sent. Walk away and it escalates.
- **Alerts that survive being offline.** Telegram or ntfy. An evil-maid event
  is most likely when the machine has no network, so a failed send is spooled
  and retried until it goes through — up to three days. The bot token is read
  at send time and never written into the queue.
- **Evidence you can hand to someone.** A per-incident directory with the
  photo, the lock state, the trigger sources and a `verdict.json`, plus an
  append-only (`chattr +a`) event log.
- **Root hooks.** Anything executable in `/etc/omarchy/emw-hooks.d` runs on an
  intruder verdict, so you can wipe keys, drop the network, or page yourself.

## Install

```bash
git clone https://github.com/ram2600/omarchy-evilmaid-watch
cd omarchy-evilmaid-watch
sudo ./install.sh
sudo omarchy-emw-setup
```

It installs to `/usr/local` and `/etc/omarchy`, so `omarchy update` cannot
clobber it, and re-running never overwrites your config.

**This is a system service, not an Omarchy plugin.** Omarchy plugins are QML
running inside `omarchy-shell` and are installed without sudo; EMW is root
systemd units, a udev rule and `/dev/input` access. A bar indicator plugin may
follow as a companion.

## Testing it safely

`sudo omarchy-emw-faillock --simulate` exercises the whole failed-unlock path —
matcher, tally, escalation, photo, toast, alert — **without typing a wrong
password**. That matters more than it sounds: Arch's `pam_faillock` locks the
account after 10 failures, and attempts during a lockout restart its timer, so
testing this the obvious way can lock you out of your own machine. See
[docs/testing.md](docs/testing.md).

## Known limitations

- Detection, not prevention. It records an intruder; it does not stop one.
- No defence against an attacker who already has root — root can stop the units
  and `chattr -a` the log.
- Developed and tested on one machine: an Apple Silicon MacBook Air running
  Asahi/Omarchy. Lock-state detection and toasts assume Hyprland + Quickshell
  (`omarchy-shell`) and the `omarchy-lock-password` PAM service.
- USB triggering fires on any device add, including your own peripherals.
- Photos are stored unencrypted, readable by root, on the machine an attacker
  is holding. Configure a remote alert if that matters to you.
