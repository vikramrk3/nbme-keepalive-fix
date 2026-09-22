# nbme-keepalive-fix

A macOS workaround for NBME self-assessments (delivered through `www.starttest.com`)
that keep aborting with:

> `SE=1002` … `Item Loading (...) Navigation was not complete in sufficient time.`

**Tested only with Chrome on macOS.** See [Other browsers](#other-browsers) for what to
expect elsewhere.

Not affiliated with NBME or its test delivery vendor. It does not touch the exam, the
browser, or any exam content. It only changes operating-system TCP keepalive settings.

Note that I detected this bug on Sunday, September 20th. It is an official bug in the NBME serving path. 
I've prepared this git repo to help their developers fix this on the serving side. If you're another test taker that's stumbled upon this, feel free to use it but hopefully the official folk have already pushed a fix! 

## Why this exists

My girlfriend is taking NBME's official Step 2 CK self-assessments (the Comprehensive
Clinical Science Self-Assessment) at home, in Chrome on a Mac, and her exam has a bug.
Every few questions the exam abruptly throws her out of the block and back to the
launch page with the error above. Relaunching resumes the block where it left off, but
each abort costs a minute or more and breaks concentration, and it happened more than a
dozen times in one afternoon. Nothing was wrong with the Mac, the browser, or the
internet connection.

### Diagnosis

The browser is not crashing, and neither is the exam. The exam host silently drops any
connection that has been idle for about two minutes, without telling the browser.
Chrome keeps idle connections for up to five minutes and reuses them, so a click on
Next between roughly two and five minutes after the last page load is sent into a dead
connection. Nothing ever comes back, and after 30 seconds the exam's own load watchdog
gives up and aborts the block.

This was reproduced outside the browser with plain sockets set up the way Chrome sets
up its own: connections to `www.starttest.com` that sat idle for 150 to 270 seconds went
silently dead 8 times out of 8, while identical connections to two other websites, on the
same network during the same minutes, did not. The full evidence is under
[How this was diagnosed](#how-this-was-diagnosed).

### Solution

Change one macOS network setting so that when the Mac's own keepalive probe of an idle
connection goes unanswered, it gives up on that connection within about two seconds
instead of about ten minutes. Chrome then discards the dead connection and reconnects
instead of hanging. On the Mac the exam runs on, in Terminal, before launching the exam:

```sh
curl -fsSLO https://raw.githubusercontent.com/vikramrk3/nbme-keepalive-fix/main/nbme-fix.sh
chmod +x nbme-fix.sh
./nbme-fix.sh on        # asks for your Mac password
```

It takes effect immediately, including for a browser that is already open. `on` lasts
until the next restart; if the exam is tomorrow or someone else will be using the Mac,
use `install` instead so nothing depends on remembering it (see
[Setting up someone else's Mac](#setting-up-someone-elses-mac)). When the exam is over:

```sh
./nbme-fix.sh off       # or just reboot; the setting does not survive a restart
./nbme-fix.sh uninstall # if you used install
```

In practice this took the exam from aborting every one to three questions to running a
whole block cleanly. It shrinks the problem rather than removing it, though: a click
that lands between about 2:05 and 2:20 after the last page load can still fail. See
[What still goes wrong](#what-still-goes-wrong). The real fix belongs to NBME's test
delivery vendor: close idle connections in a way the browser can see.

## Commands

| Command | What it does | Password? |
|---|---|---|
| `./nbme-fix.sh on` | Applies the fix | yes |
| `./nbme-fix.sh off` | Restores the macOS defaults | yes |
| `./nbme-fix.sh install` | Applies the fix now and at every startup, until uninstalled | yes |
| `./nbme-fix.sh uninstall` | Removes the startup job and restores the defaults | yes |
| `./nbme-fix.sh status` | Shows the current values, whether the fix is active, and whether the startup job is installed | no |
| `./nbme-fix.sh test` | About 3 minutes. Opens a Chrome-style idle connection to the exam host and checks that the silent drop now gets detected | no |

`test` makes two anonymous `HEAD /` requests to `www.starttest.com`. It needs Python 3
(`xcode-select --install` if you do not have it). Results: `PASS`, `FAIL` (the fix is off
or not working), or `INCONCLUSIVE` (the connection was not dropped this time).

## Setting up someone else's Mac

For a non-technical test taker, do the setup the night before on their Mac and use
`install`, so a restart (including an overnight macOS update) cannot silently undo it:

```sh
curl -fsSLO https://raw.githubusercontent.com/vikramrk3/nbme-keepalive-fix/main/nbme-fix.sh
chmod +x nbme-fix.sh
./nbme-fix.sh install     # their Mac's password; applies now and at every startup
./nbme-fix.sh test        # ~3 minutes; should end with PASS
```

`test` is the step that proves it works on *that* Mac. After that there is nothing for
the test taker to remember: sleep, closing the lid, moving to a library, restarting,
none of it matters. They only need to use Chrome, the one browser this is tested with.

`install` writes a small launchd job, `/Library/LaunchDaemons/com.nbme-keepalive-fix.plist`,
that runs `sysctl` with the fix values at every startup. `uninstall` removes it and
restores the defaults.

### Leaving it on for weeks

Fine. The two settings only change how quickly an *idle* connection that has stopped
answering keepalive probes is given up on: about 2 seconds instead of about 10 minutes.
Only apps that turn on TCP keepalive themselves are affected (Chrome and other
Chromium browsers, ssh, some chat and sync apps), and the effect is that during a
Wi-Fi hiccup longer than 2 seconds an idle connection is dropped and the app quietly
reconnects. Battery, speed, security and every other app are untouched, and nothing
else on the Mac is modified. Still, run `uninstall` once the exams are done, if only to
leave the Mac as you found it.

## What still goes wrong

The server drops an idle connection at roughly 2:05. Chrome probes its idle connections
every 45 seconds (0:45, 1:30, 2:15), so the earliest anything can notice is the 2:15
probe, and with the fix macOS declares the connection dead at about 2:19. A click that
lands in that gap can still fail. The gap cannot be closed from the Mac's side: the
45-second probe schedule is built into Chrome.

| Time since the exam last loaded something | Without the fix | With the fix |
|---|---|---|
| under ~1:45 | safe | safe |
| ~2:05 to ~2:20 | **likely crash** | **can still crash** |
| ~2:20 to 5:00 | **likely crash** | safe |
| over 5:00 | safe (browser already discarded the connections) | safe |

Practical habit: on a long question, either move on before about 1:50 or wait until
about 2:25 before clicking Next. A Next then Previous hop roughly every 90 seconds also
keeps the connections fresh.

If it does crash, relaunching from the mynbme registration page resumes the block.

## What it changes

Two system-wide settings, until the next reboot (or until `uninstall`, if applied with `install`):

| Setting | macOS default | Fix |
|---|---|---|
| `net.inet.tcp.keepintvl` (ms between keepalive retries) | `75000` | `1000` |
| `net.inet.tcp.keepcnt` (unanswered probes before giving up) | `8` | `2` |

Chrome enables TCP keepalive on its own connections and probes each idle one every
45 seconds. With the defaults, macOS retries an unanswered probe 8 times, 75 seconds
apart, so a dead connection lingers for about 10 minutes, and Chrome reuses idle
connections for up to 5. With the fix, two unanswered probes one second apart are
enough, and the dead connection is gone about 2:19 after it was last used (measured;
the first release's 3 s × 3 gave 2:26).

Side effect: any app that enables keepalive on its own connections (Chrome, ssh, most
chat apps) now drops an idle connection after about 2 seconds of unanswered probes, so
a short Wi-Fi hiccup can make such an app reconnect. Apps that do not enable keepalive
are untouched. Chrome reconnects silently, and for the exam a false drop is harmless:
probes only run on idle connections, and the next click simply opens a new one. Still,
this is meant to be switched on for an exam and off afterwards, not left on permanently.

The first release (same day, earlier) also forced keepalive onto every socket
(`always_keepalive=1`, `keepidle=30000`). That never affected Chrome, which sets its own
45-second idle time, and only widened the side effects. `on` now resets those two to
their defaults; `status` shows `PARTIAL` until you run it.

## Other browsers

Only Chrome on macOS has been tested, and `test` simulates a Chrome connection. What to
expect elsewhere, reasoned from how each browser handles connections rather than
observed:

- **Chromium-based browsers (Edge, Brave, Arc, Opera):** same network code as Chrome,
  same 45-second keepalive and 5-minute connection reuse, so the bug and the fix should
  both apply the same way.
- **Firefox:** by default stops reusing a connection after 115 seconds idle
  (`network.http.keep-alive.timeout`), which is before the server's drop, so it probably
  never hits the bug, with or without this fix.
- **Safari:** unknown. Apple's networking stack manages keepalive and connection reuse
  itself, and it was not measured.
- **Windows and Linux:** the script refuses to run; the equivalent settings live
  elsewhere and have not been tested.

A note on why keepalive matters at all: connections that do not use keepalive received
a clean close from the server at about 130 seconds and would simply reconnect. The
silent drop only affected connections that were sending keepalive probes, which is what
browsers do.

## How this was diagnosed

Observed on 2026-09-20 during a Comprehensive Clinical Science self-assessment in
Chrome on macOS, over a healthy network (no packet loss to the router or to the exam
host, clean Wi-Fi link stats, no VPN or proxy):

- Every failure carried the same driver error, `SE=1002`, raised by the exam's
  30-second load watchdog. The question frame's scripts had never started, so the
  response for the next question never arrived.
- Packet counters showed the browser reusing connections that had been idle for
  3 to 4 minutes, sending the request, getting zero bytes back, and retransmitting
  until the watchdog fired. Pings to the same server and new connections worked
  during those same seconds.
- Reproduced outside the browser with plain sockets configured like Chrome's
  (TCP keepalive, 45 s): idle 150 to 270 s, connections to `www.starttest.com` went
  silently dead 8 out of 8 times. Same test, same network, same minutes:
  `www.cloudflare.com` stayed alive 5 of 5 and `www.microsoft.com` closed cleanly 5 of 5.
  So it is not the Mac, the browser, extensions, Wi-Fi, the router or the ISP.
- Sockets with no keepalive at all received a clean reset from the server at about
  130 s. The silent drop only happens to connections that use TCP keepalive, which
  browsers do.
- With retries tightened, the same Chrome-style sockets were detected as dead instead
  of hanging: at 2:26 with 3 s × 3 (first release) and 2:19 with 1 s × 2 (current),
  measured 2026-09-21.

The proper fix belongs to the exam host: close idle connections with a reset the client
can see, or tolerate a stalled request instead of aborting the exam.

## Development

```sh
./tests/run_tests.sh
```

The tests replace `sysctl`, `sudo` and `uname` with stubs on a private `PATH`, so they
never touch real settings and never ask for a password. One test makes a short live
probe of the exam host and is skipped when offline.

## License

MIT
