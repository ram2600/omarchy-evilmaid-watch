# Demo video — shot script

A phone-filmed demo of the tool catching someone at a locked laptop. Aim for
**60–75 seconds** finished, filmed horizontally at 1080p so it embeds cleanly in
the README and the release.

The whole point is that this is a *physical* attack, so film it physically:
hands on the machine, the camera LED lighting, then the alert on a phone. A
screen recording cannot show any of that.

---

## Pre-flight

Confirm the settings the timing depends on:

```bash
sudo grep -E '^(GRACE_SECONDS|CAPTURE_PHOTO|ALERT_CHANNEL|NOTIFY_ON_BENIGN|TRIGGERS)=' /etc/omarchy/emw.conf
```

Wanted for filming: `GRACE_SECONDS=20`, `CAPTURE_PHOTO=true`,
`ALERT_CHANNEL=telegram`, `NOTIFY_ON_BENIGN=false`, and `lid` in `TRIGGERS`.

**The one real problem: the alert lands on the phone you are filming with.**
Pick one:

| Option | How |
|---|---|
| **Two devices** (best) | Telegram on a tablet or second phone, propped next to the laptop and in frame |
| Two takes | Film the laptop, stop, then film the phone screen as the alert arrives |
| Screen-share | Telegram Desktop on another computer, filmed alongside |

Also before rolling: good light on the laptop's camera bezel so the LED reads on
video, a clean desk, and **close every window with anything private in it** — the
machine is on camera.

Use the **lid** trigger, not `wake` or `boot`. Lid fires within about three
seconds of opening, while `wake` needs the machine idle for 150s first and `boot`
needs a two-minute wait.

---

## Act 1 — the intruder (the hero shot)

Timing from the moment the lid opens:

| Clock | What happens |
|---|---|
| t=0 | Lid opens, incident raised |
| t+2 to t+3 | **Camera LED lights, photo taken** |
| t+20 | Grace expires, verdict `intruder` |
| t+21 | Toast appears on the locked screen |
| t+22 | Telegram arrives with the photo |

Shot list:

| # | Length | Framing | Action |
|---|---|---|---|
| 1 | 4s | Wide, whole desk | The laptop sits closed. Nobody in frame. Establishes the scene |
| 2 | 3s | Wide | A hand enters frame and opens the lid |
| 3 | 4s | **Close on the camera bezel** | The LED lights. Hold on it — this is the moment the tool exists for |
| 4 | 3s | Over the shoulder | The lock screen, password prompt untouched |
| 5 | 4s | Wide | The hand withdraws; the person walks out of frame. Nobody touches the keyboard |
| 6 | 6s | Medium on the screen | Hold. Toast appears: *Lid opened while locked — Not unlocked within 20s* **with the captured photo in it** |
| 7 | 8s | The second device | Telegram notification arrives. Open it: the photo of whoever opened the lid, with the verdict and trigger |

Shot 6 is the one to get right — the toast carries the photograph, so a single
frame shows detection, evidence and notification at once.

---

## Act 2 — it was you (why it does not cry wolf)

A security audience will immediately ask about false alarms. Answer it on camera,
in about 15 seconds.

| # | Length | Framing | Action |
|---|---|---|---|
| 8 | 3s | Wide | Lid closes, then opens again |
| 9 | 3s | Close on bezel | LED lights again — **the photo is always taken** |
| 10 | 5s | Over the shoulder | You type your password and unlock, well inside 20 seconds |
| 11 | 4s | The second device | Nothing arrives. Hold on a silent phone |

That contrast is the argument: the evidence is captured either way, but you are
only alerted when nobody could unlock it.

---

## Optional technical cut (~15s, for the release page)

Worth having for reviewers, cut after Act 2:

```bash
sudo omarchy-emw-show          # the incident, its verdict, and the photo
journalctl -u omarchy-emw -n 12 --no-pager
```

The journal reads as the whole decision in eight lines: `new incident` →
`locked at trigger: yes` → `photo captured` → `waiting up to 20s` →
`verdict: intruder` → `toast delivered` → `sent via telegram (sendPhoto; photo 100445B)`.

**Redact before publishing:** the hostname in the shell prompt, your Telegram
handle and chat name, and the incident paths if you would rather not show them.
`sudo -E` shells show the prompt — consider `PS1='$ '` for the shot.

---

## What can go wrong on camera

| Symptom | Cause | Fix |
|---|---|---|
| No alert, silent phone | You unlocked inside the grace window | Do not touch the keyboard for a full 20 seconds after opening |
| No LED | `CAPTURE_PHOTO=false`, or camera busy | Close anything using the webcam |
| Toast has no photo | Old version installed | `sudo ./install.sh` — the fix passes a `file://` URI |
| Telegram never arrives | Offline — it is spooled, not lost | Reconnect; it retries every two minutes. Fine behaviour, poor cinema |
| Alert says `attended` | Screen was not locked when the lid opened | Lock it first: the lid trigger only escalates on a locked session |
| Nothing at all fires | Lid open too soon after the last incident | `DEBOUNCE_SECONDS=20` collapses them — wait 20s between takes |

---

## Post

- No narration needed; short captions carry it: *"Laptop locked and closed"* →
  *"Someone opens it"* → *"Photo taken in 3 seconds"* → *"20 seconds, nobody
  unlocks"* → *"Alert, with the photo"* → *"When it is you, nothing is sent"*
- Keep it under 75 seconds. The LED close-up and the toast-with-photo are the two
  shots worth extra seconds; everything else can be tight
- Upload the `.mp4` to the GitHub release, then reference that URL from the
  README's Demo section
- Pull stills from the footage for `docs/media/` rather than staging screenshots
  separately — they will match the video
