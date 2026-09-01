# my-lc

An intuitive front-end for `launchctl`.

Written for people who know Linux and have never quite got to grips with
macOS launch items. If `systemctl` and `/etc/init.d` are second nature but
`bootout`, `kickstart` and `gui/501` are not, this tool is for you: it
gives launchd the vocabulary and the single overview list you already
expect, and `-V` shows you the raw `launchctl` line behind every action, so
you learn the native tool while using this one.

## LaunchDaemon vs LaunchAgent — the whole distinction

A **LaunchDaemon** is a system daemon. It exists from boot, belongs to no
user session, and is started by launchd running as **root** — so it runs as
root unless the plist sets `UserName` / `GroupName`. Its domain is
`system`, and its plists live in `/Library/LaunchDaemons`.

A **LaunchAgent** is simply a per-user, per-GUI-session daemon. It starts
when that user logs in, dies when they log out, runs **as that user**, and
is the only kind that may talk to the window server. Its domain is
`gui/<uid>`, and its plists live in `~/Library/LaunchAgents` (that one
user) or `/Library/LaunchAgents` (every user gets a copy in their own
session).

That is the entire difference: **who owns it, and when it exists.**

Coming from systemd:

| systemd / init.d | my-lc |
|---|---|
| `systemctl list-units` | `my-lc` |
| `systemctl status X` | `my-lc X status` |
| `systemctl start` / `stop` X | `my-lc X start` / `stop` |
| `systemctl restart X` | `my-lc X restart` |
| `systemctl enable X` | `my-lc X enable` |
| `systemctl enable --now X` | `my-lc X enable --now` |
| `systemctl disable X` | `my-lc X disable` |
| `systemctl disable --now X` | `my-lc X disable --now` |
| `systemctl --user ...` | `my-lc --agents ...` |
| `journalctl -u X` | `my-lc X status` — launchd has no journal, so this is the service's own stderr/stdout |
| `/etc/systemd/system` | `/Library/LaunchDaemons` |
| `~/.config/systemd/user` | `~/Library/LaunchAgents` |

`enable` / `disable` / `--now` mean exactly what they mean in systemd:
bare `enable` only arms a service for boot, bare `disable` only stops it
coming back and leaves a running instance alone, and `--now` additionally
starts or stops it. Nothing to relearn.

One genuine difference, in launchd rather than in my-lc: **a disabled
launchd service cannot be started at all.** In systemd, `disable` only
removes the autostart links — you can still `systemctl start` the unit by
hand; refusing that needs `mask`. launchd has no such split: its disabled
flag also blocks `bootstrap`, so `my-lc X start` on a disabled service
fails until you `enable` it. In strength, launchd's `disable` sits between
systemd's `disable` and `mask`, and my-lc says so when you hit it rather
than passing on launchctl's `Could not find service`.

## Why

`launchctl` is precise and almost unusable. Four concrete faults, and what
my-lc does about each:

**1. There is no list.** `launchctl list` shows *loaded* jobs only — so a
disabled or never-bootstrapped service, exactly the thing you are looking
for when something is not running, is invisible. The plist directories,
`launchctl print-disabled` and the running domain are three separate
sources you have to join by hand.
→ my-lc walks the plist dirs first and joins all three into **one table**.

**2. "Enabled" is two orthogonal things sharing one word.** `disable`
writes a flag that survives reboot; `bootout` unloads the current session.
They can disagree, and `launchctl` gives you no way to see that without
diffing two commands.
→ my-lc's **STATE** column names the disagreement directly: `@on` = off
now but on after reload, `@off` = on now but off after reload.

**3. It never tells you *why* a service would run.** RunAtLoad vs
WatchPaths vs StartInterval vs a socket trigger is only in the plist —
which is often mode 0600. Yet it is the first thing you need to know when
a daemon "is not running", because socket- and path-triggered daemons are
*supposed* not to be running.
→ my-lc's **TRIGGER** column, and `waiting` instead of a blank STATUS.

**4. Errors are offstage.** `StandardErrorPath` is a plist key launchd
writes to and never mentions again.
→ my-lc's **ERR** column, and `my-lc <service> status` showing the log
lines added since that service last started.

### What my-lc does *not* claim

launchctl's verb set is badly named, not badly designed. `bootout` really
does mean something different from `kill`, and collapsing everything to
"stop" would lose that. my-lc keeps all three levels but names them so the
difference is visible — see *Verbs* below.

## Verbs — the full launchctl mapping

launchctl is granular and the granularity is real — it is the *names* that
are wrong. `bootout` is a compound of two words, neither of which means
what the compound does. my-lc keeps every distinction and renames it to
what an init.d user already expects.

### Service lifecycle

`<d>` is `system` or `gui/<uid>`. The legacy column is the launchd-1 name
you will find in most existing documentation.

| launchctl | legacy | my-lc | what it actually does |
|---|---|---|---|
| `bootstrap <d> <plist>` | `load <plist>` | `start` | the service becomes active in this boot session |
| `bootout <d>/<L>` | `unload <plist>`, `remove <L>` | `stop` | it becomes inactive and **stays** stopped — until the next reboot |
| `bootout` + `bootstrap` | — | `restart` | stop, then start |
| `enable <d>/<L>` | — | `enable` | arm it for boot — does **not** start it now (→ `@on`) |
| `disable <d>/<L>` | — | `disable` | stop it coming back at boot — leaves it running (→ `@off`) |
| `enable <d>/<L>` + `bootstrap` | `load -w <plist>` | `enable --now` | arm it for boot **and** start it |
| `bootout` + `disable <d>/<L>` | `unload -w <plist>` | `disable --now` | stop it coming back **and** stop it now |
| `kickstart -k <d>/<L>` | `start <L>` | `run` (alias `runnow`) | execute the program **now**, without waiting for its trigger |
| `kill <sig> <d>/<L>` | `stop <L>` | `kill [SIG]` | signal the running process — a KeepAlive service comes straight back |
| — | — | `edit` | open the plist in `$EDITOR`, then check it is still a valid launchd job |
| — | — | `delete` | stop it, disable it, and move its plist to a dated backup (always confirms) |
| — | — | `truncate [err\|out]` | empty its logs to 0 bytes, both streams by default (always confirms) |
| — | — | `undelete` | put a deleted plist back and re-enable it; with no filter, list what can be restored |
| — | `submit ...` | — | write a plist and `start` it instead |

Three levels of permanence: `kill` touches the **process** only ·
`start` / `stop` / `restart` touch **this boot session**, and a stopped
service returns after a reboot · `enable` / `disable` touch the
**persistent flag**, and `--now` applies it to the session as well.

### Two traps in the legacy column

**`launchctl stop` does not stop a service.** Look at the last two rows:
legacy `start` is `kickstart` and legacy `stop` is `kill` — it sends
SIGTERM to the process, so a KeepAlive job is back a second later. That is
my-lc's `kill`. my-lc's `stop` is `unload`.

**`load` / `unload` mean two different things**, depending entirely on
whether whoever wrote the instructions remembered `-w`. `launchctl help`
now says so itself, pointing `load` at "bootstrap | enable" and `unload`
at "bootout | disable". my-lc therefore does **not** accept them as verbs;
typing one is recognised and redirected rather than guessed at:

```
* 'load' is launchd's legacy name and means two different things. Do you mean:
    > 'start'          (launchctl load)      start it now, not enabled at boot
    > 'enable --now'   (launchctl load -w)   start it now, and enable at boot

* 'unload' is launchd's legacy name and means two different things. Do you mean:
    > 'stop'           (launchctl unload)    stop it now, still enabled at boot
    > 'disable --now'  (launchctl unload -w) stop it now, and disable at boot
```

### Inspection — folded into my-lc's two views

| launchctl | my-lc |
|---|---|
| `print <d>/<L>` | `status <service>` — the record view |
| `print-disabled <d>` | feeds the STATE column of my-lc `status` |
| `list` | superseded by plist-first discovery; `my-lc list` |
| `blame <d>/<L>` | folded into `status` |
| `plist <binary>` | read automatically for embedded-plist services |
| `managerpid` / `manageruid` / `managername` | folded into the header when the domain is ambiguous |
| `error <code>` | folded in — launchctl's numeric errors are translated in place |

### Not wrapped — use launchctl directly

These are diagnostics, global knobs or debugger plumbing rather than
service management, and wrapping them would add a name without adding
clarity: `attach`, `debug`, `print-cache`, `print-token`, `procinfo`,
`hostinfo`, `resolveport`, `limit`, `examine`, `config`, `dumpstate`,
`dump-xsc`, `dumpjpcategory`, `reboot`, `bootshell`, `setenv`, `unsetenv`,
`getenv`, `bsexec`, `asuser`, `reload-atf`, `variant`, `version`, `help`.

`-V` echoes the exact launchctl line before running it, so my-lc doubles as
a way to learn the raw commands.

## Where my-lc is smart

- **`start` on a disabled service** fails in launchctl with
  `Could not find service`. my-lc says: it is disabled, `enable` it first.
- **`start` on an already-started service** is a no-op that launchctl
  reports as an error. my-lc names the trigger it is waiting on and points
  at `run`.
- **`kill` on a KeepAlive service** comes straight back — my-lc says so
  before you wonder why nothing happened, and names `stop` as the verb
  that makes it stay down.
- **launchctl's numeric errors** (`Bootstrap failed: 5: Input/output
  error`) are translated to their actual causes.
- **stderr is in the default listing, highlighted** — the line count plus
  when the *last* line was written (`3L last 2026-09-02_0118`; the bare
  timestamp read as either the first or the last error, so it says which).
  The one exception is a service whose stdout is the same file: an error
  cannot be told from ordinary output there, so it reads
  `merged with stdout: 90L` and is left plain rather than raising a false
  alarm.
- **`status <one service>`** shows the log lines added since that service
  last started, not a blind tail.
- **File-system triggers are verified, not just listed.** A `WatchPaths`
  daemon that never fires usually has a watched path that is not there;
  my-lc shows `watch!` in the trigger and names the dead path in the
  record view. It distinguishes *missing* from *cannot tell* — a path
  under an unreadable directory is `?`, never a false `MISSING`. For a
  watched **directory** it states the trap: WatchPaths fires on the
  directory's own contents changing, not on a file inside being edited.
- **Each watched path says when it last changed, and what changed** —
  that change is the event which would have fired the service, so it is
  the first thing you want when asking "why did this run?" or "why
  didn't it?". Every watched path gets its own block:

```
  watches:  /Users/MINE/system/services/ftp/in/scans/            ok dir
              last change 3h12m ago (2026-09-01 17:24:06)
              newest entry: scan_0042.pdf (3h12m ago)
            /some/gone/path                                      MISSING
```
- **The program is checked, not assumed.** A launch item whose program is
  missing, empty, non-executable or unreachable fails with 126/127 and
  launchd says nothing about why. my-lc reports it in the table and explains
  it in the record view — and judges executability for the user the service
  **runs as** (`UserName`, else root for a daemon, else the session user),
  not for whoever happens to be running my-lc.
- **Exit codes are translated** — `FAIL 78 config error`, and in the record
  view `exit 78 = EX_CONFIG: the program rejected its own configuration`.
  `128+N` is reported as death by signal N.
- **"dead since"** — for a failed service, when it last did anything.
  Normally the newest of its log files; for a service with no logs at all,
  launchd records no timestamp, but a `boot`-triggered service that ran and
  is not running failed **at boot**, so the date is recovered from
  `kern.boottime`. "It is broken" and "it has been broken since August" are
  different problems.
- **Moments are timestamps by default** (`2026-08-17_1334`), because a
  timestamp can be lined up against other logs and an age cannot.
  `TIME_FORMAT=relative` switches to `15d9h`; `TIME_FMT` sets the format.
- **Who it runs as** is merged into the status text, and shown only when it
  is *not* the default — a daemon that runs as root and an agent that runs
  as its session user say nothing, but `run 2d1h as _www` tells you the
  plist set `UserName`. `-V` shows it always.
- **Verbs chain**, in the order typed, with a single combined plan and one
  confirmation for the lot: `my-lc <service> truncate restart` empties the
  logs and then restarts, so what you read afterwards is only the new run.
  Declining the prompt cancels the whole chain, not just the verb that
  asked.
- **`delete` is reversible.** The plist is moved to a dated backup with a
  note of where it came from, so `undelete` puts it back exactly there and
  clears the disable that `delete` set. A plist in the Trash that my-lc did
  *not* delete is never offered — installing a launch daemon from a guessed
  location would be reckless.
- **`status` says whether the RUNNING service still matches its plist.**
  launchd keeps the definition it was given at bootstrap; editing the file
  changes nothing until a restart, and nothing tells you they have
  diverged. my-lc diffs the two and shows which side says what:

```
  loaded:    DIFFERS from the plist on disk - restart to apply
             running: argument sleep 300
             on disk: argument sleep 999
```

  `edit` shows the same diff on leaving the editor and then offers exactly
  the steps that service needs — restart to apply it now, enable so every
  boot picks it up, or both — doing nothing without the word `go`.
- **The plist itself is checked.** launchd refuses a plist that is group- or
  world-writable, or that a system daemon does not own as root, and reports
  only `Input/output error` when it does. `status` names the actual problem
  and gives the `chmod`/`chown` to fix it, and also flags invalid XML, a
  missing `Label`, no `Program` at all, and a `Label` that disagrees with
  the filename.
- **Each log says how big it is**, behind its path — `(315L, 25KB)`, or
  just the size once it is too large to count cheaply, or `empty` /
  `does not exist yet`.
- **`status` shows the command line, not just the program** — every
  argument as launchd would run it, quoted where needed:
  `/bin/sh -c "echo hi there"`. `program: /bin/sh` on its own says almost
  nothing.
- **`restart` retries the bootstrap.** `bootout` returns before launchd has
  released the label, so an immediate `bootstrap` can fail with
  `Input/output error` — leaving the service stopped, the opposite of what
  a restart is for. If a start really cannot succeed, my-lc says the service
  is now stopped rather than leaving you to notice.
- **`status` dates the plist itself** — when it was written and whether it
  has changed since. An old plist edited yesterday is a different story
  from one untouched since it was installed.
- **The plan before a destructive action is in plain words**, one bullet per
  step, not launchctl's vocabulary — `- stop it`, `- disable it, so it stays
  off even if its plist comes back`. `-V` adds the exact `launchctl` line
  underneath for anyone who wants it.
- **Every mutating command narrates itself** — `* stopping X ... done` —
  and a step already in the wanted state says `* X is already stopped`
  rather than pretending it did something. `-Q` silences the narration;
  errors and the multi-target plan are never silenced.

## Usage

```
usage: my-lc [OPTIONS] [FILTER ...] [VERB]
```

`my-lc list` shows every **enabled** daemon — the ones that could run or
are running. With no arguments at all, my-lc runs whatever `DEFAULT_COMMAND`
in the config says, which ships as `status` (and `status` with no filter
renders that same list). Any word that is not a verb or an option is a case-insensitive
filter over label, plist path and program; several words are ANDed. A verb
after a filter acts on everything the filter matched, and on more than one
service it prints the plan and stops until you add `--go`.

Service names, `system/<label>`, and absolute `.plist` paths are
interchangeable everywhere.

`--agents` switches from LaunchDaemons to your LaunchAgents. Run as root it
acts on the session of the user logged in at the screen (`$SUDO_UID`, else
the console user) and says which one in the header; `--uid N` overrides.

See `my-lc -h` for the option list and `my-lc --help` for the background.

## Install

Drop `my-lc` in the path. It installs its own zsh completion on first run.
