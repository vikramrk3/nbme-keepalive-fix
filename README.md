# nbme-keepalive-fix

A macOS workaround for NBME self-assessments (delivered through `www.starttest.com`)
that keep aborting with:

> `SE=1002` … `Item Loading (...) Navigation was not complete in sufficient time.`

Not affiliated with NBME or its test delivery vendor. It does not touch the exam, the
browser, or any exam content. It only changes operating-system TCP keepalive settings.

Note that I detected this bug on Sunday, September 20th. It is an official bug in the NMBE serving path. 
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

Change one macOS network setting so the Mac itself probes idle connections and gives up
on a dead one about ten seconds after its first unanswered probe. Chrome then discards
the dead connection and reconnects instead of hanging. On the Mac the exam runs on, in
Terminal, before launching the exam:

```sh
curl -fsSLO https://raw.githubusercontent.com/vikramrk3/nbme-keepalive-fix/main/nbme-fix.sh
chmod +x nbme-fix.sh
./nbme-fix.sh on        # asks for your Mac password
```

It takes effect immediately, including for a browser that is already open. When the
exam is over:

```sh
./nbme-fix.sh off       # or just reboot; the setting does not survive a restart
```

In practice this took the exam from aborting every one to three questions to running a
whole block cleanly. It shrinks the problem rather than removing it, though: a click
that lands between about 2:00 and 2:30 after the last page load can still fail. See
[What still goes wrong](#what-still-goes-wrong). The real fix belongs to NBME's test
delivery vendor: close idle connections in a way the browser can see.

## Commands

| Command | What it does | Password? |
|---|---|---|
| `./nbme-fix.sh on` | Applies the fix | yes |
| `./nbme-fix.sh off` | Restores the macOS defaults | yes |
| `./nbme-fix.sh status` | Shows the current values and whether the fix is active | no |
| `./nbme-fix.sh test` | About 3 minutes. Opens a browser-style idle connection to the exam host and checks that the silent drop now gets detected | no |

`test` makes two anonymous `HEAD /` requests to `www.starttest.com`. It needs Python 3
(`xcode-select --install` if you do not have it). Results: `PASS`, `FAIL` (the fix is off
or not working), or `INCONCLUSIVE` (the connection was not dropped this time).

## What still goes wrong

The server drops an idle connection at roughly 2:05 and macOS notices at roughly 2:27.
A click that lands in that gap can still fail.

| Time since the exam last loaded something | Without the fix | With the fix |
|---|---|---|
| under ~1:45 | safe | safe |
| ~2:00 to ~2:30 | **likely crash** | **can still crash** |
| ~2:30 to 5:00 | **likely crash** | safe |
| over 5:00 | safe (browser already discarded the connections) | safe |

Practical habit: on a long question, either move on before about 1:50 or wait until
about 2:35 before clicking Next. A Next then Previous hop roughly every 90 seconds also
keeps the connections fresh.

If it does crash, relaunching from the mynbme registration page resumes the block.

## What it changes

Four system-wide settings, until the next reboot:

| Setting | macOS default | Fix |
|---|---|---|
| `net.inet.tcp.always_keepalive` | `0` | `1` |
| `net.inet.tcp.keepidle` (ms) | `7200000` | `30000` |
| `net.inet.tcp.keepintvl` (ms) | `75000` | `3000` |
| `net.inet.tcp.keepcnt` | `8` | `3` |

Chrome already probes idle connections every 45 seconds, but with the defaults macOS
retries a failed probe 8 times, 75 seconds apart, so a dead connection lingers for
about 12 minutes. Chrome reuses idle connections for up to 5. With the fix, three
failed probes 3 seconds apart are enough, and the dead connection is gone about
2.5 minutes after it was last used.

Side effect: every idle TCP connection on the Mac gets probed after 30 seconds, and an
idle connection is dropped after a ~9 second network blip. Apps reconnect on their
own. That is why this is meant to be switched on for an exam and off afterwards, not
left on permanently.

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
- With the fix applied, the same Chrome-style sockets were detected as dead at about
  147 s and failed fast instead of hanging.

The proper fix belongs to the exam host: close idle connections with a reset the client
can see, or tolerate a stalled request instead of aborting the exam.

## Scope

- macOS only. The script refuses to run elsewhere. Windows and Linux use different
  settings and have not been tested.
- Untested alternative: Firefox discards idle connections after 115 seconds by default
  (`network.http.keep-alive.timeout`), which is below the server's drop time, so it
  should avoid the problem without any system change.

## Development

```sh
./tests/run_tests.sh
```

The tests replace `sysctl`, `sudo` and `uname` with stubs on a private `PATH`, so they
never touch real settings and never ask for a password. One test makes a short live
probe of the exam host and is skipped when offline.

## License

MIT
