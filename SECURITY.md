# Security policy

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting** on this repository (Security →
Report a vulnerability). That keeps the report private until there is a fix.

If you would rather not use GitHub, email <ram@mastr.net> with `EMW security`
in the subject.

Please include what you would want if you were reading the report: the version
or commit, what you did, what happened, and the relevant journal lines
(`journalctl -u omarchy-emw -u omarchy-emw-faillock -u omarchy-emw-wake`).

This is a one-person project, not a vendor. I will acknowledge a report as soon
as I see it and tell you honestly whether and when I expect to fix it — there is
no service-level promise behind that.

## Scope

In scope, and most valuable:

- **A way to defeat detection quietly** — anything that stops an incident being
  recorded, or stops an alert leaving the machine, without leaving a trace. That
  is the failure this tool cannot tolerate, because a silent failure looks
  exactly like nothing having happened.
- **Privilege escalation** from the desktop user to root through EMW: the units
  run as root, run hooks as root, and read a config file that is parsed rather
  than sourced precisely because of this.
- **Evidence tampering or destruction** by a non-root local user.
- **Leaking the alert credentials** (Telegram bot token, ntfy token) into the
  process table, the journal, the spool, or an incident directory.
- **A false negative in the verdict logic** — anything that makes an intruder
  incident resolve as `benign` or `attended`.

Known and accepted, so not vulnerabilities in themselves:

- **Root can defeat everything.** An attacker who already has root can stop the
  units, remove the evidence and clear the append-only attribute. Stated in the
  README; the mitigation is that the alert leaves the machine.
- **The camera LED lights during capture.** Hardware-wired on Apple silicon, and
  intentional — it is a deterrent, not a leak.
- **Evidence is unencrypted at rest**, readable by root, on the machine an
  attacker is holding. Tracked on the roadmap; configure a remote alert if that
  matters to you.
- **It detects rather than prevents.** It will not stop anyone.
