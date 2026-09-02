#!/bin/dash
# my-lc — an intuitive front-end for launchctl.
#
# Lists, inspects and controls macOS launch items (LaunchDaemons and
# LaunchAgents) with the vocabulary an init.d/systemd user already has.
# See README.md for the full launchctl mapping and the rationale.

SCRIPT_NAME=my-lc
# Identity is the BUILD ID: a hash of this file's own bytes, computed at
# runtime. It is always correct and needs nothing remembered, so it is what
# two copies are compared on.
# SCRIPT_COMMIT is optional provenance, baked in by '--stamp-version' before
# a deploy so a binary can be traced back to a commit. It is deliberately
# NOT authoritative: it is stamped by hand and goes stale silently if the
# file is edited afterwards.
SCRIPT_VERSION="v1.0.2"
SCRIPT_COMMIT="cb91164"
VERSION="$SCRIPT_VERSION"

# --- runtime flags -----------------------------------------------------
QUIET=0
VRB=0
DBG=0
DEEPDBG=0
DBG_LOG=
GO=0
NOW=0
UID_OVERRIDE=
CONFIG_OVERRIDE=
SCOPE=                    # daemons | agents | both   (empty => config)
FILTER_STATE=             # enabled | disabled | all  (empty => config)
APPLE_MODE=               # exclude | only | include  (empty => derived)
WANT_RUNNING=0
WANT_FAILED=0
WANT_STDERR=0
WANT_STDOUT=0
VERB=
VERBS=
TRUNC_WHAT=both
WANT_VERSION=0
WANT_STAMP=0
KILLSIG=TERM
FILTERS=
TESTS=0
TESTS_SCOPE=agents
COMPLETE=0
COMPLETE_VERB=

# --- config defaults (every one of these is overridable in the config) --
DEFAULT_COMMAND=status
DEFAULT_FILTER_STATE=enabled
DEFAULT_SCOPE=daemons
ALL_MEANS=non-apple
DAEMON_DIRS="/Library/LaunchDaemons /System/Library/LaunchDaemons"
AGENT_DIRS=
STATE_DIR=
ERR_TAIL=10
BIG_DELTA=1048576
BOOTSTRAP_TRIES=3
WIDTH_LABEL=auto
COLOR=auto
EDITOR_CMD=""
DELETE_MODE=backup
TIME_FORMAT=absolute
TIME_FMT="%Y-%m-%d_%H%M"

# --- internal ----------------------------------------------------------
# Internal record format. Tab-separated, with an explicit marker for an
# empty field, because BOTH of the shells this script may run under get one
# half of the problem wrong:
#   - tab is IFS whitespace, so 'read' collapses a run of tabs into one
#     delimiter and silently drops an empty field, shifting every column
#     after it (dash and bash alike);
#   - a control character such as \001 in IFS splits correctly in dash but
#     is silently STRIPPED by bash 3.2, which is what /bin/sh is on macOS.
# Tab plus a never-empty marker is the one scheme both agree on, so this
# keeps working if anyone runs the script as 'sh my-lc' rather than
# through the shebang.
FS1=$(printf '\t')
EM=$(printf '\037')
DB=                       # tsv of discovered services
TMPD=
DOMAIN=                   # resolved acting domain, e.g. system or gui/501
DOMAIN_UID=
EXITCODE=0
CONFIRMED=0
ABORT_CHAIN=0

usage_short() {
  cat <<EOF
usage: $SCRIPT_NAME [OPTIONS] [FILTER ...] [VERB]

  FILTER   any word that is not a verb or an option: a case-insensitive
           substring matched against the label, the plist path and the
           program path. Several words are ANDed. A .plist path, a bare
           label and system/<label> are interchangeable.
  VERB     status (default) | list | start | stop | restart | run | kill
           | enable | disable | edit | delete | truncate [err|out]
           | undelete            (recognised in any position)
           Verbs CHAIN and run in the order typed, with one confirmation
           for the lot:  my-lc <service> truncate restart

  status   one match -> the record view; otherwise the table
  list     always the table
  start    make it active in this boot session
  stop     make it inactive; it stays stopped until the next reboot
  restart  stop, then start
  run      execute the program NOW, without waiting for its trigger
  kill     signal the running process (default TERM; 'kill HUP' to pick)
  enable   arm it for boot; add --now to also start it
  disable  stop it coming back at boot; add --now to also stop it now
  edit     open the plist in $EDITOR, then check it is still valid
  delete   stop it, disable it, and move its plist aside (always confirms)
  truncate empty its logs to 0 bytes. 'truncate err' or 'truncate out' to
           pick one; both by default
  undelete put a deleted plist back and re-enable it. With no filter, list
           what can be restored

  --enabled          only services that could run or are running (default)
  --disabled         only services that are switched off
  --all              no state filter
  --apple            ONLY Apple/System services (excluded by default)
  --with-apple       add Apple services to the selection
  --running          only services with a live process
  --failed           only services whose last exit code was non-zero
  --stderr           only services defining StandardErrorPath
  --stdout           only services defining StandardOutPath
  --agents           act on LaunchAgents (gui/<uid>) instead of daemons
  --both             daemons and agents together, with a DOMAIN column
  --uid N            which gui domain; default is the logged-in user
  --now              with enable/disable: also apply it to this session
  --go               carry out a multi-target action without asking
  -Q, --quiet        silence progress narration (never errors)
  -V, --verbose      echo each launchctl command before running it
  -D, --debug [PATH] debug diagnostics (implies -V)
  -DD, --deepdebug   full shell trace (implies -D)
      --config FILE  use FILE as config, bypassing the search
      --create-config [FILE]
                     print the default config to stdout, or write it to FILE
      --run-tests [agents|daemons]
                     run the built-in self-tests
      --version      print the version and the exact build it came from
      --stamp-version
                     optional: record the current git HEAD sha in this file
                     as provenance. The build id above identifies the file
                     on its own; this only adds "which commit was it".
  -h                 this short usage
      --help         full help: states, triggers, the launchctl mapping
EOF
}

usage() {
  usage_short
  cat <<'EOF'

STATE — three independent truths in one column
  on      not disabled and loaded — the normal healthy state
  @on     not disabled but NOT loaded: inactive now, on after a reload
  off     disabled and not loaded
  @off    disabled but still loaded: active now, off after a reload
  orphan  loaded, but no plist on disk
  ("enabled" means on or @on: the service could run, or is running.)

TRIGGER — why it would run, read from the plist
  boot     RunAtLoad            keep     KeepAlive
  every<N> StartInterval        cal      StartCalendarInterval
  watch    WatchPaths           queue    QueueDirectories
  sock     Sockets              xpc      MachServices
  login    LimitLoadToSessionType        manual  none of the above
  ERR is the service's own stderr: the line count and WHEN THE LAST line
  was written. Any non-empty stderr is highlighted. The exception is a
  service whose stdout is the same file - an error cannot be told apart
  from ordinary output there, so it reads 'merged with stdout: NNL' and is
  left plain.

  A trailing ! means a watched path is missing — usually why a watch
  service never fires. A ? means the plist could not be read (rerun as
  root). MISSING and ? are never conflated: a path under an unreadable
  directory is ?, never a false MISSING.

STATUS — whatever is relevant for that kind of service
  run 4d2h pid 1869   running, with uptime
  FAIL 127 x3         last exit code, run count
  ok 12x              exited cleanly
  every 3600 / cal    a timer that has not run yet
  waiting             armed on a socket, path or XPC name
  'as <user>' is appended only when it differs from the default for its
  scope (daemons run as root, agents as the session user). -V always shows
  it, and adds the OUT column, the plist path and the program.

VERBS — the launchctl mapping (-V echoes the real command)
  launchctl                          legacy              my-lc
  bootstrap <d> <plist>              load <plist>        start
  bootout <d>/<L>                    unload <plist>      stop
  bootout + bootstrap                --                  restart
  enable <d>/<L>                     --                  enable
  disable <d>/<L>                    --                  disable
  enable + bootstrap                 load -w <plist>     enable --now
  bootout + disable                  unload -w <plist>   disable --now
  kickstart -k <d>/<L>               start <L>           run
  kill <sig> <d>/<L>                 stop <L>            kill

  enable/disable change the persistent flag and nothing else, exactly as
  in systemd; --now applies it to the running session too. start/stop
  affect only this boot session — a stopped service returns after a
  reboot. Note that legacy 'launchctl stop' is my-lc's kill, NOT my-lc's
  stop: it signals the process, so a KeepAlive service comes right back.

  One launchd/systemd difference: a disabled launchd service cannot be
  started at all (systemd needs 'mask' for that), so start on a disabled
  service tells you to enable it first.

MULTIPLE TARGETS
  A verb that matches more than one service prints the plan and stops,
  asking for the word 'go'. --go carries it out without asking.

CONFIG
  Searched as $MY_LC_CONFIG, --config FILE, /LINKS/default/my-lc.conf,
  ~/.my-lc.conf, /etc/my-lc.conf, /usr/local/etc/my-lc.conf.
  DEFAULT_COMMAND (status) is what a bare 'my-lc' runs, ALL_MEANS
  (non-apple) is what --all includes, STATE_DIR (/var/lib/mine/<user>/my-lc)
  holds the log watermarks. --create-config prints the annotated default.
EOF
}

# ======================================================================
# helpers
# ======================================================================

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
err() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; EXITCODE=1; }

# major debug; -D only. Appends to DBG_LOG when one was given.
dbg() {
  [ "$DBG" = 1 ] || return 0
  printf ' ~~~ %s\n' "$*"
  [ -n "$DBG_LOG" ] && printf '%s ~~~ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$DBG_LOG"
  return 0
}

# progress narration; default ON, silenced by -Q. Never used for errors.
msg()  { [ "$QUIET" = 1 ] || printf '* %s\n' "$*"; }
msgn() { [ "$QUIET" = 1 ] || printf '* %s' "$*"; }   # no newline: '... done' follows
det()  { [ "$VRB"   = 1 ] && printf '    > %s\n' "$*"; return 0; }

# The ONLY place a launchctl command is both echoed and executed, so the
# echoed line can never drift from the executed one.
run() {
  [ "$VRB" = 1 ] && printf ' >>> %s\n' "$*"
  "$@"
}

# colour, only when it is going to a terminal and the config allows it
setup_color() {
  C_OFF=; C_ON=; C_WARN=; C_BAD=; C_DIM=; C_HDR=
  case "$COLOR" in
    never) return 0 ;;
    auto)  [ -t 1 ] || return 0 ;;
  esac
  C_OFF=$(printf '\033[0m')
  C_ON=$(printf '\033[32m')
  C_WARN=$(printf '\033[33m')
  C_BAD=$(printf '\033[31m')
  C_DIM=$(printf '\033[2m')
  C_HDR=$(printf '\033[1m')
}

# States render exactly as they are stored: '@on' and '@off' read as
# "after a reload". A circular-arrow glyph (U+21BB) was tried first, but
# terminal fonts substitute it for an unrelated mark, which turned the one
# column that had to be self-explanatory into noise.
state_render() { printf '%s' "$1"; }

# What an exit code MEANS. A bare 'FAIL 78' makes the reader go and look it
# up, which is the same failure as launchctl's numeric errors. 64-78 are the
# sysexits.h conventions, 128+N is death by signal N.
#   $2 = 'short' for the table, anything else for the record view
exit_meaning() {
  case "$1" in
    1)   _em='general error' ;;
    2)   _em='misuse of a shell builtin' ;;
    64)  _em='usage error'            ; _el='EX_USAGE: the command line was wrong' ;;
    65)  _em='data error'             ; _el='EX_DATAERR: the input data was wrong' ;;
    66)  _em='no input'               ; _el='EX_NOINPUT: an input file was missing or unreadable' ;;
    67)  _em='no such user'           ; _el='EX_NOUSER' ;;
    68)  _em='no such host'           ; _el='EX_NOHOST' ;;
    69)  _em='unavailable'            ; _el='EX_UNAVAILABLE: a service it needed was not available' ;;
    70)  _em='internal error'         ; _el='EX_SOFTWARE: an internal software error' ;;
    71)  _em='OS error'               ; _el='EX_OSERR: an operating-system error, e.g. a failed kext load' ;;
    72)  _em='missing system file'    ; _el='EX_OSFILE' ;;
    73)  _em='cannot create'          ; _el='EX_CANTCREAT: an output file could not be created' ;;
    74)  _em='I/O error'              ; _el='EX_IOERR' ;;
    75)  _em='temporary failure'      ; _el='EX_TEMPFAIL: retrying later may work' ;;
    76)  _em='protocol error'         ; _el='EX_PROTOCOL' ;;
    77)  _em='permission denied'      ; _el='EX_NOPERM' ;;
    78)  _em='config error'           ; _el='EX_CONFIG: the program rejected its own configuration' ;;
    126) _em='not executable'         ; _el='found, but not executable' ;;
    127) _em='not found'              ; _el='the program was not found - check the plist path' ;;
    129) _em='killed: HUP'  ;; 130) _em='killed: INT'  ;; 131) _em='killed: QUIT' ;;
    134) _em='killed: ABRT' ;; 137) _em='killed: KILL' ;; 139) _em='killed: SEGV' ;;
    141) _em='killed: PIPE' ;; 143) _em='killed: TERM' ;;
    *)   _em= ;;
  esac
  [ -n "${_el:-}" ] && [ "$2" != short ] && { printf '%s' "$_el"; _el=; return 0; }
  _el=
  printf '%s' "$_em"
}

# How big a log is, for the record view. The size is free from stat; the
# line count is not, so a log past BIG_DELTA is reported by size alone
# rather than reading a gigabyte to produce one number.
log_size_note() {
  [ -n "$1" ] || return 0
  if [ ! -e "$1" ]; then printf 'does not exist yet'; return; fi
  if [ ! -f "$1" ]; then printf 'not a regular file'; return; fi
  if [ ! -r "$1" ]; then printf 'not readable as %s' "$(id -un)"; return; fi
  _lsz=$(stat -f '%z' "$1" 2>/dev/null)
  [ -n "$_lsz" ] || return 0
  if [ "$_lsz" = 0 ]; then printf 'empty'; return; fi
  _lmt=$(file_epoch "$1")
  _lwhen=
  [ -n "$_lmt" ] && _lwhen=", last $(when "$_lmt")"
  if [ "$_lsz" -le "$BIG_DELTA" ] 2>/dev/null; then
    printf '%sL, %s%s' "$(wc -l < "$1" 2>/dev/null | tr -d ' ')" "$(human_size "$_lsz")" "$_lwhen"
  else
    printf '%s, too big to count cheaply%s' "$(human_size "$_lsz")" "$_lwhen"
  fi
}

# Bytes as a compact human size, for deltas too large to count by line.
human_size() {
  _hs=$1
  if   [ "$_hs" -ge 1073741824 ] 2>/dev/null; then printf '%s.%sGB' $((_hs/1073741824)) $(( (_hs%1073741824)*10/1073741824 ))
  elif [ "$_hs" -ge 1048576 ]   2>/dev/null; then printf '%s.%sMB' $((_hs/1048576))    $(( (_hs%1048576)*10/1048576 ))
  elif [ "$_hs" -ge 1024 ]      2>/dev/null; then printf '%sKB'    $((_hs/1024))
  else printf '%sB' "$_hs"; fi
}

# A point in time, rendered the way the config asks: an age relative to now,
# or an absolute timestamp. Everything that shows "when" goes through here,
# so the two styles cannot drift apart.
when() {
  [ -n "$1" ] || { printf '?'; return; }
  if [ "$TIME_FORMAT" = absolute ]; then
    date -r "$1" "+$TIME_FMT" 2>/dev/null || printf '?'
  else
    human_age $(( $(now_epoch) - $1 ))
  fi
}

human_age() {
  # seconds -> compact 4d2h / 3h12m / 45m / 12s
  _ha=$1
  [ -z "$_ha" ] && { printf '?'; return; }
  if   [ "$_ha" -ge 86400 ]; then printf '%dd%dh' $((_ha/86400)) $(((_ha%86400)/3600))
  elif [ "$_ha" -ge 3600  ]; then printf '%dh%dm' $((_ha/3600))  $(((_ha%3600)/60))
  elif [ "$_ha" -ge 60    ]; then printf '%dm'    $((_ha/60))
  else                            printf '%ds'    "$_ha"
  fi
}

now_epoch() { date '+%s'; }

# mtime of a file as an epoch, empty when it does not exist
file_epoch() { [ -e "$1" ] && stat -f '%m' "$1" 2>/dev/null; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ======================================================================
# config
# ======================================================================

default_config_content() {
  cat <<'CFG_EOF'
# my-lc configuration. Plain shell syntax; sourced at startup.
# Every runtime-tunable value lives here — the script body has no
# hard-coded defaults other than the ones this file was generated from.

# Verb run by a bare 'my-lc' (status | list).
# 'status' with no filter renders the same table as 'list'; they differ
# only when exactly one service matches, where status gives the record view.
DEFAULT_COMMAND=status

# State filter applied when none is given on the command line:
#   enabled  = on / @on  — could run, or is running
#   disabled = off / @off
#   all      = no state filter
DEFAULT_FILTER_STATE=enabled

# Which domain a bare 'my-lc' looks at: daemons | agents | both
DEFAULT_SCOPE=daemons

# What --all includes:
#   non-apple   = every state, but not Apple's own services
#   with-apple  = every state, Apple's ~400 system services included
ALL_MEANS=non-apple

# Where plists are discovered. Space-separated, searched in order.
DAEMON_DIRS="/Library/LaunchDaemons /System/Library/LaunchDaemons"
# Agent dirs default to the acting user's own dir plus the shared ones;
# $HOME here is the acting user's home, resolved at runtime.
AGENT_DIRS="$HOME/Library/LaunchAgents /Library/LaunchAgents /System/Library/LaunchAgents"

# Log watermarks — STATE, not logs, so this belongs under /var/lib.
STATE_DIR="/var/lib/mine/$(id -un)/my-lc"

# Lines of stderr/stdout shown by 'status' when no watermark exists yet.
ERR_TAIL=10

# How many times to try a bootstrap. launchd can still be tearing the old
# instance down straight after a bootout, and reports 'Input/output error'
# until it is done; one retry a second apart clears it.
BOOTSTRAP_TRIES=3

# A log delta larger than this (bytes) is reported as a size rather than a
# line count: counting lines means reading the whole thing, and a
# crash-looping daemon can leave a gigabyte behind.
BIG_DELTA=1048576

# Label column width: 'auto' fits the widest label, or give a number.
WIDTH_LABEL=auto

# What 'delete' does with the plist:
#   backup = move it to $STATE_DIR/deleted/<label>.plist.<timestamp>, so
#            every removed launch item stays together, dated, next to the
#            tool's other state and out of the way of a Trash the user
#            empties without thinking about it
#   trash  = move it to the Trash of the user running my-lc
DELETE_MODE=backup

# How ages are shown: 'relative' gives 44d0h, 'absolute' gives a timestamp
# in TIME_FMT. Absolute is easier to correlate with other logs.
TIME_FORMAT=absolute
TIME_FMT="%Y-%m-%d_%H%M"

# Editor used by the 'edit' verb. Empty means: $VISUAL, then $EDITOR, then
# vi. Set it here to override the environment.
EDITOR_CMD=""

# Colour: auto (only on a terminal) | always | never
COLOR=auto

CFG_EOF
}

find_config() {
  _cfg=
  if [ -n "${MY_LC_CONFIG:-}" ]; then
    [ -r "$MY_LC_CONFIG" ] || die "\$MY_LC_CONFIG points to a missing file: $MY_LC_CONFIG"
    _cfg=$MY_LC_CONFIG
  elif [ -n "$CONFIG_OVERRIDE" ]; then
    [ -r "$CONFIG_OVERRIDE" ] || die "no such config file: $CONFIG_OVERRIDE"
    _cfg=$CONFIG_OVERRIDE
  else
    for _c in "/LINKS/default/$SCRIPT_NAME.conf" "$HOME/.$SCRIPT_NAME.conf" \
              "/etc/$SCRIPT_NAME.conf" "/usr/local/etc/$SCRIPT_NAME.conf"; do
      [ -r "$_c" ] && { _cfg=$_c; break; }
    done
  fi
  if [ -n "$_cfg" ]; then
    dbg "config: $_cfg"
    # shellcheck disable=SC1090  # path is resolved at runtime by design
    . "$_cfg"
  else
    dbg "config: none found, using built-in defaults"
  fi
  # Anything the config did not set gets the built-in default.
  [ -n "$AGENT_DIRS" ] || AGENT_DIRS="$HOME/Library/LaunchAgents /Library/LaunchAgents /System/Library/LaunchAgents"
  [ -n "$STATE_DIR" ]  || STATE_DIR="/var/lib/mine/$(id -un)/$SCRIPT_NAME"
}

create_config() {
  if [ -z "$1" ]; then
    default_config_content
    return 0
  fi
  [ -e "$1" ] && die "refusing to overwrite an existing file: $1"
  default_config_content > "$1" || die "could not write $1"
  printf 'wrote %s\n' "$1"
}

# ======================================================================
# domain resolution
# ======================================================================

# Which gui domain do we act on? Only ambiguous when running as root.
resolve_domain() {
  case "$SCOPE" in
    daemons) DOMAIN=system; DOMAIN_UID=; return 0 ;;
  esac
  if [ -n "$UID_OVERRIDE" ]; then
    DOMAIN_UID=$UID_OVERRIDE
  elif [ "$(id -u)" != 0 ]; then
    DOMAIN_UID=$(id -u)
  elif [ -n "${SUDO_UID:-}" ] && [ "$SUDO_UID" != 0 ]; then
    DOMAIN_UID=$SUDO_UID
    dbg "gui domain from \$SUDO_UID"
  else
    _cu=$(stat -f '%Su' /dev/console 2>/dev/null)
    if [ -n "$_cu" ] && [ "$_cu" != root ]; then
      DOMAIN_UID=$(id -u "$_cu" 2>/dev/null)
      dbg "gui domain from the console user ($_cu)"
    fi
  fi
  [ -n "$DOMAIN_UID" ] || die "cannot tell which gui domain to use (nobody is logged in at the console) — give --uid N"
  DOMAIN="gui/$DOMAIN_UID"
}

# Printed only when the acting domain is genuinely ambiguous: agents, as root.
domain_header() {
  [ "$SCOPE" = daemons ] && return 0
  [ "$(id -u)" = 0 ] || return 0
  [ "$QUIET" = 1 ] && return 0
  _du=$(id -un "$DOMAIN_UID" 2>/dev/null || printf '%s' "$DOMAIN_UID")
  printf 'acting on %s (%s)\n' "gui/$DOMAIN_UID" "$_du"
}

# ======================================================================
# plist reading
# ======================================================================

# Parse MANY plists in ONE plutil call and ONE awk pass, emitting a TSV
# line per plist. Reading them one at a time cost a fork each, which on a
# --with-apple run meant ~850 forks and made it unusably slow; batched, the
# same 422 plists parse in about a tenth of a second.
#   out: plist | label | trigger | program | err | out | user | group | watch
#   (fields separated by $FS1, watched paths by a literal '|')
scan_plists() {
  _list=$1; _out=$2
  : > "$_out"
  [ -s "$_list" ] || return 0
  # shellcheck disable=SC2046  # deliberate word-splitting: one batched call
  plutil -p $(cat "$_list") 2>/dev/null > "$TMPD/pp.raw"
  # A block per plist, in the order given. If the counts disagree (an
  # unreadable or malformed file emitted nothing) fall back to one call
  # per file rather than mis-attributing keys to the wrong service.
  _nb=$(grep -c '^{' "$TMPD/pp.raw" 2>/dev/null || echo 0)
  _nf=$(wc -l < "$_list" | tr -d ' ')
  if [ "$_nb" != "$_nf" ]; then
    dbg "plutil batch desync ($_nb blocks for $_nf files) - falling back to one call per file"
    : > "$TMPD/pp.raw"
    while IFS= read -r _f; do
      { printf '{\n'
        plutil -p "$_f" 2>/dev/null | sed '1d;$d'
        printf '}\n'; } >> "$TMPD/pp.raw"
    done < "$_list"
  fi
  awk -v listfile="$_list" -v S="$FS1" -v EM="$EM" '
    BEGIN { OFS=S; n=0; while ((getline l < listfile) > 0) files[++n]=l; idx=0 }
    function nz(x) { return x == "" ? EM : x }
    function flush() {
      if (idx == 0) return
      t=""
      if (boot)   t=t (t==""?"":"+") "boot"
      if (keep)   t=t (t==""?"":"+") "keep"
      if (iv!="") t=t (t==""?"":"+") "every" iv
      if (cal)    t=t (t==""?"":"+") "cal"
      if (hw)     t=t (t==""?"":"+") "watch"
      if (hq)     t=t (t==""?"":"+") "queue"
      if (sock)   t=t (t==""?"":"+") "sock"
      if (xpc)    t=t (t==""?"":"+") "xpc"
      if (login)  t=t (t==""?"":"+") "login"
      if (t=="")  t="manual"
      print nz(files[idx]), nz(label), nz(t), nz((p2!=""?p2:prog)), nz(ef), nz(of), nz(un), nz(gn), nz(watch)
      label=""; p2=""; prog=""; ef=""; of=""; un=""; gn=""; watch=""
      boot=0; keep=0; iv=""; cal=0; hw=0; hq=0; sock=0; xpc=0; login=0; arr=""
    }
    function val(l) { sub(/^[^=]*=> /, "", l); gsub(/^"|"$/, "", l); return l }
    /^\{/ { flush(); idx++; next }
    /^\}/ { next }
    /^ *"[A-Za-z]+" *=> *\[/ {
      arr=$0; sub(/^ *"/,"",arr); sub(/".*/,"",arr)
      if (arr == "WatchPaths")       hw=1
      if (arr == "QueueDirectories") hq=1
      if (arr == "Sockets")          sock=1
      if (arr == "MachServices")     xpc=1
      next
    }
    /^ *\]/ { arr=""; next }
    arr != "" && /=>/ {
      v=val($0)
      if (arr == "ProgramArguments" && prog == "") prog=v
      if (arr == "WatchPaths" || arr == "QueueDirectories")
        watch = watch (watch=="" ? "" : "|") v
      next
    }
    /^ *"Label" *=>/             { label=val($0) }
    /^ *"Program" *=>/           { p2=val($0) }
    /^ *"StandardErrorPath" *=>/ { ef=val($0) }
    /^ *"StandardOutPath" *=>/   { of=val($0) }
    /^ *"UserName" *=>/          { un=val($0) }
    /^ *"GroupName" *=>/         { gn=val($0) }
    /^ *"RunAtLoad" *=> *(1|true)/   { boot=1 }
    /^ *"KeepAlive" *=>/             { keep=1 }
    /^ *"StartInterval" *=>/         { iv=val($0); if (iv+0 == 0) iv="" }
    /^ *"StartCalendarInterval" *=>/ { cal=1 }
    /^ *"MachServices" *=>/          { xpc=1 }
    /^ *"LimitLoadToSessionType" *=>/{ login=1 }
    END { flush() }
  ' "$TMPD/pp.raw" >> "$_out"
}

# Does a path exist, and if we cannot tell, say so rather than guessing.
# Echoes: ok <type> | MISSING | ? <first unreadable component>
path_verdict() {
  _pv=$1
  if [ -e "$_pv" ]; then
    if [ -d "$_pv" ]; then printf 'ok dir'; else printf 'ok file'; fi
    return 0
  fi
  # Not visible. Walk the parents: the first component we may not search
  # makes the answer unknown, not absent.
  _d=$(dirname "$_pv")
  while [ "$_d" != / ] && [ -n "$_d" ]; do
    if [ -e "$_d" ]; then
      [ -x "$_d" ] || { printf '? %s not readable' "$_d"; return 0; }
      break
    fi
    _d=$(dirname "$_d")
  done
  # Every parent that exists is searchable, so the path is genuinely absent.
  printf 'MISSING'
}

# Which of the three permission digits applies to USER for PATH: the owner
# digit, the group digit, or the other digit. Every "can this user do X"
# question reduces to this, so it lives in one place: the same reasoning was
# written out three times and drifted between them.
#   echoes 0-7, or nothing when the path cannot be stat'd
perm_bit() {
  _pbs=$(stat -f '%u %g %Lp' "$1" 2>/dev/null) || return 1
  _pbo=${_pbs%% *}; _pbr=${_pbs#* }; _pbg=${_pbr%% *}; _pbm=${_pbr##* }
  _pbu=$(id -u "$2" 2>/dev/null) || return 1
  # root is bound by none of them for reading, and for execute needs only
  # that SOME execute bit is set; callers handle that case themselves.
  if   [ "$_pbo" = "$_pbu" ];                       then printf '%s' $(( (0$_pbm / 64) % 8 ))
  elif case " $(id -G "$2" 2>/dev/null) " in *" $_pbg "*) true ;; *) false ;; esac
                                                    then printf '%s' $(( (0$_pbm / 8) % 8 ))
  else                                                   printf '%s' $((  0$_pbm       % 8 ))
  fi
}

# Can USER read PATH, and reach it at all? Used for the watched paths: a
# path the job cannot read is a trigger that fires into a failure.
#   ok | <reason>
path_readable() {
  _prp=$1; _pru=$2
  [ -n "$_prp" ] && [ -n "$_pru" ] || { printf 'ok'; return; }
  _pruid=$(id -u "$_pru" 2>/dev/null) || { printf '? no such user: %s' "$_pru"; return; }
  # every parent must be traversable, whoever is asking
  _prd=$(dirname "$_prp")
  while [ "$_prd" != / ] && [ -n "$_prd" ] && [ "$_prd" != . ]; do
    if [ "$_pruid" != 0 ]; then
      _b=$(perm_bit "$_prd" "$_pru") || break
      [ $(( _b % 2 )) = 1 ] || { printf 'cannot traverse %s' "$_prd"; return; }
    fi
    _prd=$(dirname "$_prd")
  done
  [ "$_pruid" = 0 ] && { printf 'ok'; return; }
  _b=$(perm_bit "$_prp" "$_pru") || { printf 'ok'; return; }
  if [ $(( _b / 4 )) = 1 ]; then printf 'ok'
  else printf 'not readable by %s' "$_pru"; fi
}

# Is the program actually runnable BY THE USER THE SERVICE RUNS AS?
# '[ -x ]' answers "can *I* execute it", which is a different question: a
# root-owned mode-544 helper is executable by root and not by me, and
# reporting that as NOT EXECUTABLE is a false alarm. So the execute bits are
# read from the mode and matched against the right user.
#   ok | MISSING | EMPTY | NOT EXECUTABLE | NOT A FILE | ? <reason>
#   $2 = the user the service runs as (optional; defaults to a bits-only test)
program_verdict() {
  [ -n "$1" ] || { printf 'ok'; return; }
  _pvv=$(path_verdict "$1")
  case "$_pvv" in
    MISSING)  printf 'MISSING';    return ;;
    '?'*)     printf '%s' "$_pvv"; return ;;
    'ok dir') printf 'NOT A FILE'; return ;;
  esac
  [ -s "$1" ] || { printf 'EMPTY'; return; }

  # Who are we judging this for? The service's own user, not the caller.
  _pusr=${2:-$(id -un)}
  _pu2=$(id -u "$_pusr" 2>/dev/null) || { printf 'ok'; return; }

  # Only when the target IS the caller does '[ -x ]' answer the question,
  # and then it answers it exactly, with no fork.
  if [ "$_pu2" = "$(id -u)" ]; then
    [ -x "$1" ] && { printf 'ok'; return; }
  fi

  _pst=$(stat -f '%Lp' "$1" 2>/dev/null) || { printf '?'; return; }
  # No execute bit at all is definitive, for every user including root.
  [ $(( 0$_pst & 73 )) = 0 ] && { printf 'NOT EXECUTABLE'; return; }
  # root may execute anything that carries any execute bit.
  [ "$_pu2" = 0 ] && { printf 'ok'; return; }
  _pb=$(perm_bit "$1" "$_pusr") || { printf 'ok'; return; }
  if [ $(( _pb % 2 )) = 1 ]; then printf 'ok'
  else printf 'NOT EXECUTABLE by %s' "$_pusr"; fi
}

# Can USER actually reach and run it? Checked component by component, since
# a directory the user cannot traverse makes the program unreachable however
# permissive the file itself is. Uses stat, so this is the record-view form.
#   ok | <reason>
program_access() {
  _pa=$1; _pu=$2
  [ -n "$_pa" ] && [ -n "$_pu" ] || { printf 'ok'; return; }
  _uid=$(id -u "$_pu" 2>/dev/null) || { printf '? no such user: %s' "$_pu"; return; }
  [ "$_uid" = 0 ] && { printf 'ok (root)'; return; }
  _gids=" $(id -G "$_pu" 2>/dev/null) "
  # every parent directory must be traversable
  _dirs=; _d=$(dirname "$_pa")
  while [ "$_d" != / ] && [ -n "$_d" ] && [ "$_d" != . ]; do
    _dirs="$_d
$_dirs"
    _d=$(dirname "$_d")
  done
  printf '%s\n' "$_dirs" | while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    _st=$(stat -f '%u %g %Lp' "$_c" 2>/dev/null) || continue
    _o=${_st%% *}; _rest=${_st#* }; _g=${_rest%% *}; _m=${_rest##* }
    if   [ "$_o" = "$_uid" ];        then _bit=$(( (0$_m / 64) % 8 ))
    elif case "$_gids" in *" $_g "*) true ;; *) false ;; esac
                                     then _bit=$(( (0$_m / 8) % 8 ))
    else                                  _bit=$((  0$_m       % 8 ))
    fi
    [ $(( _bit % 2 )) = 1 ] || printf 'cannot traverse %s\n' "$_c"
  done > "$TMPD/pacc" 2>/dev/null
  if [ -s "$TMPD/pacc" ]; then head -n 1 "$TMPD/pacc" | tr -d '\n'; return; fi
  # ...and the file itself must be executable by that user
  _st=$(stat -f '%u %g %Lp' "$_pa" 2>/dev/null) || { printf 'ok'; return; }
  _o=${_st%% *}; _rest=${_st#* }; _g=${_rest%% *}; _m=${_rest##* }
  if   [ "$_o" = "$_uid" ];        then _bit=$(( (0$_m / 64) % 8 ))
  elif case "$_gids" in *" $_g "*) true ;; *) false ;; esac
                                   then _bit=$(( (0$_m / 8) % 8 ))
  else                                  _bit=$((  0$_m       % 8 ))
  fi
  if [ $(( _bit % 2 )) = 1 ]; then printf 'ok'
  else printf 'not executable by %s' "$_pu"; fi
}

# For a watched path that exists, say WHEN it last changed - that change is
# the event that would have fired the service - and for a directory WHAT
# changed, since the directory's own mtime moves when an entry appears or
# disappears.
watch_detail() {
  _wp=$1
  case "$2" in ok*) ;; *) return 0 ;; esac
  _mt=$(file_epoch "$_wp")
  [ -n "$_mt" ] || return 0
  printf '  %-10s   last change %s\n' '' "$(when "$_mt")"
  if [ -d "$_wp" ] && [ -r "$_wp" ] && [ -x "$_wp" ]; then
    # shellcheck disable=SC2012  # newest-by-mtime; BSD find has no -printf
    _new=$(ls -t "$_wp" 2>/dev/null | head -n 1)
    if [ -n "$_new" ]; then
      _nmt=$(file_epoch "$_wp/$_new")
      if [ -n "$_nmt" ]; then
        printf '  %-10s   newest entry: %s (%s)\n' '' "$_new" "$(when "$_nmt")"
      else
        printf '  %-10s   newest entry: %s\n' '' "$_new"
      fi
    else
      printf '  %-10s   the directory is empty\n' ''
    fi
  fi
}

# Worst verdict across a service's watched paths: ok | ! (missing) | ?
# A missing path outranks an unknown one: it is the actionable answer.
watch_summary() {
  [ -z "$1" ] && { printf 'ok'; return; }
  _ws=ok
  _rest=$1
  while [ -n "$_rest" ]; do
    case "$_rest" in
      *"|"*) _w=${_rest%%"|"*}; _rest=${_rest#*"|"} ;;
      *)     _w=$_rest; _rest= ;;
    esac
    [ -n "$_w" ] || continue
    case "$(path_verdict "$_w")" in
      MISSING) _ws='!'; break ;;
      '?'*)    _ws='?' ;;
    esac
  done
  printf '%s' "$_ws"
}

# ======================================================================
# discovery
# ======================================================================

# Write one DB row, substituting the empty marker so no field is ever blank
# on disk. Every reader decodes it the same way.
db_row() {
  _r=
  for _v in "$@"; do
    [ -n "$_v" ] || _v=$EM
    if [ -z "$_r" ]; then _r=$_v; else _r="$_r$FS1$_v"; fi
  done
  printf '%s\n' "$_r"
}

# One launchctl call for the whole flag axis, kept as a shell string so
# the per-service lookup is a 'case' match rather than a fork.
load_disabled_set() {
  run launchctl print-disabled "$1" 2>/dev/null \
    | awk -F'"' '/=> *disabled/ { print $2 }' > "$TMPD/disabled.$2"
}

# One launchctl call for the whole loaded axis, for THIS domain.
# 'launchctl list' is not usable here: run unprivileged it reports the
# caller's own domain, so every system daemon would look unloaded.
# 'launchctl print <domain>' lists the domain's services with their pid
# and last exit status, and works without root.
load_loaded_set() {
  run launchctl print "$1" 2>/dev/null | awk -v S="$FS1" '
    BEGIN { OFS=S }
    /^\tservices = \{/ { inb=1; next }
    inb && /^\t\}/     { inb=0 }
    inb && NF>=3        { print $3 S $1 S $2 }
  ' S="$FS1" > "$TMPD/loaded"
}

# One ps call for every process start time, instead of two forks per
# running service. Written to a file, so the join can read it in awk.
load_ps_map() {
  # 'ps -o lstart' prints LOCAL time with no offset, and the civil-days
  # arithmetic below necessarily treats it as UTC - so every process start
  # came out shifted by the timezone offset (two hours here).
  #
  # Rather than parse an offset and guess about DST, calibrate against a
  # process whose true start time is known exactly: pid 1 is launchd, and it
  # starts at boot, which kern.boottime gives as a real epoch. The difference
  # between its naive value and that IS the correction for every other row.
  _psboot=$(sysctl -n kern.boottime 2>/dev/null \
            | sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')
  ps -eo pid=,lstart= 2>/dev/null | awk -v S="$FS1" -v boot="${_psboot:-0}" '
    BEGIN { OFS=S; split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
            for (i = 1; i <= 12; i++) m[mn[i]] = i }
    {
      pid = $1; mon = m[$3]; day = $4; split($5, t, ":"); yr = $6
      y = yr; mo = mon; d = day
      y -= (mo <= 2)
      era = int((y >= 0 ? y : y - 399) / 400)
      yoe = y - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + d - 1
      doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
      days = era * 146097 + doe - 719468
      naive[pid] = days * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
      order[++n] = pid
    }
    END {
      # pid 1 is launchd; its start IS the boot time.
      delta = (boot > 0 && (1 in naive)) ? naive[1] - boot : 0
      for (i = 1; i <= n; i++) print order[i], naive[order[i]] - delta
    }
  ' > "$TMPD/psmap"
}



is_apple() {
  case "$1" in /System/Library/*) return 0 ;; esac
  case "$2" in com.apple.*)       return 0 ;; esac
  return 1
}

# Walk the plist dirs for one scope and emit one TSV record per service.
#   label domain plist apple state trigger status err out program user errf outf
discover_scope() {
  _sc=$1
  case "$_sc" in
    daemon) _dirs=$DAEMON_DIRS; _dom=system;             _dset=system ;;
    agent)  _dirs=$AGENT_DIRS;  _dom="gui/$DOMAIN_UID";  _dset=gui ;;
  esac

  # 1. collect the plist paths we actually care about
  : > "$TMPD/plists"
  : > "$TMPD/unreadable"
  for _dir in $_dirs; do
    [ -d "$_dir" ] || continue
    for _pl in "$_dir"/*.plist; do
      [ -e "$_pl" ] || continue
      _base=${_pl##*/}; _base=${_base%.plist}
      if [ "$APPLE_MODE" = exclude ] && is_apple "$_pl" "$_base"; then continue; fi
      if [ "$APPLE_MODE" = only ]  && ! is_apple "$_pl" "$_base"; then continue; fi
      case "$SEENF" in *" $_base "*) continue ;; esac
      SEENF="$SEENF$_base "
      if [ -r "$_pl" ]; then printf '%s\n' "$_pl" >> "$TMPD/plists"
      else                   printf '%s\n' "$_pl" >> "$TMPD/unreadable"; fi
    done
  done

  # 2. one plutil + one awk for the whole lot
  [ -e "$TMPD/disabled.$_dset" ] || : > "$TMPD/disabled.$_dset"
  [ -e "$TMPD/psmap" ]            || : > "$TMPD/psmap"
  scan_plists "$TMPD/plists" "$TMPD/parsed"
  [ -e "$TMPD/parsed" ] || : > "$TMPD/parsed"
  # A plist we may not read still has a knowable state and status: only its
  # trigger is unknown. Feed it through the same join with trigger '?'.
  while IFS= read -r _pl; do
    [ -n "$_pl" ] || continue
    _b=${_pl##*/}; _b=${_b%.plist}
    printf '%s\t%s\t?\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_pl" "$_b" "$EM" "$EM" "$EM" "$EM" "$EM" "$EM" >> "$TMPD/parsed"
  done < "$TMPD/unreadable"

  # 3. join everything in ONE awk pass. Doing this in the shell meant
  #    pattern-matching a multi-kilobyte string once per service, which is
  #    quadratic in dash and cost ~35s of pure CPU on a --with-apple run.
  awk -F"$FS1" -v S="$FS1" -v EM="$EM" \
      -v dom="$_dom" -v sc="$_sc" -v now="$NOW_EPOCH" -v vrb="$VRB" \
      -v agentuser="$AGENT_USER" -v applemode="$APPLE_MODE" \
      -v fdis="$TMPD/disabled.$_dset" -v flod="$TMPD/loaded" -v fps="$TMPD/psmap" '
    BEGIN { OFS=S }
    function nz(x) { return x == "" ? EM : x }
    function age(s,   d,h,m) {
      if (s >= 86400) { d=int(s/86400); h=int((s%86400)/3600); return d "d" h "h" }
      if (s >= 3600)  { h=int(s/3600);  m=int((s%3600)/60);    return h "h" m "m" }
      if (s >= 60)    { return int(s/60) "m" }
      return s "s"
    }
    function isapple(pl, lab) {
      return (index(pl, "/System/Library/") == 1 || index(lab, "com.apple.") == 1)
    }
    # Keying off FILENAME rather than a counter: an empty stage file never
    # fires FNR==1, which would silently shift every later stage.
    FILENAME == fdis { dis[$1]=1; next }
    FILENAME == flod { pid[$1]=$2; lec[$1]=$3; next }
    FILENAME == fps  { start[$1]=$2; next }
    {
      pl=$1; lab=$2; trig=$3; prog=$4; ef=$5; of=$6; us=$7; gr=$8; wat=$9
      if (pl==EM) pl=""; if (lab==EM) lab=""; if (trig==EM) trig=""
      if (prog==EM) prog=""; if (ef==EM) ef=""; if (of==EM) of=""
      if (us==EM) us=""; if (gr==EM) gr=""; if (wat==EM) wat=""
      if (lab == "") { n=split(pl, pp, "/"); lab=pp[n]; sub(/\.plist$/, "", lab) }
      ap = isapple(pl, lab) ? 1 : 0

      p = (lab in pid) ? pid[lab] : ""
      ld = (lab in pid) ? 1 : 0
      if (p == "0") p = ""
      d = (lab in dis) ? 1 : 0

      if      (pl == "")        st="orphan"
      else if (!d && ld)        st="on"
      else if (!d && !ld)       st="@on"
      else if (d && ld)         st="@off"
      else                      st="off"

      # who it runs as: only when it is not the default for the scope
      def = (sc == "agent") ? agentuser : "root"
      extra = ""
      if (us != "") {
        if (us != def || vrb == 1) extra = " as " us (gr != "" ? ":" gr : "")
      } else if (vrb == 1) extra = " as " def

      e = (lab in lec) ? lec[lab] : ""
      if (p != "") {
        status = (p in start) ? ("run \003" start[p] " pid " p extra) \
                              : ("run pid " p extra)
      } else if (e != "" && e != "-" && e != "0") {
        status = "FAIL " e "\002" extra
      } else if (ld || st == "@off") {
        if (trig ~ /every/)      { iv=trig; sub(/.*every/,"",iv); sub(/\+.*/,"",iv); status="every " iv extra }
        else if (trig ~ /cal/)   status = "cal" extra
        else if (trig ~ /sock|xpc|watch|queue/) status = "waiting" extra
        else if (e == "0")       status = "ok" extra
        else                     status = "-" extra
      } else status = "-" extra

      # the two fields that need the filesystem are resolved afterwards,
      # and only for the handful of services that actually have paths
      ei = (ef == "") ? "-" : "?PENDING"
      oi = (of == "") ? "-" : "?PENDING"
      tg = (wat == "") ? trig : trig "?PENDINGWATCH"

      print nz(lab), nz(dom), nz(pl), nz(ap), nz(st), nz(tg), nz(status), nz(ei), nz(oi), \
            nz(prog), nz(us), nz(ef), nz(of), nz(wat)
    }
  ' "$TMPD/disabled.$_dset" "$TMPD/loaded" "$TMPD/psmap" "$TMPD/parsed" > "$TMPD/joined"

  # 3b. resolve only the rows that need to touch the filesystem
  while IFS="$FS1" read -r _lab _dm _pl _ap _st _tg _su _ei _oi _pr _us _ef _of _wat; do
    [ -n "$_lab" ] || continue
    [ "$_pl"  = "$EM" ] && _pl=;  [ "$_tg" = "$EM" ] && _tg=
    [ "$_su"  = "$EM" ] && _su=;  [ "$_pr" = "$EM" ] && _pr=
    [ "$_us"  = "$EM" ] && _us=;  [ "$_ef" = "$EM" ] && _ef=
    [ "$_of"  = "$EM" ] && _of=;  [ "$_wat" = "$EM" ] && _wat=
    [ "$_ei"  = "$EM" ] && _ei=;  [ "$_oi" = "$EM" ] && _oi=
    case "$_tg" in
      *'?PENDINGWATCH')
        _tg=${_tg%'?PENDINGWATCH'}
        case "$(watch_summary "$_wat")" in
          '!') _tg="$_tg!" ;;
          '?') _tg="$_tg?" ;;
        esac ;;
    esac
    SEEN="$SEEN$_lab "
    # \003 marks a moment in time that awk could not render: BSD awk has no
    # strftime, and only the shell knows the configured style.
    case "$_su" in
      *"$(printf '\003')"*)
        _ep=${_su#*"$(printf '\003')"}; _ep=${_ep%% *}
        _su=$(printf '%s' "$_su" | sed "s/$(printf '\003')$_ep/$(when "$_ep")/") ;;
    esac
    # \002 marks where the exit code's meaning goes; awk cannot know it
    case "$_su" in
      *"$(printf '\002')"*)
        _code=${_su#FAIL }; _code=${_code%%"$(printf '\002')"*}
        _mn=$(exit_meaning "$_code" short)
        if [ -n "$_mn" ]; then _su=$(printf '%s' "$_su" | sed "s/$(printf '\002')/ $_mn/")
        else                   _su=$(printf '%s' "$_su" | sed "s/$(printf '\002')//"); fi ;;
    esac
    # A broken program is WHY a stopped service is stopped, so for one that
    # is not running it is the fact worth showing. A running service proves
    # its program works, so it is not re-checked there.
    case "$_su" in
      run\ *) ;;
      *) if [ -n "$_pr" ]; then
           _pw=
           case "$_dm" in
             system) _asu=${_us:-root} ;;
             *)      _asu=${_us:-$AGENT_USER} ;;
           esac
           case "$(program_verdict "$_pr" "$_asu")" in
             ok|'?'*)          ;;
             MISSING)          _pw='program MISSING' ;;
             EMPTY)            _pw='program EMPTY' ;;
             'NOT EXECUTABLE')   _pw='program NOT EXECUTABLE' ;;
             'NOT EXECUTABLE by'*) _pw="program NOT EXECUTABLE by $_asu" ;;
             'NOT A FILE')     _pw='program is a DIRECTORY' ;;
           esac
           if [ -n "$_pw" ]; then
             # keep the exit code when there is one: it says HOW it died,
             # while the program verdict says why it cannot start again
             case "$_su" in
               FAIL*) _su="$_su, $_pw" ;;
               *)     _su=$_pw ;;
             esac
           fi
         fi ;;
    esac
    [ "$_ei" = '?PENDING' ] && _ei=$(log_indicator "$_ef")
    [ "$_oi" = '?PENDING' ] && _oi=$(log_indicator "$_of")
    # When both streams point at ONE file the count is not stderr alone, and
    # saying so matters: it is the difference between "90 lines of errors"
    # and "90 lines of ordinary logging that happen to include stderr".
    if [ -n "$_ef" ] && [ "$_ef" = "$_of" ]; then
      # One file for both streams: the count is not errors, it is everything
      # the service logged. Say so in words rather than marking it, and
      # leave it uncoloured - there is nothing here to alarm anyone.
      if [ "$_ei" != '-' ]; then
        _ei="merged with stdout: ${_ei%% *}"
      fi
      _oi='same file'
    fi

    # When did it last do anything? The newest of its log files is the only
    # evidence launchd leaves behind. For a FAILED service that is the
    # difference between "it broke" and "it has been broken since July".
    _last=
    for _lp in "$_ef" "$_of"; do
      [ -n "$_lp" ] || continue
      _lm=$(file_epoch "$_lp") || continue
      [ -n "$_lm" ] || continue
      [ -z "$_last" ] && _last=$_lm
      [ "$_lm" -gt "$_last" ] 2>/dev/null && _last=$_lm
    done
    # No log to date it by? A boot-triggered failure happened at boot.
    _since=$_last; _sincewhat=dead
    if [ -z "$_since" ] && [ -n "$BOOT_EPOCH" ]; then
      case "$_su" in
        FAIL*) case "$_tg" in *boot*) _since=$BOOT_EPOCH; _sincewhat='dead since boot' ;; esac ;;
      esac
    fi
    if [ -n "$_since" ]; then
      _lage=$(when "$_since")
      case "$_su" in
        run\ *) ;;
        FAIL*)  _su="$_su, $_sincewhat $_lage" ;;
        *)      [ "$VRB" = 1 ] && _su="$_su, last $_lage" ;;
      esac
    fi
    db_row "$_lab" "$_dm" "$_pl" "$_ap" "$_st" "$_tg" "$_su" "$_ei" "$_oi" \
           "$_pr" "$_us" "$_ef" "$_of" "$_wat" >> "$DB"
  done < "$TMPD/joined"

  # 4. loaded services with no plist on disk are orphans, still worth showing
  while IFS="$FS1" read -r _l _p _x; do
    [ -n "$_l" ] || continue
    case "$SEEN" in *" $_l "*) continue ;; esac
    SEEN="$SEEN$_l "
    _apple=0; is_apple "" "$_l" && _apple=1
    [ "$APPLE_MODE" = exclude ] && [ "$_apple" = 1 ] && continue
    [ "$APPLE_MODE" = only ]    && [ "$_apple" = 0 ] && continue
    db_row "$_l" "$_dom" "" "$_apple" orphan manual - - - "" "" "" "" "" >> "$DB"
  done < "$TMPD/loaded"
}

# "12L 3h" for a non-empty log, "-" for missing/empty.
log_indicator() {
  [ -n "$1" ] || { printf -- '-'; return; }
  [ -e "$1" ] || { printf -- '-'; return; }
  # A log destination is not always a regular file: several Apple daemons
  # point StandardOutPath at /dev/console. Reading one of those BLOCKS
  # forever, so a device, fifo or socket is reported as what it is and
  # never measured.
  [ -f "$1" ] || { printf 'dev'; return; }
  [ -r "$1" ] || { printf '?'; return; }
  _sz=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  [ "${_sz:-0}" -gt 0 ] 2>/dev/null || { printf -- '-'; return; }
  _ln=$(wc -l < "$1" 2>/dev/null | tr -d ' ')
  _mt=$(file_epoch "$1")
  # 'last' is not decoration: the file's mtime is when the most recent line
  # was written, not when the first error happened, and the bare timestamp
  # read as either.
  if [ -n "$_mt" ]; then printf '%sL last %s' "$_ln" "$(when "$_mt")"
  else                   printf '%sL' "$_ln"; fi
}

# ======================================================================
# selection
# ======================================================================

# A filter word may be an exact target rather than a substring.
# Emits the label it resolves to, or nothing.
resolve_target() {
  case "$1" in
    /*.plist)
      awk -F"$FS1" -v p="$1" '$3==p { print $1; exit }' "$DB"; return 0 ;;
    system/*|gui/*/*|user/*/*)
      _rt=${1##*/}
      awk -F"$FS1" -v l="$_rt" '$1==l { print $1; exit }' "$DB"; return 0 ;;
  esac
  awk -F"$FS1" -v l="$1" '$1==l { print $1; exit }' "$DB"
}

# Apply every filter and flag; write the surviving records to $2.
select_records() {
  _out=$2
  cp "$DB" "$TMPD/sel"

  # apple axis
  case "$APPLE_MODE" in
    exclude) awk -F"$FS1" '$4==0' "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel" ;;
    only)    awk -F"$FS1" '$4==1' "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel" ;;
  esac

  # state axis
  case "$FILTER_STATE" in
    enabled)  awk -F"$FS1" '$5=="on"  || $5=="@on"'  "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel" ;;
    disabled) awk -F"$FS1" '$5=="off" || $5=="@off"' "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel" ;;
  esac

  [ "$WANT_RUNNING" = 1 ] && { awk -F"$FS1" '$7 ~ /^run /' "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel"; }
  [ "$WANT_FAILED"  = 1 ] && { awk -F"$FS1" '$7 ~ /^FAIL /' "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel"; }
  [ "$WANT_STDERR"  = 1 ] && { awk -F"$FS1" '$12!=""' "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel"; }
  [ "$WANT_STDOUT"  = 1 ] && { awk -F"$FS1" '$13!=""' "$TMPD/sel" > "$TMPD/sel2"; mv "$TMPD/sel2" "$TMPD/sel"; }

  # filter words: exact target first, else substring over label+plist+program
  for _f in $FILTERS; do
    _exact=$(resolve_target "$_f")
    if [ -n "$_exact" ]; then
      awk -F"$FS1" -v l="$_exact" '$1==l' "$TMPD/sel" > "$TMPD/sel2"
    else
      _lf=$(lower "$_f")
      awk -F"$FS1" -v f="$_lf" '
        { s=tolower($1 " " $3 " " $10); if (index(s,f)) print }' "$TMPD/sel" > "$TMPD/sel2"
    fi
    mv "$TMPD/sel2" "$TMPD/sel"
  done

  sort -f "$TMPD/sel" > "$_out"
}

# ======================================================================
# rendering
# ======================================================================

render_table() {
  _f=$1
  [ -s "$_f" ] || { [ "$QUIET" = 1 ] || printf 'no matching services\n'; return 0; }

  if [ "$WIDTH_LABEL" = auto ]; then
    _wl=$(awk -F"$FS1" '{ if (length($1)>m) m=length($1) } END { print (m<20?20:(m>52?52:m)) }' "$_f")
  else
    _wl=$WIDTH_LABEL
  fi
  _wt=$(awk -F"$FS1" '{ if (length($6)>m) m=length($6) } END { print (m<7?7:m) }' "$_f")
  _ws=$(awk -F"$FS1" '{ if (length($7)>m) m=length($7) } END { print (m<6?6:m) }' "$_f")
  _dom=0; [ "$SCOPE" = both ] && _dom=1

  # header
  if [ "$QUIET" != 1 ]; then
    printf '%s' "$C_HDR"
    [ "$_dom" = 1 ] && printf '%-10s ' DOMAIN
    printf '%-*s %-6s %-*s %-*s %s' "$_wl" LABEL STATE "$_wt" TRIGGER "$_ws" STATUS ERR
    [ "$VRB" = 1 ] && printf ' %s' OUT
    printf '%s\n' "$C_OFF"
  fi

  _anyq=0
  while IFS="$FS1" read -r _l _d _p _a _st _tr _su _er _ou _pr _us _ef _of _wat; do
    [ -n "$_l" ] || continue
    case "$_tr" in *'?'*) _anyq=1 ;; esac
    _c=$C_OFF
    case "$_st" in
      on)   _c=$C_ON ;;
      @on)  _c=$C_WARN ;;
      off)  _c=$C_DIM ;;
      @off) _c=$C_WARN ;;
      orphan) _c=$C_BAD ;;
    esac
    [ "$_dom" = 1 ] && printf '%-10s ' "$_d"
    printf '%-*s ' "$_wl" "$_l"
    printf '%s%-6s%s ' "$_c" "$_st" "$C_OFF"
    printf '%-*s ' "$_wt" "$_tr"
    # A failure or a broken program is the most actionable cell on the
    # screen; it should not render like an ordinary status. Padding is
    # computed from the uncoloured text, since escape bytes count in %-*s.
    _sc=
    case "$_su" in
      *'program MISSING'*|*'program EMPTY'*|*'program NOT EXECUTABLE'*|*'program is a DIRECTORY'*)
        _sc=$C_BAD ;;
      FAIL*) _sc=$C_BAD ;;
    esac
    if [ -n "$_sc" ]; then
      _spad=$(( _ws - ${#_su} )); [ "$_spad" -lt 0 ] && _spad=0
      printf '%s%s%s%*s ' "$_sc" "$_su" "$C_OFF" "$_spad" ''
    else
      printf '%-*s ' "$_ws" "$_su"
    fi
    # A service writing to its OWN stderr is worth the eye going to it, so
    # every non-empty one is coloured. The single exception is a log shared
    # with stdout: there is no way to tell an error from ordinary output in
    # it, so it is reported in words and left plain.
    if [ "$_er" = '-' ]; then printf -- '-'
    else
      case "$_er" in
        merged*) printf '%s' "$_er" ;;
        *)       printf '%s%s%s' "$C_BAD" "$_er" "$C_OFF" ;;
      esac
    fi
    [ "$VRB" = 1 ] && printf ' %s' "$_ou"
    printf '\n'
    if [ "$VRB" = 1 ]; then
      [ -n "$_p" ]  && det "plist:   $_p"
      [ -n "$_pr" ] && det "program: $_pr"
    fi
  done < "$_f"

  if [ "$_anyq" = 1 ] && [ "$QUIET" != 1 ]; then
    printf '%s? = plist or watched path not readable as %s; rerun as root%s\n' \
      "$C_DIM" "$(id -un)" "$C_OFF"
  fi
}

# Strip the empty-field marker from a value read out of the DB.
unmark() { [ "$1" = "$EM" ] || printf '%s' "$1"; }

render_record() {
  _l=$(unmark "$(cut -d"$FS1" -f1 "$1")");  _d=$(unmark "$(cut -d"$FS1" -f2 "$1")")
  _p=$(unmark "$(cut -d"$FS1" -f3 "$1")");  _st=$(unmark "$(cut -d"$FS1" -f5 "$1")")
  _tr=$(unmark "$(cut -d"$FS1" -f6 "$1")"); _su=$(unmark "$(cut -d"$FS1" -f7 "$1")")
  _pr=$(unmark "$(cut -d"$FS1" -f10 "$1")"); _us=$(unmark "$(cut -d"$FS1" -f11 "$1")")
  _ef=$(unmark "$(cut -d"$FS1" -f12 "$1")"); _of=$(unmark "$(cut -d"$FS1" -f13 "$1")")

  printf '%s%s%s\n' "$C_HDR" "$_l" "$C_OFF"
  printf '  %-10s %s\n' 'domain:'  "$_d"
  printf '  %-10s %s\n' 'state:'   "$(state_render "$_st")  $(state_meaning "$_st")"
  printf '  %-10s %s\n' 'trigger:' "$_tr"
  printf '  %-10s %s\n' 'status:'  "$_su"
  _rl=
  for _lp in "$_ef" "$_of"; do
    [ -n "$_lp" ] || continue
    _lm=$(file_epoch "$_lp") || continue
    [ -n "$_lm" ] || continue
    [ -z "$_rl" ] && _rl=$_lm
    [ "$_lm" -gt "$_rl" ] 2>/dev/null && _rl=$_lm
  done
  if [ -z "$_rl" ]; then
    case "$_su" in
      FAIL*) case "$_tr" in
               *boot*) _bt=$BOOT_EPOCH
                       [ -n "$_bt" ] && printf '  %-10s %s%s%s\n' 'dead since:' "$C_BAD" \
                         "$(date -r "$_bt" '+%Y-%m-%d %H:%M:%S') - it failed at boot, and has no log to date it by" "$C_OFF" ;;
             esac ;;
    esac
  fi
  if [ -n "$_rl" ]; then
    case "$_su" in
      run\ *) printf '  %-10s %s\n' 'last log:' \
                "$(date -r "$_rl" '+%Y-%m-%d %H:%M:%S') ($(human_age $(( $(now_epoch) - _rl )) ) ago)" ;;
      *)      printf '  %-10s %s\n' 'dead since:' \
                "$(date -r "$_rl" '+%Y-%m-%d %H:%M:%S') ($(human_age $(( $(now_epoch) - _rl )) ) ago)" ;;
    esac
  fi
  case "$_su" in
    FAIL\ *) _code=${_su#FAIL }; _code=${_code%% *}
             _long=$(exit_meaning "$_code" long)
             [ -n "$_long" ] && printf '  %-10s %s\n' '' "exit $_code = $_long" ;;
  esac
  if [ -n "$_p" ]; then
    printf '  %-10s %s\n' 'plist:' "$_p"
    # When a launch item was installed, and when its definition last
    # changed, are two different questions: an old plist that changed
    # yesterday is a very different story from one untouched since install.
    _pb=$(stat -f '%B' "$_p" 2>/dev/null)
    _pm=$(stat -f '%m' "$_p" 2>/dev/null)
    if [ -n "$_pb" ] && [ -n "$_pm" ]; then
      if [ "$_pb" = "$_pm" ]; then
        printf '  %-10s %s\n' '' "written $(when "$_pb"), unchanged since"
      else
        printf '  %-10s %s\n' '' "written $(when "$_pb"), last changed $(when "$_pm")"
      fi
    fi
    plist_problems "$_p" "$_l"
  fi
  show_loaded_diff "$_l" "$_d" "$_p"
  if [ -n "$_pr" ]; then
    case "$_d" in
      system) _asuser=${_us:-root} ;;
      *)      _asuser=${_us:-$(id -un "$DOMAIN_UID" 2>/dev/null)} ;;
    esac
    _pv=$(program_verdict "$_pr" "$_asuser")
    # Show what actually gets executed, arguments and all: 'program: /bin/sh'
    # says almost nothing when the plist is /bin/sh -c "the real work".
    _cmd=
    [ -n "$_p" ] && _cmd=$(plist_cmdline "$_p")
    # When the command line IS just the program, one line says it all;
    # repeating it under 'program:' is noise.
    _cmdbare=$(printf '%s' "$_cmd" | sed 's/^"//; s/"$//')
    if [ -n "$_cmd" ] && [ "$_cmdbare" != "$_pr" ]; then
      printf '  %-10s %s\n' 'command:' "$_cmd"
      printf '  %-10s %s\n' 'program:' "$_pr"
    elif [ -n "$_cmd" ]; then
      printf '  %-10s %s\n' 'program:' "$_pr"
    else
      printf '  %-10s %s\n' 'program:' "$_pr"
    fi
    case "$_pv" in
      ok)
        _pac=$(program_access "$_pr" "$_asuser")
        if [ "$_pac" = ok ] || [ "$_pac" = 'ok (root)' ]; then
          printf '  %-10s %s\n' '' "exists, executable, reachable by $_asuser"
        else
          printf '  %-10s %s%s%s\n' '' "$C_BAD" "UNREACHABLE by $_asuser: $_pac" "$C_OFF"
        fi ;;
      MISSING)          printf '  %-10s %s%s%s\n' '' "$C_BAD" 'MISSING - this is why it cannot start (exit 127)' "$C_OFF" ;;
      EMPTY)            printf '  %-10s %s%s%s\n' '' "$C_BAD" 'the file is EMPTY (0 bytes)' "$C_OFF" ;;
      'NOT EXECUTABLE')   printf '  %-10s %s%s%s\n' '' "$C_BAD" 'NOT EXECUTABLE - no execute bit at all (exit 126)' "$C_OFF" ;;
      'NOT EXECUTABLE by'*) printf '  %-10s %s%s%s\n' '' "$C_BAD" "$_pv - the bits allow others, not this user" "$C_OFF" ;;
      'NOT A FILE')     printf '  %-10s %s%s%s\n' '' "$C_BAD" 'this path is a DIRECTORY, not a program' "$C_OFF" ;;
      '?'*)             printf '  %-10s %s\n' '' "$_pv - rerun as root to tell" ;;
    esac
  fi
  if [ -n "$_us" ]; then printf '  %-10s %s\n' 'runs as:' "$_us"
  else
    case "$_d" in
      system) printf '  %-10s %s\n' 'runs as:' 'root (default for a daemon)' ;;
      *)      printf '  %-10s %s\n' 'runs as:' "$(id -un "$DOMAIN_UID" 2>/dev/null) (default for an agent)" ;;
    esac
  fi

  # who the job runs as decides whether it can read its watched paths
  case "$_d" in
    system) _asuser=${_us:-root} ;;
    *)      _asuser=${_us:-$(id -un "$DOMAIN_UID" 2>/dev/null)} ;;
  esac

  # watched paths, each with its own verdict
  _wat=$(unmark "$(cut -d"$FS1" -f14 "$1")")
  if [ -n "$_wat" ]; then
    _first=1
    _rest=$_wat
    while [ -n "$_rest" ]; do
      case "$_rest" in
        *"|"*) _w=${_rest%%"|"*}; _rest=${_rest#*"|"} ;;
        *)     _w=$_rest; _rest= ;;
      esac
      [ -n "$_w" ] || continue
      if [ "$_first" = 1 ]; then _lbl='watches:'; _first=0; else _lbl=''; fi
      _pv=$(path_verdict "$_w")
      # A path that exists but cannot be read by the user the job runs as is
      # a trigger that fires into a failure, so check that too.
      case "$_pv" in
        ok*) _pr2=$(path_readable "$_w" "$_asuser")
             [ "$_pr2" = ok ] || _pv="$_pv, $_pr2" ;;
      esac
      printf '  %-10s %-56s %s\n' "$_lbl" "$_w" "$_pv"
      watch_detail "$_w" "$_pv"
    done
    case "$_tr" in
      *watch*) printf '  %-10s %s\n' '' 'note: WatchPaths fires when a watched DIRECTORY gains or loses'
               printf '  %-10s %s\n' '' '      an entry, not when a file inside it is edited in place' ;;
    esac
    case "$_tr" in
      *queue*) printf '  %-10s %s\n' '' 'note: QueueDirectories only fires while the directory is NOT'
               printf '  %-10s %s\n' '' '      empty, and the job is expected to drain it' ;;
    esac
  fi

  if [ -n "$_ef" ]; then
    _n1=$(log_size_note "$_ef")
    printf '  %-10s %s%s\n' 'stderr:' "$_ef" "$( [ -n "$_n1" ] && printf '   (%s)' "$_n1" )"
  fi
  if [ -n "$_of" ]; then
    if [ "$_of" = "$_ef" ]; then
      printf '  %-10s %s   (the same file)\n' 'stdout:' "$_of"
    else
      _n2=$(log_size_note "$_of")
      printf '  %-10s %s%s\n' 'stdout:' "$_of" "$( [ -n "$_n2" ] && printf '   (%s)' "$_n2" )"
    fi
  fi
  show_log_delta "$_l" "$_ef" "$_of"
}

# launchd keeps the definition it was given at bootstrap time. Editing the
# plist changes the file, NOT the running service - and nothing tells you
# they have diverged. These two render the same facts from each side so
# they can be diffed.
defn_from_launchctl() {
  launchctl print "$1/$2" 2>/dev/null | awk '
    /^\tprogram = /      { sub(/^\tprogram = /, ""); print "program " $0; next }
    /^\targuments = \{/  { inargs = 1; next }
    inargs && /^\t\}/    { inargs = 0; next }
    inargs                { sub(/^\t\t/, ""); print "argument " $0; next }
    /^\tstdout path = /  { sub(/^\tstdout path = /, ""); print "stdout " $0; next }
    /^\tstderr path = /  { sub(/^\tstderr path = /, ""); print "stderr " $0; next }
  '
}

defn_from_plist() {
  plutil -p "$1" 2>/dev/null | awk '
    function val(l) { sub(/^[^=]*=> /, "", l); gsub(/^"|"$/, "", l); return l }
    /^ *"ProgramArguments" *=> *\[/ { inargs = 1; next }
    inargs && /^ *\]/              { inargs = 0; next }
    inargs && /=>/                  { a[++n] = val($0); print "argument " a[n]; next }
    /^ *"Program" *=>/              { prog = val($0); next }
    /^ *"StandardOutPath" *=>/      { print "stdout " val($0); next }
    /^ *"StandardErrorPath" *=>/    { print "stderr " val($0); next }
    END {
      # launchd fills program in from the first argument when the plist does
      # not set one, and reports BOTH. Mirror that, or a plist that only has
      # ProgramArguments reads as changed when nothing has changed.
      if (prog == "") prog = a[1]
      if (prog != "") print "program " prog
      # NOT the reverse: for a Program-only service launchctl reports a
      # program and NO arguments block, so inventing argument[0] here made
      # every such service read as changed.
    }
  '
}


# Report how the running service differs from its plist, if at all.
show_loaded_diff() {
  _dl=$1; _dd=$2; _dp=$3
  [ -n "$_dp" ] || return 0
  launchctl print "$_dd/$_dl" >/dev/null 2>&1 || return 0
  defn_from_launchctl "$_dd" "$_dl" | sort > "$TMPD/defn.loaded"
  defn_from_plist "$_dp"            | sort > "$TMPD/defn.disk"
  # A plist my-lc cannot read yields nothing, which would look like a total
  # rewrite. Say nothing rather than something false.
  [ -s "$TMPD/defn.disk" ] || return 0
  if cmp -s "$TMPD/defn.loaded" "$TMPD/defn.disk"; then
    printf '  %-10s %s\n' 'loaded:' 'matches the plist on disk'
    return 0
  fi
  printf '  %-10s %s%s%s\n' 'loaded:' "$C_WARN" \
    'DIFFERS from the plist on disk - restart to apply' "$C_OFF"
  diff "$TMPD/defn.loaded" "$TMPD/defn.disk" 2>/dev/null \
    | sed -n 's/^< /             running: /p; s/^> /             on disk: /p'
}

# The command line as launchd would execute it: the program plus every
# argument, on one line. 'program: /bin/sh' tells you almost nothing when
# the plist is /bin/sh -c "the actual work".
plist_cmdline() {
  plutil -p "$1" 2>/dev/null | awk '
    function val(l) { sub(/^[^=]*=> /, "", l); gsub(/^"|"$/, "", l); return l }
    function quote(a) { return (a ~ /[ \t"]/) ? "\"" a "\"" : a }
    /^ *"ProgramArguments" *=> *\[/ { inargs = 1; next }
    inargs && /^ *\]/               { inargs = 0; next }
    inargs && /=>/                   { line = line (line == "" ? "" : " ") quote(val($0)); next }
    /^ *"Program" *=>/               { prog = val($0); next }
    END {
      # With both keys launchd runs Program with ProgramArguments as argv,
      # so argv[0] is only a name - the binary that runs is Program.
      if (prog != "" && line != "") print quote(prog) "   (argv: " line ")"
      else if (line != "")          print line
      else if (prog != "")          print quote(prog)
    }
  '
}

# Everything about the plist that launchd cares about and will not tell you.
# A refused bootstrap ('Input/output error') is usually one of these, and
# launchd names none of them.
plist_problems() {
  _pp=$1; _plab=$2
  [ -n "$_pp" ] && [ -r "$_pp" ] || return 0
  _bad=0

  if ! plutil -lint "$_pp" >/dev/null 2>&1; then
    printf '  %-10s %s%s%s\n' 'plist:' "$C_BAD" 'is NOT a valid property list:' "$C_OFF"
    plutil -lint "$_pp" 2>&1 | sed 's/^/             /'
    return 0
  fi
  _lab=$(plutil -extract Label raw -o - "$_pp" 2>/dev/null)
  if [ -z "$_lab" ]; then
    printf '  %-10s %s%s%s\n' '' "$C_BAD" 'no Label key - launchd ignores it entirely' "$C_OFF"
    _bad=1
  else
    _base=${_pp##*/}; _base=${_base%.plist}
    if [ "$_lab" != "$_base" ]; then
      printf '  %-10s %s\n' '' "note: the Label is '$_lab', the filename says '$_base'"
      printf '  %-10s %s\n' '' '      launchd uses the Label; the filename is only convention'
    fi
  fi
  if ! plutil -extract Program raw -o - "$_pp" >/dev/null 2>&1 \
     && ! plutil -extract ProgramArguments.0 raw -o - "$_pp" >/dev/null 2>&1; then
    printf '  %-10s %s%s%s\n' '' "$C_BAD" 'neither Program nor ProgramArguments - nothing to run' "$C_OFF"
    _bad=1
  fi

  # launchd REFUSES a plist that anyone but its owner can write, and says
  # only 'Input/output error' when it does.
  _st=$(stat -f '%Su %Sg %Lp' "$_pp" 2>/dev/null) || return 0
  _own=${_st%% *}; _r=${_st#* }; _grp=${_r%% *}; _mode=${_r##* }
  # 022 octal = group-write + other-write. Written as 22 it is DECIMAL 22,
  # which is 0026 - a mask that flags an innocent 644.
  if [ $(( 0$_mode & 022 )) != 0 ]; then
    printf '  %-10s %s%s%s\n' '' "$C_BAD" \
      "mode $_mode is group- or world-writable; launchd refuses such a plist" "$C_OFF"
    printf '  %-10s %s\n' '' "      chmod 644 $_pp"
    _bad=1
  fi
  case "$_pp" in
    /Library/LaunchDaemons/*|/System/Library/LaunchDaemons/*)
      if [ "$_own" != root ]; then
        printf '  %-10s %s%s%s\n' '' "$C_BAD" \
          "owned by $_own, but a system daemon plist must be owned by root" "$C_OFF"
        printf '  %-10s %s\n' '' "      chown root:wheel $_pp"
        _bad=1
      fi ;;
  esac
  [ "$_bad" = 0 ] && [ "$VRB" = 1 ] && \
    printf '  %-10s %s\n' '' "owner $_own:$_grp mode $_mode - acceptable to launchd"
  return 0
}

state_meaning() {
  case "$1" in
    on)     printf 'running-capable now and after a reload' ;;
    @on)    printf 'not loaded now, but it comes up after a reload' ;;
    off)    printf 'disabled; note a disabled service cannot be started at all' ;;
    @off)   printf 'still loaded now, but gone after a reload' ;;
    orphan) printf 'loaded, but no plist on disk' ;;
  esac
}

# ======================================================================
# log watermarks and the "since the last run" delta
# ======================================================================

mark_file() { printf '%s/marks/%s.%s' "$STATE_DIR" "$(printf '%s' "$DOMAIN" | tr / _)" "$1"; }

ensure_state_dir() {
  [ -d "$STATE_DIR/marks" ] && return 0
  mkdir -p "$STATE_DIR/marks" 2>/dev/null || return 1
  return 0
}

runs_of() {
  launchctl print "$DOMAIN/$1" 2>/dev/null | awk '/^[[:space:]]*runs =/ { print $3; exit }'
}

# Record the exact byte offsets BEFORE we act, so the next status is exact.
write_mark() {
  ensure_state_dir || return 0
  _mf=$(mark_file "$1")
  _eo=0; [ -n "$2" ] && [ -r "$2" ] && _eo=$(wc -c < "$2" | tr -d ' ')
  _oo=0; [ -n "$3" ] && [ -r "$3" ] && _oo=$(wc -c < "$3" | tr -d ' ')
  printf '%s\t%s\t%s\t%s\n' "$(runs_of "$1")" "$_eo" "$_oo" "$4" > "$_mf" 2>/dev/null
  return 0
}

# Show what each log gained since the service last started.
show_log_delta() {
  _l=$1; _ef=$2; _of=$3
  [ -n "$_ef$_of" ] || return 0
  _mf=$(mark_file "$_l")
  _runs=$(runs_of "$_l")
  _eo=; _oo=; _kind=

  if [ -r "$_mf" ]; then
    _mruns=$(cut -f1 "$_mf"); _eo=$(cut -f2 "$_mf"); _oo=$(cut -f3 "$_mf"); _kind=$(cut -f4 "$_mf")
    if [ "$_kind" = exact ] && [ -n "$_runs" ] && [ -n "$_mruns" ] && [ "$_runs" = "$_mruns" ]; then
      _hdr="since run #$_runs (exact)"
    elif [ "$_kind" = exact ]; then
      if [ -n "$_runs" ]; then _hdr="since run #$_runs (exact)"
      else _hdr='since my-lc last acted on it (exact)'; fi
    else
      if [ -n "$_runs" ]; then _hdr="since run #$_runs (approx - boundary from the last my-lc run)"
      else _hdr='since my-lc last looked (approx)'; fi
    fi
  elif [ -n "$_runs" ] && [ "$_runs" = 1 ]; then
    _eo=0; _oo=0; _hdr='the whole log (this service has run once)'
  else
    _hdr='no watermark yet - showing what the log holds'
  fi

  _shown=0
  _same=0
  [ -n "$_ef" ] && [ "$_ef" = "$_of" ] && _same=1
  for _which in stderr stdout; do
    if [ "$_which" = stderr ]; then _lf=$_ef; _off=$_eo; else _lf=$_of; _off=$_oo; fi
    [ -n "$_lf" ] || continue
    # One file serving both streams: show it once, named for what it is.
    if [ "$_same" = 1 ]; then
      [ "$_which" = stdout ] && continue
      _which='stderr+stdout (one file)'
    fi
    [ -e "$_lf" ] || continue
    if [ ! -r "$_lf" ]; then
      printf '\n  %s: not readable as %s; rerun as root\n' "$_which" "$(id -un)"
      continue
    fi
    _sz=$(wc -c < "$_lf" | tr -d ' ')
    [ -n "$_off" ] || _off=$(( _sz > 0 ? 0 : 0 ))
    # a shorter file than the mark means it was rotated or truncated
    if [ "$_sz" -lt "$_off" ] 2>/dev/null; then
      _off=0; _hdr="$_hdr [log was truncated, showing from the start]"
    fi
    _dsz=$(( _sz - _off ))
    [ "$_shown" = 0 ] && { printf '\n  %s%s%s\n' "$C_DIM" "$_hdr" "$C_OFF"; _shown=1; }

    # Nothing new is an answer, not a reason to show nothing: the tail of
    # the log is still the context you came for.
    if [ "$_dsz" -le 0 ] 2>/dev/null; then
      if [ "$_sz" -gt 0 ] 2>/dev/null; then
        printf '  %s%s:%s nothing new, last %s lines:\n' \
          "$C_HDR" "$_which" "$C_OFF" "$ERR_TAIL"
        tail -n "$ERR_TAIL" "$_lf" 2>/dev/null | sed 's/^/    /'
      else
        printf '  %s%s:%s empty\n' "$C_HDR" "$_which" "$C_OFF"
      fi
      continue
    fi

    # A crash-looping daemon can leave a gigabyte behind. Counting its lines
    # means reading all of it - 18 seconds of CPU to print ten lines - so a
    # large delta is measured in bytes, which is free, and the last lines are
    # taken with tail -n, which seeks from the END. When the delta is big,
    # the file's last N lines ARE the delta's last N lines.
    if [ "$_dsz" -gt "$BIG_DELTA" ] 2>/dev/null; then
      printf '  %s%s:%s %s new, last %s lines:\n' \
        "$C_HDR" "$_which" "$C_OFF" "$(human_size "$_dsz")" "$ERR_TAIL"
      tail -n "$ERR_TAIL" "$_lf" 2>/dev/null | sed 's/^/    /'
      continue
    fi

    # Small enough to read: an exact line count is worth having.
    # From offset 0 the file IS the delta, so count and tail it directly -
    # copying it first would read it twice and write it once for nothing.
    # From a non-zero offset, wc cannot count "lines after byte N", so the
    # delta has to be materialised; under BIG_DELTA that is cheap.
    if [ "$_off" -gt 0 ] 2>/dev/null; then
      tail -c "+$((_off + 1))" "$_lf" 2>/dev/null > "$TMPD/delta"
      _src="$TMPD/delta"
    else
      _src="$_lf"
    fi
    _nl=$(wc -l < "$_src" | tr -d ' ')
    if [ "$_nl" -gt "$ERR_TAIL" ] 2>/dev/null; then
      printf '  %s%s:%s %s new lines, last %s:\n' \
        "$C_HDR" "$_which" "$C_OFF" "$_nl" "$ERR_TAIL"
      tail -n "$ERR_TAIL" "$_src" | sed 's/^/    /'
    else
      printf '  %s%s:%s\n' "$C_HDR" "$_which" "$C_OFF"
      sed 's/^/    /' "$_src"
    fi
  done
  [ "$_shown" = 0 ] && printf '\n  %s%s: no log files exist yet%s\n' "$C_DIM" "$_hdr" "$C_OFF"
  # Refresh the approximate boundary for next time.
  [ "$_kind" = exact ] || write_mark "$_l" "$_ef" "$_of" approx
  return 0
}

# ======================================================================
# verbs
# ======================================================================

# The one place a launchctl mutation happens. Returns non-zero on failure.
# Every launchctl call that CHANGES something goes through here. Read-only
# calls do not: they work unprivileged, and refusing them would break the
# listing for a normal user.
lc() {
  if [ "$DOMAIN" = system ] && [ "$(id -u)" != 0 ]; then
    # Report it the same way as any other failure - one line, with the
    # evidence under it - rather than a separate error plus a second,
    # vaguer 'launchctl failed' from the caller.
    { printf 'needs root, and my-lc will not invoke sudo for you\n'
      printf 'the command it would have run:\n'
      printf '  launchctl %s\n' "$*"; } > "$TMPD/lcerr"
    printf '90' > "$TMPD/lcrc"
    return 90
  fi
  _o=$(run launchctl "$@" 2>&1); _rc=$?
  # Keep whatever it said either way: on success so a stale message from an
  # earlier call cannot be reprinted later, on failure so it can be shown.
  printf '%s' "$_o" > "$TMPD/lcerr"
  [ "$_rc" = 0 ] && { : > "$TMPD/lcerr"; return 0; }
  printf '%s' "$_rc" > "$TMPD/lcrc"
  return "$_rc"
}

# Turn launchctl's numeric complaints into the actual cause.
translate_lc_error() {
  _e=$(cat "$TMPD/lcerr" 2>/dev/null)
  case "$_e" in
    "needs root"*)                  printf 'needs root - rerun under sudo' ;;
    *"No such file or directory"*)  printf 'no such file (has the plist moved?)' ;;
    *"Service is disabled"*)        printf 'the service is disabled; enable it first' ;;
    *"Could not find service"*)     printf 'not loaded in this domain' ;;
    *"Operation not permitted"*)    printf 'not permitted (SIP, or not root)' ;;
    *"Input/output error"*)         printf 'launchd refused it - see the plist checks in "status"' ;;
    *"Bootstrap failed: 37"*)       printf 'already bootstrapped' ;;
    *"already loaded"*)             printf 'already loaded' ;;
    '')                             printf 'launchctl failed' ;;
    *)                              printf '%s' "$(printf '%s' "$_e" | head -n 1)" ;;
  esac
}

step_ok()   { [ "$QUIET" = 1 ] || { [ "$VRB" = 1 ] && printf '  done\n' || printf ' done\n'; }; }
# A failure prints the translated cause AND the command's own output. The
# translation is a summary; the raw text is the evidence, and hiding it
# means the user has to reproduce the failure by hand to see it.
step_fail() {
  [ "$QUIET" = 1 ] || { [ "$VRB" = 1 ] && printf '  FAILED' || printf ' FAILED'; printf ': %s\n' "$1"; }
  if [ -s "$TMPD/lcerr" ]; then
    _rc=$(cat "$TMPD/lcrc" 2>/dev/null)
    printf '    > launchctl exited %s and said:\n' "${_rc:-non-zero}" >&2
    sed 's/^/      /' "$TMPD/lcerr" >&2
    : > "$TMPD/lcerr"
  fi
  EXITCODE=1
}

act_on() {
  _label=$1; _plist=$2; _state=$3; _trig=$4; _ef=$5; _of=$6
  case "$VERB" in
    start)   v_start   ;;
    stop)    v_stop    ;;
    restart) v_restart ;;
    run)     v_run     ;;
    kill)    v_kill    ;;
    enable)  v_enable  ;;
    disable) v_disable ;;
    delete)  v_delete  ;;
    edit)    v_edit    ;;
    truncate) v_truncate ;;
  esac
}

v_start() {
  case "$_state" in
    off|@off) msg "$_label is disabled and cannot be started; 'enable' it first"
              printf '    > a disabled launchd service refuses bootstrap, unlike a\n' >&2
              printf '      disabled systemd unit, which you can still start by hand\n' >&2
              EXITCODE=1; return 0 ;;
    on)       msg "$_label is already started (armed on: $_trig)"
              det "'run' executes it now without waiting for that trigger"
              return 0 ;;
  esac
  [ -n "$_plist" ] || { msg "$_label has no plist on disk; nothing to start"; EXITCODE=1; return 0; }
  # launchctl bootstrap only REGISTERS the job - it returns 0 without ever
  # touching the program, so a missing binary is not discovered until
  # launchd execs it. Reporting 'done' for that is a false success, and
  # my-lc already knows better.
  case "$_dm" in system) _asu=${_us:-root} ;; *) _asu=${_us:-$AGENT_USER} ;; esac
  _pv=$(program_verdict "$_pr" "$_asu")
  if [ -z "$_pr" ]; then
    msg "$_label defines no program at all; launchd will reject it"
    printf '    > the plist needs a Program or ProgramArguments key\n' >&2
    EXITCODE=1; return 0
  fi
  case "$_pv" in
    ok|'?'*) ;;
    *) msg "$_label cannot start: its program is $_pv"
       [ -n "$_pr" ] && printf '    > %s\n' "$_pr" >&2
       printf '    > fix the program or the plist first; launchd would just fail to exec it\n' >&2
       EXITCODE=1; return 0 ;;
  esac
  write_mark "$_label" "$_ef" "$_of" exact
  msgn "starting $_label ..."; [ "$VRB" = 1 ] && printf '\n'
  det "bootstrap puts the service into the $DOMAIN domain for this boot"
  # bootout returns before launchd has finished releasing the label, so a
  # bootstrap straight afterwards can fail with 'Input/output error' even
  # though nothing is wrong. Give it a moment and try again rather than
  # leaving the service stopped, which is the worst outcome of a 'restart'.
  _try=1
  while :; do
    if lc bootstrap "$DOMAIN" "$_plist"; then
      # 'done' has to mean it worked, not merely that launchctl returned 0.
      if launchctl print "$DOMAIN/$_label" >/dev/null 2>&1; then
        step_ok
        [ "$_try" -gt 1 ] && msg "(it took $_try attempts; launchd was still releasing the old instance)"
      else step_fail 'launchctl reported success, but the service is not in the domain'; fi
      break
    fi
    if [ "$_try" -ge "$BOOTSTRAP_TRIES" ]; then
      step_fail "$(translate_lc_error)"
      # A failed start leaves the service DOWN. Say so plainly: it is not
      # obvious, and after a restart it is the opposite of what was wanted.
      printf '    > %s is now STOPPED. Try: %s %s start\n' \
        "$_label" "$SCRIPT_NAME" "$_label" >&2
      break
    fi
    _try=$((_try + 1))
    sleep 1
  done
}

v_stop() {
  case "$_state" in
    @on|off) msg "$_label is already stopped"; return 0 ;;
  esac
  msgn "stopping $_label ..."; [ "$VRB" = 1 ] && printf '\n'
  det "bootout removes it from the running domain; it returns at the next boot"
  if lc bootout "$DOMAIN/$_label"; then
    step_ok
    case "$_trig" in
      *boot*) det "this one has RunAtLoad, so it will be back after a reboot; 'disable' is the permanent form" ;;
    esac
  else step_fail "$(translate_lc_error)"; fi
}

v_restart() {
  if [ "$_state" = '@on' ] || [ "$_state" = off ]; then
    msg "$_label is not started"
    v_start; return 0
  fi
  v_stop
  _state=@on
  v_start
}

v_run() {
  case "$_state" in
    off|@off) msg "$_label is disabled; 'enable' it first"; EXITCODE=1; return 0 ;;
    @on)      msg "$_label is not started; 'start' it first"; EXITCODE=1; return 0 ;;
  esac
  write_mark "$_label" "$_ef" "$_of" exact
  msgn "running $_label ..."; [ "$VRB" = 1 ] && printf '\n'
  det "kickstart -k runs the program now, restarting it if it is already up"
  if lc kickstart -k "$DOMAIN/$_label"; then step_ok; else step_fail "$(translate_lc_error)"; fi
}

v_kill() {
  case "$_state" in
    @on|off) msg "$_label is not running; nothing to signal"; return 0 ;;
  esac
  msgn "signalling $_label with SIG$KILLSIG ..."; [ "$VRB" = 1 ] && printf '\n'
  det "kill signals the process; the service itself stays started"
  if lc kill "$KILLSIG" "$DOMAIN/$_label"; then
    step_ok
    case "$_trig" in
      *keep*) msg "$_label has KeepAlive, so launchd is restarting it right now"
              det "'stop' is the verb that makes it stay down until the next reboot" ;;
    esac
  else step_fail "$(translate_lc_error)"; fi
}

v_enable() {
  if [ "$_state" = on ]; then
    [ "$NOW" = 1 ] && { msg "$_label is already enabled and started"; return 0; }
    msg "$_label is already enabled"; return 0
  fi
  if [ "$_state" = '@on' ] && [ "$NOW" = 0 ]; then
    msg "$_label is already enabled for boot (not started - 'enable --now' or 'start')"
    return 0
  fi
  if [ "$_state" != '@on' ]; then
    msgn "enabling $_label ..."; [ "$VRB" = 1 ] && printf '\n'
    det "clears the persistent disabled flag; this alone does NOT start it"
    if lc enable "$DOMAIN/$_label"; then step_ok; else step_fail "$(translate_lc_error)"; return 0; fi
  fi
  if [ "$NOW" = 1 ]; then
    [ -n "$_plist" ] || { msg "$_label has no plist on disk; cannot start it"; EXITCODE=1; return 0; }
    write_mark "$_label" "$_ef" "$_of" exact
    msgn "starting $_label ..."; [ "$VRB" = 1 ] && printf '\n'
    if lc bootstrap "$DOMAIN" "$_plist"; then step_ok; else step_fail "$(translate_lc_error)"; fi
  else
    msg "$_label is enabled for boot (not started - add --now, or 'start' it)"
  fi
}

v_disable() {
  if [ "$NOW" = 1 ] && { [ "$_state" = on ] || [ "$_state" = '@off' ]; }; then
    msgn "stopping $_label ..."; [ "$VRB" = 1 ] && printf '\n'
    det "bootout first, so the running instance goes away too"
    if lc bootout "$DOMAIN/$_label"; then step_ok; else step_fail "$(translate_lc_error)"; fi
  fi
  case "$_state" in
    off|@off) msg "$_label is already disabled"; return 0 ;;
  esac
  msgn "disabling $_label ..."; [ "$VRB" = 1 ] && printf '\n'
  det "sets the persistent flag; it will not come back at the next boot"
  if lc disable "$DOMAIN/$_label"; then
    step_ok
    [ "$NOW" = 0 ] && [ "$_state" = on ] && \
      msg "$_label is still running (add --now, or 'stop' it)"
  else step_fail "$(translate_lc_error)"; fi
}

# Empty a service's log files. Truncating in place (rather than deleting and
# recreating) matters: launchd holds the file open, so a new file would be
# written to by nobody while the daemon kept appending to the unlinked one.
v_truncate() {
  _did=0
  for _stream in stderr stdout; do
    case "$TRUNC_WHAT" in
      both) ;;
      "$_stream") ;;
      *) continue ;;
    esac
    if [ "$_stream" = stderr ]; then _tf=$_ef; else _tf=$_of; fi
    [ -n "$_tf" ] || continue
    # one file serving both streams must not be emptied twice
    if [ "$_stream" = stdout ] && [ -n "$_ef" ] && [ "$_ef" = "$_of" ]; then continue; fi
    if [ ! -e "$_tf" ]; then msg "$_label: no $_stream log at $_tf"; continue; fi
    if [ ! -f "$_tf" ]; then msg "$_label: $_stream is $_tf, not a regular file - left alone"; continue; fi
    _tsz=$(wc -c < "$_tf" 2>/dev/null | tr -d ' ')
    if [ "${_tsz:-0}" = 0 ]; then msg "$_label: $_stream log is already empty"; continue; fi
    _lbl=$_stream
    [ -n "$_ef" ] && [ "$_ef" = "$_of" ] && _lbl='stderr+stdout'
    msgn "emptying the $_lbl log of $_label ($(human_size "$_tsz")) ..."
    [ "$VRB" = 1 ] && printf '\n'
    det "$_tf"
    det "truncated in place: launchd holds it open, so unlinking would orphan it"
    if run truncate -s 0 "$_tf"; then _did=1; step_ok
    else step_fail 'could not truncate (needs root?)'; fi
  done
  # The watermark's offsets point past the end of an emptied file, so reset
  # it; otherwise the next status would report a truncation that my-lc did.
  [ "$_did" = 1 ] && write_mark "$_label" "$_ef" "$_of" exact
  return 0
}

# Everything my-lc has deleted, newest first: label, when, and where it
# came from. Scans both destinations, since DELETE_MODE may have changed
# between the delete and the undelete.
#   out: backup-path <TAB> label <TAB> epoch <TAB> origin-plist
deleted_list() {
  for _dd in "$STATE_DIR/deleted" "${HOME:-/nonexistent}/.Trash"; do
    [ -d "$_dd" ] || continue
    for _bf in "$_dd"/*.plist "$_dd"/*.plist.*; do
      [ -f "$_bf" ] || continue
      case "$_bf" in *.origin) continue ;; esac
      _bl=${_bf##*/}
      # <label>.plist or <label>.plist.<timestamp>
      _bl=${_bl%.plist}; _bl=${_bl%.plist.*}
      case "$_bl" in *.plist) _bl=${_bl%.plist} ;; esac
      _bo=
      [ -r "$_bf.origin" ] && _bo=$(head -n 1 "$_bf.origin" 2>/dev/null)
      if [ -z "$_bo" ]; then
        # A plist in the Trash with no origin note was NOT put there by
        # my-lc - the user's own Trash is full of things it knows nothing
        # about. Offering to install one, to a guessed location, would be
        # reckless: skip it, and say so under -V.
        case "$_dd" in
          "$STATE_DIR/deleted") ;;
          *) [ "$VRB" = 1 ] && printf 'skipping %s: not deleted by %s\n' \
               "$_bf" "$SCRIPT_NAME" >&2
             continue ;;
        esac
        # Inside my-lc's own folder, an origin note may simply predate the
        # version that started writing one: fall back to where a service of
        # this scope belongs.
        case "$SCOPE" in
          agents) _bo="$HOME/Library/LaunchAgents/$_bl.plist" ;;
          *)      _bo="/Library/LaunchDaemons/$_bl.plist" ;;
        esac
      fi
      printf '%s%s%s%s%s%s%s\n' "$_bf" "$FS1" "$_bl" "$FS1" \
        "$(file_epoch "$_bf")" "$FS1" "$_bo"
    done
  done | sort -t"$FS1" -k3,3nr
}

v_undelete() {
  _bf=$1; _label=$2; _when=$3; _origin=$4
  if [ -e "$_origin" ]; then
    err "$_label: something is already at $_origin"
    printf '    > move it aside first, or restore the backup by hand\n' >&2
    return 0
  fi
  msgn "putting $_label back ..."; [ "$VRB" = 1 ] && printf '\n'
  det "$_bf"
  det "-> $_origin"
  if run mv "$_bf" "$_origin"; then step_ok
  else step_fail 'could not move it back (needs root?)'; return 0; fi
  rm -f "$_bf.origin" 2>/dev/null
  # delete disabled it, so undelete must clear that or it stays off
  msgn "re-enabling $_label ..."; [ "$VRB" = 1 ] && printf '\n'
  det 'delete disabled it as well as removing it; this undoes that half'
  if lc enable "$DOMAIN/$_label"; then step_ok; else step_fail "$(translate_lc_error)"; fi
  if [ "$NOW" = 1 ]; then
    msgn "starting $_label ..."; [ "$VRB" = 1 ] && printf '\n'
    if lc bootstrap "$DOMAIN" "$_origin"; then step_ok; else step_fail "$(translate_lc_error)"; fi
  else
    msg "$_label is restored and enabled, but not started (add --now, or 'start' it)"
  fi
}

# Where a deleted plist goes, and what to call that place. The Trash is the
# default: it is where a deleted file belongs, Finder can restore it, and it
# needs no explaining. Prints nothing if neither destination can be made,
# in which case the caller unlinks instead.
delete_where() {
  case "$DELETE_MODE" in
    trash) printf 'the Trash' ;;
    *)     printf 'the deleted folder' ;;
  esac
}

delete_destination() {
  case "$DELETE_MODE" in
    trash)
      [ -n "${HOME:-}" ] || return 0
      mkdir -p "$HOME/.Trash" 2>/dev/null || return 0
      # Finder refuses to overwrite in the Trash, and neither should we:
      # a second delete of the same label must not clobber the first.
      if [ -e "$HOME/.Trash/$1.plist" ]; then
        printf '%s/.Trash/%s.plist.%s' "$HOME" "$1" "$(date '+%Y%m%d-%H%M%S')"
      else
        printf '%s/.Trash/%s.plist' "$HOME" "$1"
      fi ;;
    *)
      ensure_state_dir || return 0
      mkdir -p "$STATE_DIR/deleted" 2>/dev/null || return 0
      printf '%s/deleted/%s.plist.%s' "$STATE_DIR" "$1" "$(date '+%Y%m%d-%H%M%S')" ;;
  esac
}

# Remove a launch item for good: stop it, then take its plist out of the
# way. The plist is MOVED to a dated backup rather than unlinked - undoing a
# delete should not need a reinstall.
v_delete() {
  [ -n "$_plist" ] || { msg "$_label has no plist on disk; nothing to delete"; EXITCODE=1; return 0; }
  case "$_plist" in
    /System/Library/*) msg "$_label is SIP-protected; macOS will not let it be removed"
                       EXITCODE=1; return 0 ;;
  esac
  if [ "$_state" = on ] || [ "$_state" = '@off' ]; then
    msgn "stopping $_label ..."; [ "$VRB" = 1 ] && printf '\n'
    if lc bootout "$DOMAIN/$_label"; then step_ok; else step_fail "$(translate_lc_error)"; fi
  fi
  # Disable as well as remove: if whatever installed this plist puts it back
  # - an app re-blessing its helper, say - the flag keeps the service off,
  # which removing the file alone would not.
  case "$_state" in
    off|@off) ;;
    *) msgn "disabling $_label ..."; [ "$VRB" = 1 ] && printf '\n'
       det "so it stays off even if its plist is reinstalled later"
       if lc disable "$DOMAIN/$_label"; then step_ok; else step_fail "$(translate_lc_error)"; fi ;;
  esac
  _dest=$(delete_destination "$_label")
  if [ -n "$_dest" ]; then
    msgn "moving the plist to $(delete_where) ..."; [ "$VRB" = 1 ] && printf '\n'
    det "$_plist"
    det "-> $_dest"
    if run mv "$_plist" "$_dest"; then
      step_ok
      # Remember where it came from: the backup name carries the label and
      # a date, not the directory, and 'undelete' must put it back exactly
      # where it was rather than guess.
      printf '%s\n%s\n' "$_plist" "$DOMAIN" > "$_dest.origin" 2>/dev/null || true
      msg "$_dest"
    else step_fail 'could not move the plist (needs root?)'; fi
  else
    msgn "removing $_plist ..."; [ "$VRB" = 1 ] && printf '\n'
    if run rm -f "$_plist"; then step_ok; else step_fail 'could not remove the plist (needs root?)'; fi
  fi
  msg "$_label is now stopped, disabled, and its plist is out of the way"
}

# Re-read the fields the action verbs use, straight from the plist. After an
# edit the record built at startup is STALE: 'restart' went on using the old
# program path and refused to start a service whose plist had just been
# corrected - after already stopping it.
refresh_from_plist() {
  [ -n "$1" ] && [ -r "$1" ] || return 0
  _np=$(plutil -extract Program raw -o - "$1" 2>/dev/null) \
    || _np=$(plutil -extract ProgramArguments.0 raw -o - "$1" 2>/dev/null) || _np=
  [ -n "$_np" ] && _pr=$_np
  _ne=$(plutil -extract StandardErrorPath raw -o - "$1" 2>/dev/null) || _ne=
  _no=$(plutil -extract StandardOutPath  raw -o - "$1" 2>/dev/null) || _no=
  _nu=$(plutil -extract UserName         raw -o - "$1" 2>/dev/null) || _nu=
  _ef=$_ne; _of=$_no; _us=$_nu
  return 0
}

# Open the plist in the user's editor, then check what came back.
v_edit() {
  [ -n "$_plist" ] || { err "$_label has no plist on disk to edit"; return 0; }
  case "$_plist" in
    /System/Library/*) err "$_label is SIP-protected; its plist cannot be edited"; return 0 ;;
  esac
  _ed=${EDITOR_CMD:-${VISUAL:-${EDITOR:-vi}}}
  command -v "${_ed%% *}" >/dev/null 2>&1 \
    || die "editor not found: $_ed  (set EDITOR, or EDITOR_CMD in the config)"
  [ -w "$_plist" ] || [ "$(id -u)" = 0 ] \
    || warn "$_plist is not writable by $(id -un); the editor may refuse to save"
  _before=$(shasum -a 256 "$_plist" 2>/dev/null | cut -d' ' -f1)
  msg "editing $_plist with $_ed"
  # The editor inherits my-lc's own stdin, which is the terminal. That only
  # works because the action loop reads its work list on fd 3: while it read
  # on stdin, the editor got a FILE as its input, reported "Input is not from
  # a terminal", and left the terminal mode broken afterwards. Redirecting
  # from /dev/tty here instead would fail outright where there is no
  # controlling terminal, e.g. under a test harness or from cron.
  run "$_ed" "$_plist"
  _after=$(shasum -a 256 "$_plist" 2>/dev/null | cut -d' ' -f1)
  if [ "$_before" = "$_after" ]; then
    msg "unchanged"
    return 0
  fi
  # A malformed plist is silently ignored by launchd, so check it here.
  # 'plutil -lint' alone is too weak: it accepts a bare word, because that
  # is a valid old-style plist string. launchd needs a DICT WITH A LABEL,
  # so that is what gets checked.
  if ! plutil -lint "$_plist" >/dev/null 2>&1; then
    err "the plist is NOT valid any more:"
    plutil -lint "$_plist" 2>&1 | sed 's/^/    /' >&2
    printf '    > launchd ignores a malformed plist; fix it or restore the backup\n' >&2
    return 0
  fi
  if ! plutil -extract Label raw -o - "$_plist" >/dev/null 2>&1; then
    err "the plist parses, but it is NOT a launchd job any more"
    printf '    > it needs to be a dictionary with a Label key\n' >&2
    printf '    > launchd ignores it as it stands\n' >&2
    return 0
  fi
  msg "saved; it is a valid launchd job"
  # Everything below acts on the NEW definition, so stop using the stale one.
  refresh_from_plist "$_plist"
  _newlab=$(plutil -extract Label raw -o - "$_plist" 2>/dev/null)
  [ -n "$_newlab" ] && [ "$_newlab" != "$_label" ] && \
    msg "note: the Label is now '$_newlab' - the old service keeps the old name until reloaded"
  # Editing a plist changes the FILE. The running service keeps the
  # definition it was bootstrapped with, and the next boot reads the file -
  # so "now" and "at every boot" are two separate questions, and the answer
  # to each depends on the state the service is in.
  _needrestart=0; _needenable=0
  case "$_state" in
    on|@off) _needrestart=1 ;;
  esac
  case "$_state" in
    off|@off) _needenable=1 ;;
  esac
  if [ "$_needrestart" = 1 ]; then
    msg "$_label is still running the OLD definition:"
    show_loaded_diff "$_label" "$DOMAIN" "$_plist" | sed 's/^/  /'
  fi
  [ "$_needenable" = 1 ] && \
    msg "$_label is disabled, so the next boot will NOT pick this up either"
  if [ "$_needrestart" = 0 ] && [ "$_needenable" = 0 ]; then
    msg "$_label is not loaded; the next boot will use the new definition"
    msg "'start' it to use it now as well"
    return 0
  fi

  # Offer exactly the steps this service needs, and do nothing without the
  # agreed word.
  printf '\napply it?\n'
  [ "$_needrestart" = 1 ] && printf '  - restart %s, so the change takes effect now\n' "$_label"
  [ "$_needenable" = 1 ]  && printf '  - enable %s, so every boot picks it up\n' "$_label"
  [ "$_needrestart" = 0 ] && [ "$_needenable" = 1 ] && \
    printf '  - and start it, so it runs now too\n'
  if [ "$GO" = 1 ]; then
    printf '(--go given)\n'
  else
    printf 'type go: '
    if [ -t 0 ]; then read -r _ans; else _ans=; fi
    if [ "$_ans" != go ]; then
      printf 'nothing done - the file is saved, the running service is unchanged\n'
      return 0
    fi
  fi
  if [ "$_needenable" = 1 ]; then
    msgn "enabling $_label ..."; [ "$VRB" = 1 ] && printf '\n'
    if lc enable "$DOMAIN/$_label"; then step_ok; else step_fail "$(translate_lc_error)"; fi
  fi
  if [ "$_needrestart" = 1 ]; then
    _state=on
    v_restart
  else
    _state=@on
    v_start
  fi
}

# ======================================================================
# zsh completion — installed transparently on every run, idempotent
# ======================================================================

install_zsh_completions() {
  [ -n "${HOME:-}" ] || return 0
  _comp_dir="$HOME/.zsh/completions"
  _comp_file="$_comp_dir/_my-lc"
  _tmp=$(mktemp 2>/dev/null) || return 0
  cat >"$_tmp" <<'COMPLETION_EOF'
#compdef my-lc

# Descriptions here contain spaces, commas and '|'. That rules out
# _alternative's "tag:descr:((list))" form, whose list is eval'd and must be
# space-separated - it failed with a parse error near '|'. _describe takes
# the array by NAME and needs no quoting gymnastics.
_my-lc() {
    local -a verbs opts labels
    local verb w

    verbs=(
        'status:Record view for one service, the table for many'
        'list:Always the table'
        'start:Make it active in this boot session'
        'stop:Make it inactive until the next reboot'
        'restart:Stop it, then start it again'
        'run:Execute the program now, ignoring its trigger'
        'runnow:Execute the program now, ignoring its trigger'
        'kill:Signal the running process (default TERM)'
        'enable:Arm it for boot; add --now to start it too'
        'disable:Stop it coming back at boot; --now stops it too'
        'edit:Open the plist in an editor, then check it'
        'delete:Stop it, disable it, and move its plist aside'
        'truncate:Empty its logs; truncate err or truncate out'
        'undelete:Put a deleted plist back and re-enable it'
    )

    opts=(
        '--enabled:Only services that could run or are running'
        '--disabled:Only services that are switched off'
        '--all:No state filter'
        '--apple:Only Apple system services'
        '--with-apple:Add Apple services to the selection'
        '--running:Only services with a live process'
        '--failed:Only services whose last exit was non-zero'
        '--stderr:Only services defining StandardErrorPath'
        '--stdout:Only services defining StandardOutPath'
        '--agents:Act on LaunchAgents instead of daemons'
        '--both:Daemons and agents together'
        '--uid:Which gui domain to act on'
        '--now:With enable or disable, apply it to this session too'
        '--go:Carry out the action without asking'
        '--quiet:Silence progress narration'
        '--verbose:Echo each launchctl command'
        '--debug:Debug diagnostics'
        '--config:Use this file as the config'
        '--create-config:Write the default config'
        '--run-tests:Run the built-in self-tests'
        '--stamp-version:Record the current commit in this file'
        '--version:Version and build id'
        '--help:Full help'
    )

    # Which verb is already on the line? The label set depends on it.
    for w in ${words[2,-1]}; do
        case $w in
            status|list|start|stop|restart|run|runnow|kill|enable|disable|edit|delete|truncate|undelete)
                verb=$w
                break
                ;;
        esac
    done

    if [[ ${words[CURRENT]} == -* ]]; then
        _describe -t options 'option' opts
        return
    fi

    # 'truncate' takes a stream name, the way 'kill' takes a signal.
    if [[ $verb == truncate && ${words[CURRENT-1]} == truncate ]]; then
        local -a streams
        streams=('err:Only the stderr log' 'out:Only the stdout log')
        _describe -t streams 'stream' streams
    fi
    if [[ $verb == kill && ${words[CURRENT-1]} == kill ]]; then
        local -a sigs
        sigs=(HUP INT QUIT KILL TERM USR1 USR2 STOP CONT)
        _describe -t signals 'signal' sigs
    fi

    [[ -z $verb ]] && _describe -t verbs 'verb' verbs

    labels=(${(f)"$(my-lc --complete-labels $verb 2>/dev/null)"})
    (( ${#labels} )) && _describe -t services 'service' labels
}

_my-lc "$@"
COMPLETION_EOF

  _changed=0
  if [ -r "$_comp_file" ] && cmp -s "$_tmp" "$_comp_file" 2>/dev/null; then
    rm -f "$_tmp"
  else
    mkdir -p "$_comp_dir" 2>/dev/null || { rm -f "$_tmp"; return 0; }
    mv "$_tmp" "$_comp_file" 2>/dev/null || { rm -f "$_tmp"; return 0; }
    _changed=1
  fi
  # mktemp makes 600, and compinit then silently refuses to load the file.
  if [ -r "$_comp_file" ]; then
    case "$(stat -f '%Lp' "$_comp_file" 2>/dev/null)" in
      644) ;;
      *) chmod 644 "$_comp_file" 2>/dev/null && _changed=1 ;;
    esac
  fi
  # A stale zcompdump would keep the old file, so invalidate it on change.
  [ "$_changed" = 1 ] && rm -f "$HOME"/.zcompdump* 2>/dev/null

  _zshrc="$HOME/.zshrc"
  [ -f "$_zshrc" ] || return 0
  grep -q '\.zsh/completions' "$_zshrc" 2>/dev/null && return 0
  if grep -q 'oh-my-zsh\.sh' "$_zshrc" 2>/dev/null; then
    _trc=$(mktemp 2>/dev/null) || return 0
    awk -v cdir="$_comp_dir" '
      !ins && /oh-my-zsh\.sh/ { print "# my-lc zsh completions"; print "fpath=(" cdir " $fpath)"; ins=1 }
      { print }' "$_zshrc" >"$_trc" 2>/dev/null && mv "$_trc" "$_zshrc" 2>/dev/null
    rm -f "$_trc"
  else
    { printf '\n# my-lc zsh completions\n'
      # shellcheck disable=SC2016  # $fpath must reach .zshrc unexpanded
      printf 'fpath=(%s $fpath)\n' "$_comp_dir"
      printf 'autoload -Uz compinit && compinit\n'; } >>"$_zshrc" 2>/dev/null || true
  fi
  return 0
}

# The fast path the completion calls: labels only, narrowed by verb.
complete_labels() {
  case "$COMPLETE_VERB" in
    enable)          awk -F"$FS1" '$5=="off"  || $5=="@off"' "$DB" ;;
    disable)         awk -F"$FS1" '$5=="on"   || $5=="@on"'  "$DB" ;;
    start)           awk -F"$FS1" '$5=="@on"'                "$DB" ;;
    stop|restart|run|runnow) awk -F"$FS1" '$5=="on" || $5=="@off"' "$DB" ;;
    kill)            awk -F"$FS1" '$7 ~ /^run /'             "$DB" ;;
    edit|delete)     awk -F"$FS1" '$3 != "" && $3 !~ /^\/System\/Library\//' "$DB" ;;
    truncate)        awk -F"$FS1" '$12 != "" || $13 != ""' "$DB" ;;
    *)               cat "$DB" ;;
  esac | cut -d"$FS1" -f1 | sort -u
}

# ======================================================================
# argument parsing
# ======================================================================

is_verb() {
  case "$1" in
    status|list|start|stop|restart|run|runnow|kill|enable|disable|delete|edit|truncate|undelete) return 0 ;;
  esac
  return 1
}

parse_args() {
  _want_uid=0; _want_cfg=0; _want_ccfg=0; _want_dbglog=0; _want_tests=0
  _ccfg_seen=0; _ccfg_file=
  while [ $# -gt 0 ]; do
    _a=$1
    if [ "$_want_uid"    = 1 ]; then UID_OVERRIDE=$_a;     _want_uid=0;    shift; continue; fi
    if [ "$_want_cfg"    = 1 ]; then CONFIG_OVERRIDE=$_a;  _want_cfg=0;    shift; continue; fi
    case "$_a" in
      --) shift; break ;;
      --config=*)        CONFIG_OVERRIDE=${_a#*=} ;;
      --config)          _want_cfg=1 ;;
      --create-config=*) _ccfg_seen=1; _ccfg_file=${_a#*=} ;;
      --create-config)   _ccfg_seen=1
                         case "${2:-}" in -*|'') ;; *) _ccfg_file=$2; shift ;; esac ;;
      --uid=*)           UID_OVERRIDE=${_a#*=} ;;
      --uid)             _want_uid=1 ;;
      --run-tests)       TESTS=1
                         case "${2:-}" in agents|daemons) TESTS_SCOPE=$2; shift ;; esac ;;
      --run-tests=*)     TESTS=1; TESTS_SCOPE=${_a#*=} ;;
      --complete-labels) COMPLETE=1
                         case "${2:-}" in -*|'') ;; *) COMPLETE_VERB=$2; shift ;; esac ;;
      --enabled)     FILTER_STATE=enabled ;;
      --disabled)    FILTER_STATE=disabled ;;
      --all)         FILTER_STATE=all
                     [ -z "$APPLE_MODE" ] && { [ "$ALL_MEANS" = with-apple ] && APPLE_MODE=include || APPLE_MODE=exclude; } ;;
      --apple)       APPLE_MODE=only ;;
      --with-apple)  APPLE_MODE=include ;;
      --running)     WANT_RUNNING=1 ;;
      --failed)      WANT_FAILED=1 ;;
      --stderr)      WANT_STDERR=1 ;;
      --stdout)      WANT_STDOUT=1 ;;
      --agents)      SCOPE=agents ;;
      --both)        SCOPE=both ;;
      --daemons)     SCOPE=daemons ;;
      --now)         NOW=1 ;;
      --go)          GO=1 ;;
      -Q|--quiet)    QUIET=1 ;;
      -V|--verbose)  VRB=1 ;;
      -D|--debug)    DBG=1
                     case "${2:-}" in -*|'') ;; *) DBG_LOG=$2; shift ;; esac ;;
      -DD|--deepdebug) DEEPDBG=1
                     case "${2:-}" in -*|'') ;; *) DBG_LOG=$2; shift ;; esac ;;
      --version)     WANT_VERSION=1 ;;
      --stamp-version) WANT_STAMP=1 ;;
      -h)            usage_short; exit 0 ;;
      --help)        usage; exit 0 ;;
      # Recognise, never guess: the legacy names mean two different things.
      load|unload)
        printf "* '%s' is launchd's legacy name and means two different things. Do you mean:\n" "$_a"
        if [ "$_a" = load ]; then
          printf "    > 'start'          (launchctl load)      start it now, not enabled at boot\n"
          printf "    > 'enable --now'   (launchctl load -w)   start it now, and enable at boot\n"
        else
          printf "    > 'stop'           (launchctl unload)    stop it now, still enabled at boot\n"
          printf "    > 'disable --now'  (launchctl unload -w) stop it now, and disable at boot\n"
        fi
        exit 1 ;;
      -w)
        printf "* '-w' is the legacy flag that also changed the boot setting.\n"
        printf "    > with 'start' or 'stop' you want 'enable --now' / 'disable --now'\n"
        exit 1 ;;
      -*)
        die "unknown option: $_a  (try -h)" ;;
      # 'go' releases the confirmation AT THE PROMPT, never on the command
      # line. Left as a filter word it silently matched anything containing
      # 'go' - com.paragon-software, for one - and looked like it worked.
      go)
        printf "%s: 'go' is not a filter word.\n" "$SCRIPT_NAME" >&2
        printf "    > type 'go' at the confirmation prompt, or pass --go\n" >&2
        printf "    > e.g. my-lc <service> delete --go\n" >&2
        exit 1 ;;
      *)
        if is_verb "$_a"; then
          # Verbs chain, and run in the order typed: 'truncate restart' is a
          # natural pair - clear the logs, then restart and watch fresh
          # output. Refusing the second one made the user run two commands
          # and lose that ordering guarantee.
          VERB=$_a
          [ "$VERB" = runnow ] && VERB=run
          case " $VERBS " in
            *" $VERB "*) die "the verb '$VERB' was given twice" ;;
          esac
          VERBS="$VERBS$VERB "
          # 'kill' may take a signal name as the next word
          if [ "$VERB" = kill ]; then
            case "${2:-}" in
              HUP|INT|QUIT|KILL|TERM|USR1|USR2|STOP|CONT) KILLSIG=$2; shift ;;
            esac
          fi
          # 'truncate' takes an optional stream, the way 'kill' takes a signal
          if [ "$VERB" = truncate ]; then
            case "${2:-}" in
              stderr|err) TRUNC_WHAT=stderr; shift ;;
              stdout|out) TRUNC_WHAT=stdout; shift ;;
              both)       TRUNC_WHAT=both;   shift ;;
            esac
          fi
        else
          FILTERS="$FILTERS $_a"
        fi ;;
    esac
    shift
  done
  if [ "$_ccfg_seen" = 1 ]; then create_config "$_ccfg_file"; exit 0; fi
}

# --now only means something on enable/disable. Anything else is a near-miss
# worth naming rather than an unknown-combination error.
check_now_misuse() {
  [ "$NOW" = 1 ] || return 0
  case "$VERB" in
    enable|disable|'') return 0 ;;
  esac
  printf "* '%s --now' is not a thing: %s already acts now.\n" "$VERB" "$VERB"
  printf "    > --now exists only to add that to 'enable' and 'disable'\n"
  exit 1
}

# --version identifies the EXACT bytes being run, so two copies can be
# compared by running each and diffing the output. It does NOT go looking
# for other copies: a tool has no business knowing where its own source
# lives, and hard-coding those paths made it wrong the moment anything moved.
# The build id is a hash of this file's own content, so it is always
# accurate with nothing to stamp or remember to bump.
# The authoritative identity: the stamped commit when there is one, else a
# hash of this file's content. Either way two copies can be compared by
# running each and diffing the output.
script_version_string() {
  # The build id is ALWAYS shown and is the authoritative identity: it is
  # computed from this file's bytes, so it cannot be stale or wrong. The
  # commit is provenance only - it is stamped by hand and will silently
  # point at the wrong commit if someone edits after stamping, so it must
  # never be what two copies are compared on.
  if [ -n "$SCRIPT_COMMIT" ]; then
    printf '%s (build %s, from commit %s)' "$SCRIPT_VERSION" "$(build_id)" "$SCRIPT_COMMIT"
  else
    printf '%s (build %s)' "$SCRIPT_VERSION" "$(build_id)"
  fi
}

build_id() {
  _bi=$(shasum -a 256 "$0" 2>/dev/null | cut -c1-12)
  [ -n "$_bi" ] || _bi=$(cksum < "$0" 2>/dev/null | cut -d" " -f1)
  printf '%s' "${_bi:-unknown}"
}

show_version() {
  printf '%s %s\n' "$SCRIPT_NAME" "$(script_version_string)"
  [ "$VRB" = 1 ] && printf '  %s\n' "$0"
  return 0
}

# Record the current HEAD short sha in SCRIPT_COMMIT, then amend HEAD so the
# in-tree file carries it. Run as the last step before a deploy.
#
# The stamped sha necessarily lags HEAD by one: amending changes the commit
# sha, and a commit's sha depends on content that now includes the stamp.
# That is unavoidable, not a bug - SCRIPT_COMMIT names the commit whose
# CONTENT this build was made from.
stamp_version() {
  _here=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || die 'cannot resolve my own directory'
  _self="$_here/$(basename "$0")"
  [ -f "$_self" ] || die "cannot locate myself at $_self"
  command -v git >/dev/null 2>&1 || die 'git is not on PATH'
  git -C "$_here" rev-parse --show-toplevel >/dev/null 2>&1 \
    || die "not a git repository: $_here"

  # Never fold unrelated edits into someone else's commit via --amend.
  _dirty=$(git -C "$_here" diff --name-only 2>/dev/null | grep -v "^$(basename "$0")$")
  if [ -n "$_dirty" ]; then
    printf '%s: uncommitted changes in other files:\n' "$SCRIPT_NAME" >&2
    printf '%s\n' "$_dirty" | sed 's/^/  /' >&2
    die 'commit or stash those first, then re-run --stamp-version'
  fi

  _new=$(git -C "$_here" rev-parse --short HEAD 2>/dev/null) \
    || die 'the repository has no commits yet - commit first'
  _cur=$(awk -F\" '/^SCRIPT_COMMIT=/ { print $2; exit }' "$_self")
  if [ "$_new" = "$_cur" ]; then
    printf 'SCRIPT_COMMIT already matches HEAD (%s); nothing to do\n' "$_new"
    return 0
  fi

  # Write via a temp file and mv: replacing the inode leaves the running
  # copy intact, whereas rewriting in place can corrupt a script mid-read.
  _tmp=$(mktemp) || die 'could not create a temp file'
  sed "s|^SCRIPT_COMMIT=\"[^\"]*\"|SCRIPT_COMMIT=\"$_new\"|" "$_self" > "$_tmp" \
    || { rm -f "$_tmp"; die 'could not rewrite SCRIPT_COMMIT'; }
  _mode=$(stat -f '%Lp' "$_self" 2>/dev/null)
  mv "$_tmp" "$_self" || { rm -f "$_tmp"; die 'could not replace the file'; }
  [ -n "$_mode" ] && chmod "$_mode" "$_self"
  printf 'stamped SCRIPT_COMMIT: %s -> %s\n' "${_cur:-<empty>}" "$_new"

  git -C "$_here" add "$_self" || die 'git add failed'
  git -C "$_here" commit --amend --no-edit --no-verify >/dev/null 2>&1 \
    || die 'git amend failed'
  _head=$(git -C "$_here" rev-parse --short HEAD)
  printf 'amended HEAD, now %s\n' "$_head"
  printf '  > SCRIPT_COMMIT=%s names the commit this content came from;\n' "$_new"
  printf '    it lags HEAD by one because amending changed HEAD\047s sha.\n'
}

# ======================================================================
# main
# ======================================================================

# shellcheck disable=SC2329  # invoked from the EXIT/INT/TERM traps
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }

build_db() {
  DB="$TMPD/db"; : > "$DB"
  SEEN=' '      # labels already emitted
  SEENF=' '     # plist basenames already scanned
  NOW_EPOCH=$(date '+%s')
  # launchd records no timestamp for a failure - only 'runs' and the exit
  # code. But a boot-triggered service that ran and is not running now
  # failed AT BOOT, and boot time is knowable, so the date is recoverable
  # for exactly the services that have no log to date them by.
  # Anchored on purpose: '.*sec' also matches 'usec', which captures the
  # microseconds and dates everything to 1970.
  BOOT_EPOCH=$(sysctl -n kern.boottime 2>/dev/null \
               | sed -n 's/^{ *sec *= *\([0-9][0-9]*\).*/\1/p')
  AGENT_USER=$(id -un "${DOMAIN_UID:-$(id -u)}" 2>/dev/null)
  load_ps_map
  case "$SCOPE" in
    daemons) load_loaded_set system; load_disabled_set system system; discover_scope daemon ;;
    agents)  load_loaded_set "gui/$DOMAIN_UID"; load_disabled_set "gui/$DOMAIN_UID" gui; discover_scope agent ;;
    both)
      # The loaded set is per DOMAIN and lives in one file, so it has to be
      # reloaded between the two passes. Loading it only for system meant
      # agent states were computed against the DAEMONS' loaded list: every
      # gui orphan disappeared and the on/@on split was wrong.
      load_disabled_set system system
      load_disabled_set "gui/$DOMAIN_UID" gui
      load_loaded_set system
      discover_scope daemon
      SEEN=' '; SEENF=' '
      load_loaded_set "gui/$DOMAIN_UID"
      discover_scope agent ;;
  esac
}

do_action() {
  _sel=$1
  _n=$(wc -l < "$_sel" | tr -d ' ')
  if [ "$_n" = 0 ]; then
    err "nothing matched$( [ -n "$FILTERS" ] && printf ':%s' "$FILTERS" )"
    return 0
  fi
  if [ "$VERB" = edit ] && [ "$_n" -gt 1 ]; then
    err "'edit' opens one plist at a time; $_n services matched"
    printf '    > narrow the filter, or name the service exactly\n' >&2
    return 0
  fi
  # delete and truncate destroy something, so they confirm even for a single
  # target. The chain is confirmed ONCE, as a whole: being asked twice for
  # 'truncate restart' would be worse than being asked once for both.
  [ "$CONFIRMED" = 1 ] && GO=1
  _needc=0
  [ "$_n" -gt 1 ] && _needc=1
  case " $VERBS " in *" delete "*|*" truncate "*) _needc=1 ;; esac
  if [ "$_needc" = 1 ] && [ "$GO" != 1 ]; then
    _vl=$(printf '%s' "$VERBS" | sed 's/ *$//; s/ /, then /g')
    if [ "$_n" = 1 ]; then printf 'this would %s 1 service:\n\n' "$_vl"
    else                   printf 'this would %s %s services:\n\n' "$_vl" "$_n"; fi
    while IFS="$FS1" read -r _l _d _p _a _st _tr _su _er _ou _pr _us _ef _of _wat; do
      printf '  %s%s%s\n' "$C_HDR" "$_l" "$C_OFF"
      # No pipeline here on purpose: it would run the loop in a subshell,
      # and $VERB is the caller's loop variable.
      _vsave=$VERB
      { for VERB in $VERBS; do
          plan_steps
          case "$VERB" in
            edit) [ -n "$_p" ] && [ "$_p" != "$EM" ] && printf '  %s\n' "$_p" ;;
            truncate)
              for _ts in "$_ef" "$_of"; do
                [ -n "$_ts" ] && [ "$_ts" != "$EM" ] && [ -f "$_ts" ] || continue
                printf '  %s (%s)\n' "$_ts" \
                  "$(human_size "$(wc -c < "$_ts" 2>/dev/null | tr -d ' ')")"
                [ "$_ef" = "$_of" ] && break
              done ;;
            delete)
              if [ -n "$_p" ] && [ "$_p" != "$EM" ]; then
                printf '  %s\n' "$_p"
                _pd=$(delete_destination "$_l")
                [ -n "$_pd" ] && printf '  -> %s\n' "$_pd"
              fi ;;
          esac
        done; } > "$TMPD/plansteps"
      VERB=$_vsave
      sed 's/^/      /' "$TMPD/plansteps"
      [ "$VRB" = 1 ] && printf '      %s%s%s\n' "$C_DIM" "$(plan_raw "$_l" "$_d" "$_p")" "$C_OFF"
      printf '\n'
    done < "$_sel"
    :
    printf '\nadd --go to carry it out, or type go: '
    if [ -t 0 ]; then read -r _ans; else _ans=; fi
    [ "$_ans" = go ] || { printf 'nothing done\n'; ABORT_CHAIN=1; return 0; }
    printf '\n'
    CONFIRMED=1
  fi
  # Sequential, one launchctl call at a time, so the narration is
  # consecutive and a failure is unambiguously attributable.
  while IFS="$FS1" read -r _l _d _p _a _st _tr _su _er _ou _pr _us _ef _of _wat <&3; do
    [ -n "$_l" ] || continue
    # Decode the empty-field marker. Without this an "empty" program came
    # through as the sentinel character, and every check on it was wrong:
    # a plist with no program at all was reported as 'program MISSING'.
    [ "$_p"  = "$EM" ] && _p=;   [ "$_tr" = "$EM" ] && _tr=
    [ "$_su" = "$EM" ] && _su=;  [ "$_pr" = "$EM" ] && _pr=
    [ "$_us" = "$EM" ] && _us=;  [ "$_ef" = "$EM" ] && _ef=
    [ "$_of" = "$EM" ] && _of=;  [ "$_wat" = "$EM" ] && _wat=
    if [ "$_a" = 1 ] && [ "${_p#/System/Library/}" != "$_p" ]; then
      msg "$_l is SIP-protected (/System/Library); launchd will not let anyone change it"
      EXITCODE=1
      continue
    fi
    DOMAIN=$_d
    act_on "$_l" "$_p" "$_st" "$_tr" "$_ef" "$_of"
  done 3< "$_sel"
}

# What the action will DO, one bullet per step, in plain words. The plan is
# the last thing shown before something irreversible, so it is no place for
# launchctl's vocabulary - that is what -V is for.
# The undelete flow: list what can be restored, or restore what matches.
do_undelete() {
  deleted_list > "$TMPD/del.all"
  if [ ! -s "$TMPD/del.all" ]; then
    printf 'nothing to undelete: no plist has been deleted by my-lc\n'
    printf '  (it would be in %s)\n' "$STATE_DIR/deleted"
    return 0
  fi
  : > "$TMPD/del.sel"
  while IFS="$FS1" read -r _bf _bl _bt _bo; do
    [ -n "$_bl" ] || continue
    _keep=1
    for _f in $FILTERS; do
      _lf=$(lower "$_f")
      case "$(lower "$_bl $_bf $_bo")" in *"$_lf"*) ;; *) _keep=0 ;; esac
    done
    [ "$_keep" = 1 ] && printf '%s%s%s%s%s%s%s\n' "$_bf" "$FS1" "$_bl" "$FS1" "$_bt" "$FS1" "$_bo" >> "$TMPD/del.sel"
  done < "$TMPD/del.all"

  _n=$(wc -l < "$TMPD/del.sel" | tr -d ' ')
  if [ "$_n" = 0 ]; then
    err "nothing deleted matches$( [ -n "$FILTERS" ] && printf ':%s' "$FILTERS" )"
    printf '    > run '\''my-lc undelete'\'' with no filter to see what there is\n' >&2
    return 0
  fi

  # With no filter this is a listing, not an action: show what is there.
  if [ -z "$FILTERS" ]; then
    printf '%sdeleted, and restorable:%s\n\n' "$C_HDR" "$C_OFF"
    while IFS="$FS1" read -r _bf _bl _bt _bo; do
      printf '  %s%s%s\n' "$C_HDR" "$_bl" "$C_OFF"
      printf '      deleted %s\n' "$(when "$_bt")"
      printf '      would go back to %s\n' "$_bo"
      [ "$VRB" = 1 ] && printf '      from %s\n' "$_bf"
      printf '\n'
    done < "$TMPD/del.sel"
    printf 'name one to restore it, e.g. my-lc undelete %s\n' \
      "$(head -n 1 "$TMPD/del.sel" | cut -d"$FS1" -f2)"
    return 0
  fi

  if [ "$_n" -gt 1 ] && [ "$GO" != 1 ]; then
    printf 'this would undelete %s services:\n\n' "$_n"
    while IFS="$FS1" read -r _bf _bl _bt _bo; do
      printf '  %s%s%s\n' "$C_HDR" "$_bl" "$C_OFF"
      printf '      - put its plist back at %s\n' "$_bo"
      printf '      - re-enable it\n'
      [ "$NOW" = 1 ] && printf '      - start it\n'
      printf '\n'
    done < "$TMPD/del.sel"
    printf 'add --go to carry it out, or type go: '
    if [ -t 0 ]; then read -r _ans; else _ans=; fi
    [ "$_ans" = go ] || { printf 'nothing done\n'; return 0; }
    printf '\n'
  fi
  while IFS="$FS1" read -r _bf _bl _bt _bo <&3; do
    [ -n "$_bl" ] || continue
    v_undelete "$_bf" "$_bl" "$_bt" "$_bo"
  done 3< "$TMPD/del.sel"
}

plan_steps() {
  case "$VERB" in
    start)   printf -- '- start it in this boot session\n' ;;
    stop)    printf -- '- stop it, and leave it stopped until the next reboot\n' ;;
    restart) printf -- '- stop it\n- start it again\n' ;;
    run)     printf -- '- run its program now, without waiting for its trigger\n' ;;
    kill)    printf -- '- send SIG%s to the running process\n' "$KILLSIG" ;;
    enable)  printf -- '- arm it to run at every boot from now on\n'
             [ "$NOW" = 1 ] && printf -- '- start it now as well\n'
             [ "$NOW" = 1 ] || printf -- '  (it is NOT started now; add --now for that)\n' ;;
    disable) [ "$NOW" = 1 ] && printf -- '- stop it now\n'
             printf -- '- stop it coming back at any future boot\n'
             [ "$NOW" = 1 ] || printf -- '  (it keeps running for now; add --now to stop it too)\n' ;;
    delete)  printf -- '- stop it\n'
             printf -- '- disable it, so it stays off even if its plist comes back\n'
             printf -- '- move its plist to %s\n' "$(delete_where)" ;;
    edit)    printf -- '- open its plist in the editor\n' ;;
    truncate)
             case "$TRUNC_WHAT" in
               stderr) printf -- '- empty its stderr log\n' ;;
               stdout) printf -- '- empty its stdout log\n' ;;
               *)      printf -- '- empty its stderr and stdout logs\n' ;;
             esac
             printf -- '  (the files stay, they are truncated to 0 bytes)\n' ;;
  esac
}

# The literal launchctl commands, shown only under -V, for anyone who wants
# to know exactly what is about to run.
plan_raw() {
  case "$VERB" in
    start)   printf 'launchctl bootstrap %s %s' "$2" "$3" ;;
    stop)    printf 'launchctl bootout %s/%s' "$2" "$1" ;;
    restart) printf 'launchctl bootout %s/%s ; bootstrap %s %s' "$2" "$1" "$2" "$3" ;;
    run)     printf 'launchctl kickstart -k %s/%s' "$2" "$1" ;;
    kill)    printf 'launchctl kill %s %s/%s' "$KILLSIG" "$2" "$1" ;;
    enable)  if [ "$NOW" = 1 ]; then printf 'launchctl enable %s/%s ; bootstrap %s %s' "$2" "$1" "$2" "$3"
             else printf 'launchctl enable %s/%s' "$2" "$1"; fi ;;
    disable) if [ "$NOW" = 1 ]; then printf 'launchctl bootout %s/%s ; disable %s/%s' "$2" "$1" "$2" "$1"
             else printf 'launchctl disable %s/%s' "$2" "$1"; fi ;;
    delete)  printf 'launchctl bootout %s/%s ; disable %s/%s ; mv %s' "$2" "$1" "$2" "$1" "$3" ;;
    edit)    printf '%s %s' "${EDITOR_CMD:-${VISUAL:-${EDITOR:-vi}}}" "$3" ;;
    truncate) printf 'truncate -s 0 <the %s log(s)>' "$TRUNC_WHAT" ;;
  esac
}

main() {
  parse_args "$@"

  # The implication chain, enforced once, right here.
  [ "$DEEPDBG" = 1 ] && DBG=1
  [ "$DBG"     = 1 ] && VRB=1
  [ "$VRB"     = 1 ] && QUIET=0
  [ "$DEEPDBG" = 1 ] && { PS4='+ '; set -x; }

  find_config

  if [ "$WANT_STAMP" = 1 ];   then stamp_version; exit 0; fi
  if [ "$WANT_VERSION" = 1 ]; then show_version; exit 0; fi

  [ -z "$SCOPE" ]        && SCOPE=$DEFAULT_SCOPE
  [ -z "$FILTER_STATE" ] && FILTER_STATE=$DEFAULT_FILTER_STATE
  if [ -z "$VERBS" ]; then VERB=$DEFAULT_COMMAND; VERBS="$VERB "; fi
  [ -z "$APPLE_MODE" ]   && APPLE_MODE=exclude
  FILTERS=$(printf '%s' "$FILTERS" | sed 's/^ *//')

  check_now_misuse
  setup_color

  TMPD=$(mktemp -d "/tmp/$SCRIPT_NAME.XXXXXX") || die "cannot create a temp dir"
  trap 'cleanup' EXIT
  trap 'cleanup; exit 130' INT TERM HUP

  if [ "$TESTS" = 1 ]; then run_tests; exit "$EXITCODE"; fi

  install_zsh_completions

  resolve_domain
  build_db

  if [ "$COMPLETE" = 1 ]; then complete_labels; exit 0; fi

  # 'undelete' works on what is NOT in the table: a deleted service has no
  # plist, so the ordinary selection can never find it.
  if [ "$VERB" = undelete ]; then do_undelete; exit "$EXITCODE"; fi

  select_records "$DB" "$TMPD/sel.final"
  _n=$(wc -l < "$TMPD/sel.final" | tr -d ' ')

  domain_header
  for VERB in $VERBS; do
    # A declined confirmation stops the whole chain: the plan the user said
    # no to covered every verb in it.
    [ "$ABORT_CHAIN" = 1 ] && break
    case "$VERB" in
      list)   render_table "$TMPD/sel.final" ;;
      status) if [ "$_n" = 1 ]; then render_record "$TMPD/sel.final"
              else                   render_table  "$TMPD/sel.final"; fi ;;
      *)      do_action "$TMPD/sel.final" ;;
    esac
  done
  exit "$EXITCODE"
}

# ======================================================================
# self-tests — real launchd, never a mock. Fixtures are generated here;
# nothing is shipped alongside the script.
# ======================================================================

T_PASS=0; T_FAIL=0; T_SKIP=0
SELFTEST_PREFIX=eu.no-panic.my-lc-selftest

t_ok()   { T_PASS=$((T_PASS+1)); printf '  PASS  %s\n' "$1"; }
t_no()   { T_FAIL=$((T_FAIL+1)); EXITCODE=1
           printf '  FAIL  %s\n' "$1"
           printf '        expected: %s\n' "$2"
           printf '        actual:   %s\n' "$3"; }
t_skip() { T_SKIP=$((T_SKIP+1)); printf '  SKIP  %s (%s)\n' "$1" "$2"; }
t_eq()   { if [ "$2" = "$3" ]; then t_ok "$1"; else t_no "$1" "$2" "$3"; fi; }
t_sec()  { printf '\n%s%s%s\n' "$C_HDR" "$1" "$C_OFF"; }

# Nothing may ever act on a label that is not ours.
t_guard() {
  case "$1" in
    "$SELFTEST_PREFIX"*) return 0 ;;
  esac
  printf '\nABORT: a test tried to act on %s, which is not a selftest label\n' "$1" >&2
  cleanup_fixtures; exit 2
}

t_plist() {
  # $1 variant, $2..: extra plist body lines
  _v=$1; shift
  _lab="$SELFTEST_PREFIX-$_v"
  _f="$TMPD/$_lab.plist"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_lab"
    printf '  <key>ProgramArguments</key><array>\n'
    printf '    <string>/bin/sh</string><string>-c</string>\n'
    printf '    <string>echo out-$$; echo err-$$ >&amp;2; sleep 3600</string>\n'
    printf '  </array>\n'
    for _l in "$@"; do printf '  %s\n' "$_l"; done
    printf '</dict></plist>\n'
  } > "$_f"
  printf '%s' "$_f"
}

t_state() {
  # current STATE of a selftest label, re-derived from raw launchctl
  _l=$1
  _d=0; launchctl print-disabled "$DOMAIN" 2>/dev/null \
        | awk -F'"' '/=> *disabled/ { print $2 }' | grep -qxF "$_l" && _d=1
  _ld=0; launchctl print "$DOMAIN/$_l" >/dev/null 2>&1 && _ld=1
  if   [ "$_d" = 0 ] && [ "$_ld" = 1 ]; then printf 'on'
  elif [ "$_d" = 0 ] && [ "$_ld" = 0 ]; then printf '@on'
  elif [ "$_d" = 1 ] && [ "$_ld" = 1 ]; then printf '@off'
  else                                       printf 'off'; fi
}

cleanup_fixtures() {
  for _l in $(launchctl print-disabled "$DOMAIN" 2>/dev/null \
              | awk -F'"' '{print $2}' | grep "^$SELFTEST_PREFIX" ; \
              launchctl list 2>/dev/null | awk '{print $3}' | grep "^$SELFTEST_PREFIX"); do
    t_guard "$_l"
    launchctl bootout "$DOMAIN/$_l" >/dev/null 2>&1
    launchctl enable  "$DOMAIN/$_l" >/dev/null 2>&1
  done
}

run_tests() {
  setup_color
  SCOPE=$TESTS_SCOPE
  case "$TESTS_SCOPE" in
    daemons)
      if [ "$(id -u)" != 0 ]; then
        printf 'the daemon-scope tests need root.\n'
        printf 'run them as root:  my-lc --run-tests daemons\n'
        T_SKIP=$((T_SKIP+1)); t_summary; return 0
      fi ;;
  esac
  resolve_domain
  printf '%smy-lc %s self-tests — domain %s%s\n' "$C_HDR" "$VERSION" "$DOMAIN" "$C_OFF"

  # refuse to run if a stale fixture is lying around
  if launchctl list 2>/dev/null | awk '{print $3}' | grep -q "^$SELFTEST_PREFIX"; then
    printf '\na selftest service is already loaded; booting it out first\n'
    cleanup_fixtures
  fi
  trap 'cleanup_fixtures; cleanup' EXIT
  ensure_state_dir || true

  # Child my-lc runs must discover the fixture plists, which live in the
  # temp dir rather than a real LaunchAgents directory - so hand them a
  # config that adds it. This keeps the suite self-contained: nothing is
  # ever written into the user's own LaunchAgents.
  T_CONF="$TMPD/test.conf"
  {
    printf 'DEFAULT_COMMAND=status\n'
    printf 'DEFAULT_FILTER_STATE=all\n'
    printf 'DEFAULT_SCOPE=%s\n' "$TESTS_SCOPE"
    printf 'ALL_MEANS=non-apple\n'
    printf 'DAEMON_DIRS="%s /Library/LaunchDaemons"\n' "$TMPD"
    printf 'AGENT_DIRS="%s %s/Library/LaunchAgents"\n' "$TMPD" "$HOME"
    printf 'STATE_DIR="%s/state"\n' "$TMPD"
    printf 'ERR_TAIL=10\nBIG_DELTA=1048576\nBOOTSTRAP_TRIES=3\nWIDTH_LABEL=auto\nCOLOR=never\n'
    printf 'EDITOR_CMD=""\nDELETE_MODE=backup\nTIME_FORMAT=absolute\nTIME_FMT="%%Y-%%m-%%d_%%H%%M"\n'
  } > "$T_CONF"

  # and the suite's own view of the machine
  APPLE_MODE=exclude
  FILTER_STATE=all
  build_db

  t_static
  t_readonly
  t_matrix
  t_hints
  t_version
  t_exitcodes
  t_timefmt
  t_truncate
  t_undelete
  t_loadeddiff
  t_verbose
  t_pstime
  t_logsizes
  t_plistchecks
  t_restartrace
  t_chain
  t_failures
  t_errcolumn
  t_editdelete
  t_program
  t_watch
  t_logs
  t_completion
  cleanup_fixtures
  t_residue
  t_summary
}

# Say plainly what the suite could not take back. 'launchctl enable' clears
# the disabled flag but does NOT remove the entry from the domain's override
# database, and launchctl has no verb that does - so every label the suite
# ever disabled stays listed there, as '=> enabled'. Harmless, but it is
# litter in a system file and the user should hear it from the tool rather
# than discover it.
t_residue() {
  # Clean up properly rather than just reporting: 'launchctl enable' clears
  # the flag but leaves the entry, and one per fixture label accumulates in
  # the domain's override database run after run. The file is root-owned, so
  # this only works when the suite runs as root; otherwise say what is left.
  if [ "$DOMAIN" = system ]; then _dbf=/var/db/com.apple.xpc.launchd/disabled.plist
  else _dbf=/var/db/com.apple.xpc.launchd/disabled.$DOMAIN_UID.plist; fi
  if [ -w "$_dbf" ]; then
    _removed=0
    for _rl in $(launchctl print-disabled "$DOMAIN" 2>/dev/null \
                 | awk -F'"' -v p="$SELFTEST_PREFIX" '$2 ~ p { print $2 }'); do
      t_guard "$_rl"
      plutil -remove "$_rl" "$_dbf" >/dev/null 2>&1 && _removed=$((_removed + 1))
    done
    [ "$_removed" -gt 0 ] && printf '\ncleaned up %s selftest entr%s from %s\n' \
      "$_removed" "$( [ "$_removed" = 1 ] && printf 'y' || printf 'ies' )" "$_dbf"
  fi
  _res=$(launchctl print-disabled "$DOMAIN" 2>/dev/null \
         | grep -c "$SELFTEST_PREFIX" 2>/dev/null)
  [ "${_res:-0}" -gt 0 ] 2>/dev/null || return 0
  printf '\n%sleft behind%s: %s selftest label(s) remain listed in the %s\n' \
    "$C_WARN" "$C_OFF" "$_res" "override database"
  printf '  as "=> enabled", which disables nothing. The suite removes these\n'
  printf '  itself when it can write the file, but it is root-owned. As root:\n'
  # the system domain's file has no uid component; a gui domain's does
  if [ "$DOMAIN" = system ]; then _dbf=/var/db/com.apple.xpc.launchd/disabled.plist
  else _dbf=/var/db/com.apple.xpc.launchd/disabled.$DOMAIN_UID.plist; fi
  launchctl print-disabled "$DOMAIN" 2>/dev/null \
    | awk -F'"' -v p="$SELFTEST_PREFIX" -v f="$_dbf" \
        '$2 ~ p { print "    plutil -remove " $2 " " f }'
  printf '  followed by a reboot, since launchd caches the file in memory.\n'
}

t_summary() {
  printf '\n%s%s%s  passed %s  failed %s  skipped %s\n' \
    "$C_HDR" 'RESULT' "$C_OFF" "$T_PASS" "$T_FAIL" "$T_SKIP"
  [ "$T_SKIP" -gt 0 ] && printf '%sNOTE: %s test group(s) were SKIPPED — this is not a full pass.%s\n' \
    "$C_WARN" "$T_SKIP" "$C_OFF"
  [ "$T_FAIL" -gt 0 ] && EXITCODE=1
  return 0
}

t_static() {
  t_sec 'A. static'
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s dash "$0" >"$TMPD/sc.log" 2>&1; then t_ok 'shellcheck -s dash is clean'
    else t_no 'shellcheck -s dash is clean' 'no findings' "$(grep -c '^In ' "$TMPD/sc.log" 2>/dev/null) finding(s); see $TMPD/sc.log"; fi
  else t_skip 'shellcheck' 'not installed'; fi
  if command -v dash >/dev/null 2>&1; then
    if dash -n "$0" 2>"$TMPD/dash.log"; then t_ok 'dash -n parses'
    else t_no 'dash -n parses' 'clean' "$(cat "$TMPD/dash.log")"; fi
  else t_skip 'dash -n' 'not installed'; fi
  # Three times, an edit removed a test function and left its call behind:
  # run_tests then failed silently to stderr and the section simply vanished
  # from the report, with the total still looking healthy.
  _missing=0
  awk '/^run_tests\(\) \{/,/^\}/' "$0" | awk '$1 ~ /^t_[a-z]+$/ { print $1 }' > "$TMPD/called"
  while IFS= read -r _fn; do
    [ -n "$_fn" ] || continue
    grep -q "^$_fn() {" "$0" || { printf '  called but not defined: %s\n' "$_fn"; _missing=$((_missing + 1)); }
  done < "$TMPD/called"
  t_eq 'every test function run_tests calls is defined' 0 "$_missing"
  "$0" -h >/dev/null 2>&1;    t_eq '-h exits 0' 0 $?
  "$0" --help >/dev/null 2>&1; t_eq '--help exits 0' 0 $?
  t_eq 'usage line follows the convention' 'usage: my-lc [OPTIONS] [FILTER ...] [VERB]' \
       "$("$0" -h 2>/dev/null | head -n 1)"
}

t_readonly() {
  t_sec 'B. read-only, against the real machine'
  # Only the disabled set is a valid invariant here. A full 'launchctl list'
  # snapshot changes on its own on a live machine - transient XPC services
  # come and go and pids move - so comparing it made this assertion flaky
  # and told us nothing about my-lc.
  _before=$(launchctl print-disabled "$DOMAIN" 2>/dev/null)

  # every service lands in exactly one state, none dropped or duplicated
  _tot=$(wc -l < "$DB" | tr -d ' ')
  _cls=$(awk -F"$FS1" '$5=="on"||$5=="@on"||$5=="off"||$5=="@off"||$5=="orphan"' "$DB" | wc -l | tr -d ' ')
  t_eq 'every record has exactly one valid STATE' "$_tot" "$_cls"
  _uniq=$(cut -d"$FS1" -f1 "$DB" | sort -u | wc -l | tr -d ' ')
  t_eq 'no duplicate labels' "$_tot" "$_uniq"

  # cross-check the flag axis against raw launchctl for the whole population
  _bad=0
  launchctl print-disabled "$DOMAIN" 2>/dev/null | awk -F'"' '/=> *disabled/ { print $2 }' > "$TMPD/t.dis"
  while IFS= read -r _l; do
    [ -n "$_l" ] || continue
    _s=$(awk -F"$FS1" -v l="$_l" '$1==l { print $5; exit }' "$DB")
    [ -n "$_s" ] || continue
    case "$_s" in off|@off) ;; *) _bad=$((_bad+1)) ;; esac
  done < "$TMPD/t.dis"
  t_eq 'STATE agrees with print-disabled on every disabled service' 0 "$_bad"

  # ...and the loaded axis
  _bad=0
  launchctl list 2>/dev/null | awk 'NR>1 {print $3}' > "$TMPD/t.loaded"
  while IFS= read -r _l; do
    [ -n "$_l" ] || continue
    _s=$(awk -F"$FS1" -v l="$_l" '$1==l { print $5; exit }' "$DB")
    [ -n "$_s" ] || continue
    case "$_s" in on|@off|orphan) ;; *) _bad=$((_bad+1)) ;; esac
  done < "$TMPD/t.loaded"
  t_eq 'STATE agrees with launchctl list on every loaded service' 0 "$_bad"

  # apple partition: no overlap, no gap
  _ap=$(awk -F"$FS1" '$4==1' "$DB" | wc -l | tr -d ' ')
  _no=$(awk -F"$FS1" '$4==0' "$DB" | wc -l | tr -d ' ')
  t_eq 'apple / non-apple partition the set exactly' "$_tot" "$((_ap + _no))"

  # target forms are interchangeable
  _one=$(awk -F"$FS1" '$3!="" { print $1; exit }' "$DB")
  _onep=$(awk -F"$FS1" -v l="$_one" '$1==l { print $3; exit }' "$DB")
  t_eq 'a bare label resolves to itself'        "$_one" "$(FILTERS=$_one; resolve_target "$_one")"
  t_eq 'a .plist path resolves to the label'    "$_one" "$(resolve_target "$_onep")"
  t_eq 'domain/label resolves to the label'     "$_one" "$(resolve_target "$DOMAIN/$_one")"

  _after=$(launchctl print-disabled "$DOMAIN" 2>/dev/null)
  if [ "$_before" = "$_after" ]; then t_ok 'read-only work left every enable/disable flag untouched'
  else t_no 'read-only work mutated nothing' 'an identical disabled set' 'the disabled set changed'; fi
  # and no selftest service is LOADED during the read-only block. Counting
  # every mention of the prefix was wrong: leftover '=> enabled' entries in
  # the disabled database also match, and those are not loaded services.
  _leak=$(grep -c "$SELFTEST_PREFIX" "$TMPD/loaded" 2>/dev/null)
  t_eq 'no selftest service is loaded during the read-only block' 0 "${_leak:-0}"
}

# Drive my-lc itself, in the same scope, and return its output.
t_run() {
  _scopeflag=
  [ "$SCOPE" = agents ] && _scopeflag=--agents
  MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --all "$@" 2>&1
}

t_matrix() {
  t_sec 'C. the STATE transition matrix'
  _pl=$(t_plist plain)
  _lab="$SELFTEST_PREFIX-plain"
  t_guard "$_lab"

  # from off
  launchctl bootout "$DOMAIN/$_lab" >/dev/null 2>&1
  launchctl disable "$DOMAIN/$_lab" >/dev/null 2>&1
  t_eq 'fixture starts in off' off "$(t_state "$_lab")"

  t_run "$_lab" enable >/dev/null 2>&1
  t_eq 'off  + enable        -> @on' '@on' "$(t_state "$_lab")"

  t_run "$_lab" disable >/dev/null 2>&1
  t_eq '@on  + disable       -> off' 'off' "$(t_state "$_lab")"

  # start on a disabled service must refuse, not fail obscurely
  _o=$(t_run "$_lab" start)
  case "$_o" in
    *"is disabled"*) t_ok 'off  + start         -> refused, and says to enable first' ;;
    *) t_no 'off + start refused' 'a message naming enable' "$_o" ;;
  esac
  t_eq 'off  + start         -> still off (nothing happened)' off "$(t_state "$_lab")"

  t_run "$_lab" enable --now >/dev/null 2>&1
  t_eq 'off  + enable --now  -> on'  on   "$(t_state "$_lab")"

  _pidb=$(launchctl list 2>/dev/null | awk -v l="$_lab" '$3==l {print $1}')
  t_run "$_lab" run >/dev/null 2>&1
  _pida=$(launchctl list 2>/dev/null | awk -v l="$_lab" '$3==l {print $1}')
  t_eq 'on   + run           -> on' on "$(t_state "$_lab")"
  if [ -n "$_pidb" ] && [ -n "$_pida" ] && [ "$_pidb" != "$_pida" ]; then
    t_ok 'on   + run           -> the program actually ran again (new pid)'
  else
    t_no 'on + run re-ran the program' "a pid different from $_pidb" "$_pida"
  fi

  t_run "$_lab" disable >/dev/null 2>&1
  t_eq 'on   + disable       -> @off' '@off' "$(t_state "$_lab")"

  t_run "$_lab" enable >/dev/null 2>&1
  t_eq '@off + enable        -> on'  on "$(t_state "$_lab")"

  t_run "$_lab" stop >/dev/null 2>&1
  t_eq 'on   + stop          -> @on' '@on' "$(t_state "$_lab")"

  t_run "$_lab" start >/dev/null 2>&1
  t_run "$_lab" disable --now >/dev/null 2>&1
  t_eq 'on   + disable --now -> off' off "$(t_state "$_lab")"

  t_run "$_lab" enable --now >/dev/null 2>&1
  _pidb=$(launchctl list 2>/dev/null | awk -v l="$_lab" '$3==l {print $1}')
  t_run "$_lab" restart >/dev/null 2>&1
  _pida=$(launchctl list 2>/dev/null | awk -v l="$_lab" '$3==l {print $1}')
  t_eq 'on   + restart       -> on'  on "$(t_state "$_lab")"

  cleanup_fixtures
}

t_hints() {
  t_sec 'D. hints and adaptive errors'

  _o=$("$0" load 2>&1)
  case "$_o" in
    *"legacy name"*"'start'"*"'enable --now'"*) t_ok "load  -> named as legacy, both meanings offered" ;;
    *) t_no 'load redirect' "both 'start' and 'enable --now'" "$_o" ;;
  esac
  _o=$("$0" unload 2>&1)
  case "$_o" in
    *"legacy name"*"'stop'"*"'disable --now'"*) t_ok "unload -> named as legacy, both meanings offered" ;;
    *) t_no 'unload redirect' "both 'stop' and 'disable --now'" "$_o" ;;
  esac
  _o=$("$0" start --now 2>&1)
  case "$_o" in
    *"already acts now"*) t_ok "start --now -> named, not an unknown-flag error" ;;
    *) t_no 'start --now hint' 'a message saying start already acts now' "$_o" ;;
  esac
  _o=$("$0" --nonsense-flag 2>&1)
  case "$_o" in
    *"unknown option"*) t_ok 'a genuinely unknown option is still an error' ;;
    *) t_no 'unknown option' 'unknown option: --nonsense-flag' "$_o" ;;
  esac

  # kill on a KeepAlive service must warn that it comes straight back
  _pl=$(t_plist keep '<key>KeepAlive</key><true/>' '<key>RunAtLoad</key><true/>')
  _lab="$SELFTEST_PREFIX-keep"
  t_guard "$_lab"
  t_run "$_lab" enable --now >/dev/null 2>&1
  if [ "$(t_state "$_lab")" = on ]; then
    _o=$(t_run "$_lab" kill)
    case "$_o" in
      *KeepAlive*) t_ok 'kill on a KeepAlive service warns that launchd restarts it' ;;
      *) t_no 'KeepAlive warning' 'a message naming KeepAlive' "$_o" ;;
    esac
    _o=$(t_run "$_lab" 2>&1)
    case "$_o" in
      *keep*) t_ok 'the KeepAlive trigger shows as keep' ;;
      *) t_no 'keep trigger' 'keep in the TRIGGER column' "$_o" ;;
    esac
  else
    t_skip 'KeepAlive tests' 'the fixture would not bootstrap'
  fi
  cleanup_fixtures
}

t_version() {
  t_sec 'H. --version identifies the exact build'
  _o=$("$0" --version 2>&1)
  case "$_o" in
    "$SCRIPT_NAME $VERSION (build "*) t_ok '--version names the tool, version and build' ;;
    *) t_no '--version format' "$SCRIPT_NAME $VERSION (build ...)" "$_o" ;;
  esac
  _b=$(build_id)
  case "$_b" in
    unknown) t_no 'a build id can be computed' 'a hash' 'unknown' ;;
    *) t_ok "the build id is derivable ($_b)" ;;
  esac
  # the whole point: a changed file MUST report a different build id, so two
  # copies can be compared by running each
  cp "$0" "$TMPD/v1"; cp "$0" "$TMPD/v2"; printf '\n# changed\n' >> "$TMPD/v2"
  _b1=$(/bin/dash "$TMPD/v1" --version 2>&1)
  _b2=$(/bin/dash "$TMPD/v2" --version 2>&1)
  if [ "$_b1" != "$_b2" ]; then t_ok 'a changed file reports a different build id'
  else t_no 'build id tracks content' 'two different ids' "$_b1 == $_b2"; fi
  # ...and an identical copy MUST report the same one
  _b3=$(/bin/dash "$TMPD/v1" --version 2>&1)
  t_eq 'an identical file reports the same build id' "$_b1" "$_b3"
}

t_program() {
  t_sec 'J. the program is checked, not assumed'
  _pd="$TMPD/prog"; mkdir -p "$_pd/sub"
  printf '#!/bin/sh\ntrue\n' > "$_pd/good";   chmod 755 "$_pd/good"
  : > "$_pd/empty";                            chmod 755 "$_pd/empty"
  printf 'x' > "$_pd/noexec";                  chmod 644 "$_pd/noexec"

  t_eq 'a real executable is ok'        ok               "$(program_verdict "$_pd/good")"
  t_eq 'a 0-byte program is EMPTY'      EMPTY            "$(program_verdict "$_pd/empty")"
  t_eq 'a file with no execute bit at all is caught' \
       'NOT EXECUTABLE' "$(program_verdict "$_pd/noexec")"
  # '[ -x ]' answers "can I run it", which is the wrong question: a
  # root-owned mode-544 helper is executable by root and not by me, and
  # calling that NOT EXECUTABLE was a real false alarm.
  printf 'x' > "$_pd/rootonly"; chmod 544 "$_pd/rootonly"
  t_eq 'mode 544 is executable for root'  ok "$(program_verdict "$_pd/rootonly" root)"

  # The full matrix, because the caller's own access is NOT the answer: a
  # mode-700 file is runnable by its owner and by root, and by nobody else.
  # Judging it by '[ -x ]' - can *I* run it - was wrong twice over.
  _own="$_pd/own700"; printf 'x' > "$_own"; chmod 700 "$_own"
  _all="$_pd/all755"; printf 'x' > "$_all"; chmod 755 "$_all"
  _me=$(id -un)
  t_eq 'mode 700: root may run it'          ok "$(program_verdict "$_own" root)"
  t_eq 'mode 700: its owner may run it'     ok "$(program_verdict "$_own" "$_me")"
  t_eq 'mode 700: a stranger may NOT'       "NOT EXECUTABLE by nobody" \
       "$(program_verdict "$_own" nobody)"
  t_eq 'mode 755: anyone may run it'        ok "$(program_verdict "$_all" nobody)"
  t_eq 'mode 644: nobody may, not even root' 'NOT EXECUTABLE' \
       "$(program_verdict "$_pd/noexec" root)"
  t_eq 'an absent program is MISSING'   MISSING          "$(program_verdict "$_pd/nope")"
  t_eq 'a directory is not a program'   'NOT A FILE'     "$(program_verdict "$_pd")"
  t_eq 'no program at all is not an error' ok            "$(program_verdict '')"

  # the MISSING / ? distinction matters here exactly as it does for watches:
  # a program under an unreadable directory is unknown, not absent
  mkdir -p "$_pd/closed"; printf 'x' > "$_pd/closed/hidden"; chmod 000 "$_pd/closed"
  if [ "$(id -u)" = 0 ]; then
    t_skip 'unreadable-parent program' 'root can read everything'
  else
    case "$(program_verdict "$_pd/closed/hidden")" in
      '?'*) t_ok 'a program under an unreadable dir is ?, never MISSING' ;;
      *)    t_no 'unreadable parent -> ?' '?' "$(program_verdict "$_pd/closed/hidden")" ;;
    esac
  fi
  chmod 755 "$_pd/closed"

  # reachability is about the user the service runs AS
  t_eq 'reachable by its own user' ok "$(program_access "$_pd/good" "$(id -un)")"
  case "$(program_access "$_pd/good" no-such-user-xyz)" in
    '?'*) t_ok 'an unknown user is reported, not silently passed' ;;
    *)    t_no 'unknown user' '? no such user' "$(program_access "$_pd/good" no-such-user-xyz)" ;;
  esac
  t_eq 'root reaches everything' 'ok (root)' "$(program_access "$_pd/good" root)"
}

t_editdelete() {
  t_sec 'K. edit and delete'
  _ed="$TMPD/ed"; mkdir -p "$_ed"
  _lab="$SELFTEST_PREFIX-editme"
  t_guard "$_lab"
  _pl=$(t_plist editme)
  cp "$_pl" "$_ed/$_lab.plist"
  # DELETE_MODE=backup is the default and keeps the suite inside its own
  # temp dir; it is set explicitly so the trash test below is the only thing
  # that can go near a Trash, and even that one redirects HOME.
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\nDELETE_MODE=backup\n' \
    "$_ed" "$_ed" "$_ed" > "$_ed/conf"
  _sf=
  [ "$SCOPE" = agents ] && _sf=--agents

  # edit: no change, a valid change, and a change that breaks the plist
  printf '#!/bin/sh\nexit 0\n' > "$_ed/noop"; chmod 755 "$_ed/noop"
  # shellcheck disable=SC2016  # $1 belongs to the generated script, not to us
  printf '#!/bin/sh\nsed -i "" "s|3600|7200|" "$1"\n' > "$_ed/ok"; chmod 755 "$_ed/ok"
  # a bare word IS a valid plist string, so break it in a way launchd cares
  # about: valid syntax, but not a dict with a Label
  # shellcheck disable=SC2016  # same
  printf '#!/bin/sh\nprintf "just-a-string\\n" > "$1"\n' > "$_ed/bad"; chmod 755 "$_ed/bad"

  _o=$(EDITOR="$_ed/noop" MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" edit 2>&1)
  case "$_o" in *unchanged*) t_ok 'edit reports an unchanged plist' ;;
    *) t_no 'edit: unchanged' 'unchanged' "$_o" ;; esac

  _o=$(EDITOR="$_ed/ok" MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" edit 2>&1)
  case "$_o" in *'valid launchd job'*) t_ok 'edit validates a good change' ;;
    *) t_no 'edit: valid change' 'a valid launchd job' "$_o" ;; esac

  _o=$(EDITOR="$_ed/bad" MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" edit 2>&1)
  case "$_o" in
    *'NOT a launchd job'*) t_ok 'edit catches a plist that stopped being a launchd job' ;;
    *) t_no 'edit: broken plist' 'NOT a launchd job any more' "$_o" ;;
  esac
  # and truly malformed content is caught too
  # shellcheck disable=SC2016  # $1 belongs to the generated script
  printf '#!/bin/sh\nprintf "<<<\\n" > "$1"\n' > "$_ed/bad2"; chmod 755 "$_ed/bad2"
  cp "$_pl" "$_ed/$_lab.plist"
  _o=$(EDITOR="$_ed/bad2" MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" edit 2>&1)
  case "$_o" in *'NOT valid'*) t_ok 'edit catches malformed XML' ;;
    *) t_no 'edit: malformed' 'NOT valid any more' "$_o" ;; esac

  # delete must CONFIRM even for a single service, and must not act without it
  cp "$_pl" "$_ed/$_lab.plist"
  _o=$(MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" delete < /dev/null 2>&1)
  case "$_o" in *'this would delete 1 service:'*) t_ok 'delete confirms even for one service' ;;
    *) t_no 'delete confirmation' 'this would delete 1 service:' "$_o" ;; esac
  # the plan must be in plain words, not launchctl's vocabulary
  case "$_o" in
    *bootout*|*kickstart*|*"gui/"*|*"system/"*)
      t_no 'the plan avoids launchctl jargon' 'plain words' "$_o" ;;
    *) t_ok 'the plan is in plain words, not launchctl terms' ;;
  esac
  case "$_o" in *'- stop it'*'- disable it'*) t_ok 'the plan lists each step as a bullet' ;;
    *) t_no 'plan bullets' 'one bullet per step' "$_o" ;; esac
  # the plan must name the DESTINATION, not repeat the source: "move it to a
  # dated backup:" followed by the source path was actively misleading
  case "$_o" in
    *'-> '*) t_ok 'the plan names where the plist will go' ;;
    *) t_no 'plan names the destination' 'a -> destination line' "$_o" ;;
  esac
  # ...and -V still exposes the exact commands
  _ov=$(MY_LC_CONFIG="$_ed/conf" "$0" $_sf -V "$_lab" delete < /dev/null 2>&1)
  case "$_ov" in *'launchctl bootout'*) t_ok '-V still shows the exact launchctl commands' ;;
    *) t_no '-V shows raw commands' 'launchctl bootout ...' "$_ov" ;; esac
  if [ -f "$_ed/$_lab.plist" ]; then t_ok 'delete without go removes nothing'
  else t_no 'delete without go is a no-op' 'the plist still there' 'it was deleted'; fi

  # ...and with --go it backs the plist up rather than unlinking it
  _o=$(MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" delete --go 2>&1)
  if [ -f "$_ed/$_lab.plist" ]; then t_no 'delete --go removes the plist' 'gone' 'still there'
  else t_ok 'delete --go removes the plist'; fi
  if ls "$_ed"/st/deleted/"$_lab".plist.* >/dev/null 2>&1; then
    t_ok 'delete keeps a dated backup, so it can be undone'
  else t_no 'delete backs up the plist' 'a file under st/deleted/' 'no backup found'; fi
  # A bare 'go' on the command line must be named, not silently taken as a
  # filter: it matched anything containing 'go' (com.paragon-software) and
  # so appeared to work.
  _o=$(MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" delete go < /dev/null 2>&1); _rc=$?
  case "$_o" in
    *"'go' is not a filter word"*) t_ok "a bare 'go' argument is named, not used as a filter" ;;
    *) t_no 'bare go rejected' "'go' is not a filter word" "$_o" ;;
  esac
  t_eq "a bare 'go' exits non-zero" 1 "$_rc"

  # An interactive verb must inherit the CALLER's stdin. The action loop
  # used to read its work list on stdin, so vim got a file as its input,
  # reported "Input is not from a terminal", and left the terminal mode
  # broken. Feeding a known marker in proves stdin reaches the editor.
  cp "$_pl" "$_ed/$_lab.plist"
  # shellcheck disable=SC2016  # $line belongs to the generated script
  printf '#!/bin/sh\nread -r line\nprintf "STDIN[%%s]\\n" "$line"\n' > "$_ed/readin"
  chmod 755 "$_ed/readin"
  _o=$(printf 'MARKER\n' | EDITOR="$_ed/readin" MY_LC_CONFIG="$_ed/conf" "$0" $_sf "$_lab" edit 2>&1)
  case "$_o" in
    *'STDIN[MARKER]'*) t_ok 'the editor inherits the caller stdin, not the match list' ;;
    *) t_no 'editor stdin' 'STDIN[MARKER]' "$_o" ;;
  esac

  # trash mode, exercised with HOME redirected so the real Trash is untouched
  _th="$_ed/home"; mkdir -p "$_th"
  cp "$_pl" "$_ed/$_lab.plist"
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\nDELETE_MODE=trash\n' \
    "$_ed" "$_ed" "$_ed" > "$_ed/conft"
  _o=$(HOME="$_th" MY_LC_CONFIG="$_ed/conft" "$0" $_sf "$_lab" delete --go 2>&1)
  if [ -f "$_th/.Trash/$_lab.plist" ]; then t_ok 'DELETE_MODE=trash puts the plist in the Trash'
  else t_no 'trash mode' "a plist in $_th/.Trash" "$_o"; fi
  # a second delete of the same label must not clobber the first
  cp "$_pl" "$_ed/$_lab.plist"
  HOME="$_th" MY_LC_CONFIG="$_ed/conft" "$0" $_sf "$_lab" delete --go >/dev/null 2>&1
  _cnt=$(find "$_th/.Trash" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$_cnt" -ge 2 ]; then t_ok 'a second delete does not overwrite the first in the Trash'
  else t_no 'trash collision' '2 files' "$_cnt file(s)"; fi

  # delete must DISABLE as well as remove, so a reinstalled plist stays off
  if launchctl print-disabled "$DOMAIN" 2>/dev/null \
     | awk -F'"' '/=> *disabled/ { print $2 }' | grep -qxF "$_lab"; then
    t_ok 'delete leaves the service disabled, not merely removed'
  else t_no 'delete disables too' "$_lab listed as disabled" 'it is not disabled'; fi
  cleanup_fixtures
}

t_truncate() {
  t_sec 'N. truncate'
  _td="$TMPD/trunc"; mkdir -p "$_td/st"
  _lab="$SELFTEST_PREFIX-trunc"
  t_guard "$_lab"
  _mk() {
    { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><dict>\n'
      printf '  <key>Label</key><string>%s</string>\n' "$_lab"
      printf '  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>\n'
      printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$1"
      printf '  <key>StandardOutPath</key><string>%s</string>\n' "$2"
      printf '</dict></plist>\n'; } > "$_td/$_lab.plist"
  }
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\n' \
    "$_td" "$_td" "$_td" > "$_td/conf"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents
  _run() { MY_LC_CONFIG="$_td/conf" "$0" $_sf "$_lab" truncate "$@" 2>&1; }
  _sz() { wc -c < "$1" 2>/dev/null | tr -d ' '; }

  _mk "$_td/e.log" "$_td/o.log"
  printf 'aaaa\nbbbb\n' > "$_td/e.log"; printf 'cccc\n' > "$_td/o.log"

  # it must CONFIRM: truncating discards data
  _o=$(_run < /dev/null)
  case "$_o" in *'this would truncate 1 service:'*) t_ok 'truncate confirms before discarding anything' ;;
    *) t_no 'truncate confirms' 'this would truncate 1 service:' "$_o" ;; esac
  t_eq 'truncate without go changes nothing' 10 "$(_sz "$_td/e.log")"
  # ...and the plan says how much would go
  case "$_o" in *'(10B)'*) t_ok 'the plan says how much would be discarded' ;;
    *) t_no 'plan shows sizes' '(10B)' "$_o" ;; esac

  # err only
  _run err --go >/dev/null 2>&1
  t_eq 'truncate err empties stderr'        0 "$(_sz "$_td/e.log")"
  t_eq 'truncate err leaves stdout alone'   5 "$(_sz "$_td/o.log")"

  # out only
  printf 'aaaa\nbbbb\n' > "$_td/e.log"
  _run out --go >/dev/null 2>&1
  t_eq 'truncate out empties stdout'        0 "$(_sz "$_td/o.log")"
  t_eq 'truncate out leaves stderr alone'   10 "$(_sz "$_td/e.log")"

  # both by default
  printf 'cccc\n' > "$_td/o.log"
  _run --go >/dev/null 2>&1
  t_eq 'truncate with no argument does both (stderr)' 0 "$(_sz "$_td/e.log")"
  t_eq 'truncate with no argument does both (stdout)' 0 "$(_sz "$_td/o.log")"

  # the file must SURVIVE: launchd holds it open, so unlinking would orphan it
  if [ -f "$_td/e.log" ]; then t_ok 'the log file survives, it is only emptied'
  else t_no 'truncate keeps the file' 'the file still exists' 'it was removed'; fi

  # one file serving both streams is emptied once, and named as one
  _mk "$_td/both.log" "$_td/both.log"
  printf 'xxxx\n' > "$_td/both.log"
  _o=$(_run --go)
  case "$_o" in *'stderr+stdout'*) t_ok 'a shared log is emptied once, and named as one' ;;
    *) t_no 'shared log' 'stderr+stdout' "$_o" ;; esac
  t_eq 'the shared log is empty afterwards' 0 "$(_sz "$_td/both.log")"

  # an already-empty log is said so, not silently "done"
  _o=$(_run --go)
  case "$_o" in *'already empty'*) t_ok 'an already-empty log says so' ;;
    *) t_no 'already empty' 'already empty' "$_o" ;; esac
  cleanup_fixtures
}


t_verbose() {
  t_sec 'W. -V adds detail, and --both merges the domains'
  _o=$("$0" --all list 2>&1)
  _ov=$("$0" --all -V list 2>&1)

  # -V adds the OUT column, which is informational rather than actionable
  case "$_o"  in *' OUT'*) t_no 'OUT is not in the default view' 'no OUT column' 'it is there' ;;
    *) t_ok 'the default table has no OUT column' ;; esac
  case "$_ov" in *' OUT'*) t_ok '-V adds the OUT column' ;;
    *) t_no '-V adds OUT' 'an OUT column' "$(printf '%s\n' "$_ov" | head -n 1)" ;; esac

  # -V adds the plist and program under each row
  case "$_ov" in *'    > plist:'*) t_ok '-V shows the plist path under each row' ;;
    *) t_no '-V shows the plist' '    > plist: ...' "$(printf '%s\n' "$_ov" | head -n 3)" ;; esac
  case "$_o"  in *'    > plist:'*) t_no 'the default view is clean' 'no plist lines' 'they are there' ;;
    *) t_ok 'the default view stays clean' ;; esac

  # -V names the user even when it IS the default, which the table omits
  case "$_ov" in *' as root'*) t_ok '-V spells out the user even when it is the default' ;;
    *) t_no '-V shows the default user' 'as root' "$(printf '%s\n' "$_ov" | sed -n '2p')" ;; esac

  # --both merges the two domains and says which is which
  _ob=$("$0" --all --both list 2>&1)
  case "$_ob" in *'DOMAIN'*) t_ok '--both adds a DOMAIN column' ;;
    *) t_no '--both DOMAIN column' 'a DOMAIN header' "$(printf '%s\n' "$_ob" | head -n 1)" ;; esac
  _nsys=$(printf '%s\n' "$_ob" | awk 'NR>1 && $1=="system" { n++ } END { print n+0 }')
  _ngui=$(printf '%s\n' "$_ob" | awk 'NR>1 && $1 ~ /^gui\// { n++ } END { print n+0 }')
  if [ "$_nsys" -gt 0 ] && [ "$_ngui" -gt 0 ]; then
    t_ok "--both lists both domains ($_nsys system, $_ngui gui)"
  else t_no '--both merges the domains' 'rows from each' "$_nsys system, $_ngui gui"; fi

  # the merge must not duplicate a label, and must not lose one
  _dup=$(printf '%s\n' "$_ob" | awk 'NR>1 { print $1 " " $2 }' | sort | uniq -d | wc -l | tr -d ' ')
  t_eq '--both produces no duplicate domain+label pairs' 0 "$_dup"
  # the '? = ...' footer is not a row
  _nd=$("$0" --all list 2>/dev/null | awk 'NR>1 && $1!="?"' | wc -l | tr -d ' ')
  _nb=$(printf '%s\n' "$_ob" | awk 'NR>1 && $1=="system"' | wc -l | tr -d ' ')
  t_eq '--both keeps every daemon the daemon-only view had' "$_nd" "$_nb"

  # ...and every agent, with the same state. The loaded set is per domain
  # and lives in one file, so a missing reload between the passes silently
  # judged agents against the daemons' loaded list.
  "$0" --all --agents list 2>/dev/null | awk 'NR>1 && $1!="?" {print $1, $2}' | sort > "$TMPD/ag.only"
  printf '%s\n' "$_ob" | awk 'NR>1 && $1 ~ /^gui\// {print $2, $3}' | sort > "$TMPD/ag.both"
  if cmp -s "$TMPD/ag.only" "$TMPD/ag.both"; then
    t_ok '--both agrees with --agents on every agent and its state'
  else
    t_no '--both matches --agents' \
      "$(wc -l < "$TMPD/ag.only" | tr -d ' ') rows" \
      "$(wc -l < "$TMPD/ag.both" | tr -d ' ') rows, or different states"
  fi
}

t_pstime() {
  t_sec 'U. process start times are in local time'
  # 'ps -o lstart' prints local time with no offset, and the civil-days
  # arithmetic treats it as UTC - every start time came out shifted by the
  # timezone (two hours here). pid 1 calibrates it: launchd starts at boot,
  # and kern.boottime gives that as a true epoch.
  [ -s "$TMPD/psmap" ] || { t_no 'a ps map exists' 'entries' 'empty'; return; }
  _p1=$(awk -F"$FS1" '$1==1 { print $2; exit }' "$TMPD/psmap")
  if [ -z "$_p1" ]; then t_skip 'pid 1 calibration' 'pid 1 not in the ps map'; return; fi
  if [ -z "$BOOT_EPOCH" ]; then t_skip 'pid 1 calibration' 'no boot time'; return; fi
  _skew=$(( _p1 - BOOT_EPOCH ))
  [ "$_skew" -lt 0 ] && _skew=$(( -_skew ))
  if [ "$_skew" -le 2 ]; then
    t_ok "launchd's start time matches kern.boottime (${_skew}s apart)"
  else
    t_no 'pid 1 start matches boot time' 'within 2s' "${_skew}s - a timezone offset would be 3600 or 7200"
  fi
  # and a running service's start must agree with ps, not be hours off
  _rp=$(awk -F"$FS1" '$7 ~ /^run / { print $7; exit }' "$DB" | sed 's/.*pid //; s/ .*//')
  if [ -n "$_rp" ]; then
    _mine=$(awk -F"$FS1" -v p="$_rp" '$1==p { print $2; exit }' "$TMPD/psmap")
    _real=$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p "$_rp" 2>/dev/null)" '+%s' 2>/dev/null)
    if [ -n "$_mine" ] && [ -n "$_real" ]; then
      _d=$(( _mine - _real )); [ "$_d" -lt 0 ] && _d=$(( -_d ))
      t_eq "a running service's start matches date(1) parsing of ps" 0 "$_d"
    else t_skip 'cross-check against date(1)' 'could not parse'; fi
  else t_skip 'cross-check against date(1)' 'nothing running'; fi
}

t_logsizes() {
  t_sec 'V. each log says how big it is'
  _lg="$TMPD/lsz"; mkdir -p "$_lg"
  printf 'a\nb\nc\n' > "$_lg/three"
  : > "$_lg/empty"
  case "$(log_size_note "$_lg/three")" in
    '3L, 6B, last '*) t_ok 'a small log gives lines, bytes and when it was last written' ;;
    *) t_no 'small log note' '3L, 6B, last <when>' "$(log_size_note "$_lg/three")" ;;
  esac
  t_eq 'an empty log says so'              'empty'  "$(log_size_note "$_lg/empty")"
  t_eq 'a missing log says so'             'does not exist yet' "$(log_size_note "$_lg/nope")"
  t_eq 'a directory is not a log'          'not a regular file' "$(log_size_note "$_lg")"
  # counting lines in a huge log means reading it all, so past BIG_DELTA it
  # is reported by size alone
  _sv=$BIG_DELTA; BIG_DELTA=1   # the file is 6 bytes, so this makes it "large"
  case "$(log_size_note "$_lg/three")" in
    *'too big to count cheaply'*) t_ok 'a large log is reported by size alone' ;;
    *) t_no 'large log note' 'too big to count cheaply' "$(log_size_note "$_lg/three")" ;;
  esac
  BIG_DELTA=$_sv
}

t_plistchecks() {
  t_sec 'T. the plist itself is checked, and the command line shown'
  _pd2="$TMPD/plchk"; mkdir -p "$_pd2/st"
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\n' \
    "$_pd2" "$_pd2" "$_pd2" > "$_pd2/conf"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents
  _s() { MY_LC_CONFIG="$_pd2/conf" "$0" $_sf "$1" 2>&1; }

  # the command line, as launchd would run it
  _l="$SELFTEST_PREFIX-cmd"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_l"
    printf '  <key>ProgramArguments</key><array>\n'
    printf '    <string>/bin/sh</string><string>-c</string><string>echo hi there</string>\n'
    printf '  </array>\n</dict></plist>\n'; } > "$_pd2/$_l.plist"
  _o=$(_s "$_l")
  case "$_o" in
    *'command:'*'/bin/sh -c "echo hi there"'*)
      t_ok 'the command line shows every argument, quoted where needed' ;;
    *) t_no 'command line' '/bin/sh -c "echo hi there"' "$_o" ;;
  esac
  # ...and is not repeated pointlessly for a program with no arguments
  _l2="$SELFTEST_PREFIX-cmd2"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_l2"
    printf '  <key>Program</key><string>/usr/bin/true</string>\n'
    printf '</dict></plist>\n'; } > "$_pd2/$_l2.plist"
  _o=$(_s "$_l2")
  _n=$(printf '%s\n' "$_o" | grep -c '/usr/bin/true')
  t_eq 'a program with no arguments is shown once, not twice' 1 "$_n"

  # launchd refuses a group- or world-writable plist and says only
  # 'Input/output error'; my-lc must name it
  chmod 664 "$_pd2/$_l2.plist"
  _o=$(_s "$_l2")
  case "$_o" in *'group- or world-writable'*) t_ok 'a writable-by-others plist is flagged' ;;
    *) t_no 'permission check' 'group- or world-writable' "$_o" ;; esac
  case "$_o" in *'chmod 644'*) t_ok 'and the fix is spelled out' ;;
    *) t_no 'permission fix given' 'chmod 644 ...' "$_o" ;; esac
  chmod 644 "$_pd2/$_l2.plist"
  _o=$(_s "$_l2")
  case "$_o" in *'group- or world-writable'*) t_no 'mode 644 is accepted' 'no complaint' "$_o" ;;
    *) t_ok 'mode 644 raises nothing - the octal mask is right' ;; esac

  # a Label that disagrees with the filename is legal but confusing
  _l3="$SELFTEST_PREFIX-cmd3"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s-different</string>\n' "$_l3"
    printf '  <key>Program</key><string>/usr/bin/true</string>\n'
    printf '</dict></plist>\n'; } > "$_pd2/$_l3.plist"
  _o=$(_s "$_l3")
  case "$_o" in *'the filename says'*) t_ok 'a Label that disagrees with the filename is pointed out' ;;
    *) t_no 'label mismatch' 'the filename says ...' "$_o" ;; esac
}

t_loadeddiff() {
  t_sec 'R. the running definition versus the plist on disk'
  # every loaded service on THIS machine must compare equal: a false
  # positive here would cry wolf on every status
  _bad=0; _checked=0
  while IFS="$FS1" read -r _l _d _p _a _st _tr _su _er _ou _pr _us _ef _of _wat; do
    [ "$_st" = on ] || continue
    [ -n "$_p" ] && [ "$_p" != "$EM" ] || continue
    _checked=$((_checked + 1))
    case "$(show_loaded_diff "$_l" "$_d" "$_p")" in
      *DIFFERS*) _bad=$((_bad + 1)); printf '        %s\n' "$_l" ;;
    esac
  done < "$DB"
  if [ "$_checked" = 0 ]; then t_skip 'loaded-vs-disk on real services' 'nothing loaded to compare'
  else t_eq "no false differences across $_checked loaded services" 0 "$_bad"; fi

  # and a real change must be detected
  _dd2="$TMPD/ldiff"; mkdir -p "$_dd2/st"
  _lab="$SELFTEST_PREFIX-ldiff"
  t_guard "$_lab"
  _w() {
    { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><dict>\n'
      printf '  <key>Label</key><string>%s</string>\n' "$_lab"
      printf '  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>sleep %s</string></array>\n' "$1"
      printf '  <key>RunAtLoad</key><true/>\n'
      printf '</dict></plist>\n'; } > "$_dd2/$_lab.plist"
  }
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\n' \
    "$_dd2" "$_dd2" "$_dd2" > "$_dd2/conf"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents
  _w 300
  MY_LC_CONFIG="$_dd2/conf" "$0" $_sf "$_lab" enable --now >/dev/null 2>&1
  _o=$(show_loaded_diff "$_lab" "$DOMAIN" "$_dd2/$_lab.plist")
  case "$_o" in *'matches the plist'*) t_ok 'an untouched service matches' ;;
    *) t_no 'untouched matches' 'matches the plist on disk' "$_o" ;; esac

  _w 999
  _o=$(show_loaded_diff "$_lab" "$DOMAIN" "$_dd2/$_lab.plist")
  case "$_o" in *DIFFERS*) t_ok 'an edited plist is detected as different' ;;
    *) t_no 'edit detected' 'DIFFERS from the plist on disk' "$_o" ;; esac
  case "$_o" in *'running: argument sleep 300'*) t_ok 'the diff shows what is RUNNING' ;;
    *) t_no 'diff shows running side' 'running: argument sleep 300' "$_o" ;; esac
  case "$_o" in *'on disk: argument sleep 999'*) t_ok 'the diff shows what is ON DISK' ;;
    *) t_no 'diff shows disk side' 'on disk: argument sleep 999' "$_o" ;; esac

  # edit offers to apply it, and --go carries it out
  # shellcheck disable=SC2016  # $1 belongs to the generated script
  printf '#!/bin/sh\nsed -i "" "s|sleep 999|sleep 555|" "$1"\n' > "$_dd2/ed"
  chmod 755 "$_dd2/ed"
  _o=$(EDITOR="$_dd2/ed" MY_LC_CONFIG="$_dd2/conf" "$0" $_sf "$_lab" edit --go 2>&1)
  case "$_o" in *'apply it?'*'restart'*) t_ok 'edit proposes the action the service needs' ;;
    *) t_no 'edit proposes' 'apply it? ... restart' "$_o" ;; esac
  _o=$(show_loaded_diff "$_lab" "$DOMAIN" "$_dd2/$_lab.plist")
  case "$_o" in *'matches the plist'*) t_ok 'and --go applies it, so they match again' ;;
    *) t_no 'edit --go applied' 'matches the plist on disk' "$_o" ;; esac
  cleanup_fixtures

  # An edit that CHANGES THE PROGRAM must be acted on with the new value.
  # The record is built at startup, so restart went on using the OLD path,
  # refused to start a service whose plist had just been corrected - and had
  # already stopped it. The worst possible outcome of an edit.
  _sd3="$_dd2/stale"; mkdir -p "$_sd3/new" "$_sd3/old"
  _slab="$SELFTEST_PREFIX-stale"
  t_guard "$_slab"
  printf '#!/bin/sh\nsleep 300\n' > "$_sd3/new/p.sh"; chmod 755 "$_sd3/new/p.sh"
  cp "$_sd3/new/p.sh" "$_sd3/old/p.sh"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_slab"
    printf '  <key>ProgramArguments</key><array><string>%s/old/p.sh</string></array>\n' "$_sd3"
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '</dict></plist>\n'; } > "$_dd2/$_slab.plist"
  MY_LC_CONFIG="$_dd2/conf" "$0" $_sf "$_slab" enable --now >/dev/null 2>&1
  rm -rf "$_sd3/old"
  # shellcheck disable=SC2016  # $1 belongs to the generated script
  printf '#!/bin/sh\nsed -i "" "s|/old/|/new/|" "$1"\n' > "$_dd2/edstale"
  chmod 755 "$_dd2/edstale"
  _o=$(EDITOR="$_dd2/edstale" MY_LC_CONFIG="$_dd2/conf" "$0" $_sf "$_slab" edit --go 2>&1)
  case "$_o" in
    *'cannot start'*) t_no 'edit acts on the NEW definition' 'a successful restart' "$_o" ;;
    *) t_ok 'a restart after an edit uses the edited program, not the stale one' ;;
  esac
  t_eq 'and the service is left RUNNING, not stopped' on "$(t_state "$_slab")"
  cleanup_fixtures
}

t_restartrace() {
  t_sec 'S. restart must not leave the service stopped'
  _rd="$TMPD/race"; mkdir -p "$_rd/st"
  _lab="$SELFTEST_PREFIX-race"
  t_guard "$_lab"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_lab"
    printf '  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>sleep 300</string></array>\n'
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '</dict></plist>\n'; } > "$_rd/$_lab.plist"
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\n' \
    "$_rd" "$_rd" "$_rd" > "$_rd/conf"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents
  MY_LC_CONFIG="$_rd/conf" "$0" $_sf "$_lab" enable --now >/dev/null 2>&1

  # bootout returns before launchd has released the label, so a bootstrap
  # straight after can fail with 'Input/output error' and leave the service
  # DOWN - the opposite of what a restart is for. Hammer it.
  _fails=0
  for _i in 1 2 3 4 5 6 7 8; do
    MY_LC_CONFIG="$_rd/conf" "$0" $_sf "$_lab" restart --go >/dev/null 2>&1
    [ "$(t_state "$_lab")" = on ] || _fails=$((_fails + 1))
  done
  t_eq 'eight restarts in a row all end with the service running' 0 "$_fails"

  # and if a start really cannot succeed, it must SAY the service is down
  _bad="$SELFTEST_PREFIX-race2"; t_guard "$_bad"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_bad"
    printf '  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>\n'
    printf '</dict></plist>\n'; } > "$_rd/$_bad.plist"
  BOOTSTRAP_TRIES_SAVE=$BOOTSTRAP_TRIES
  t_eq 'the retry count is configurable' '3' "$("$0" --create-config | awk -F= '/^BOOTSTRAP_TRIES=/ {print $2}')"
  BOOTSTRAP_TRIES=$BOOTSTRAP_TRIES_SAVE
  cleanup_fixtures
}

t_chain() {
  t_sec 'Q. verbs chain, in the order typed'
  _cd2="$TMPD/chain"; mkdir -p "$_cd2/st"
  _lab="$SELFTEST_PREFIX-chain"
  t_guard "$_lab"
  printf 'one\ntwo\n' > "$_cd2/e.log"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_lab"
    printf '  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>sleep 300</string></array>\n'
    printf '  <key>StandardErrorPath</key><string>%s/e.log</string>\n' "$_cd2"
    printf '  <key>RunAtLoad</key><true/>\n'
    printf '</dict></plist>\n'; } > "$_cd2/$_lab.plist"
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\n' \
    "$_cd2" "$_cd2" "$_cd2" > "$_cd2/conf"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents
  _c() { MY_LC_CONFIG="$_cd2/conf" "$0" $_sf "$@" 2>&1; }

  _c "$_lab" enable --now >/dev/null 2>&1

  # ONE plan, ONE confirmation, both verbs named
  _o=$(_c truncate restart "$_lab" < /dev/null)
  case "$_o" in *'truncate, then restart'*) t_ok 'the plan names the whole chain' ;;
    *) t_no 'chain plan' 'truncate, then restart' "$_o" ;; esac
  _asks=$(printf '%s\n' "$_o" | grep -c 'add --go')
  t_eq 'it asks once, not once per verb' 1 "$_asks"

  # declining stops the WHOLE chain, not just the verb that asked
  t_eq 'declining leaves the log untouched' 8 "$(wc -c < "$_cd2/e.log" | tr -d ' ')"
  # look for the narration of a real step; ' done' also matches
  # "nothing done", which is what a decline prints
  case "$_o" in
    *'* emptying'*|*'* stopping'*|*'* starting'*)
      t_no 'nothing runs after a decline' 'no step narration' "$_o" ;;
    *) t_ok 'declining runs none of the chain' ;;
  esac

  # and it runs in the order typed
  _p1=$(launchctl list 2>/dev/null | awk -v l="$_lab" '$3==l {print $1}')
  _o=$(_c truncate restart "$_lab" --go)
  _p2=$(launchctl list 2>/dev/null | awk -v l="$_lab" '$3==l {print $1}')
  t_eq 'truncate ran' 0 "$(wc -c < "$_cd2/e.log" | tr -d ' ')"
  if [ -n "$_p1" ] && [ -n "$_p2" ] && [ "$_p1" != "$_p2" ]; then
    t_ok 'restart ran too, after the truncate'
  else t_no 'chain ran both verbs' "a new pid, was $_p1" "$_p2"; fi
  case "$_o" in
    *emptying*stopping*) t_ok 'the order typed is the order run' ;;
    *) t_no 'chain order' 'emptying before stopping' "$_o" ;;
  esac

  # the same verb twice is a mistake, not a chain
  _o=$(_c truncate truncate "$_lab" --go)
  case "$_o" in *"given twice"*) t_ok 'a repeated verb is refused' ;;
    *) t_no 'repeated verb' "the verb 'truncate' was given twice" "$_o" ;; esac
  cleanup_fixtures
}

t_failures() {
  t_sec 'P. done means it worked, and a failure shows its evidence'
  _fd="$TMPD/fail"; mkdir -p "$_fd/st"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents
  _mkp() {
    { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><dict>\n'
      printf '  <key>Label</key><string>%s</string>\n' "$1"
      [ -n "$2" ] && printf '  <key>Program</key><string>%s</string>\n' "$2"
      printf '</dict></plist>\n'; } > "$_fd/$1.plist"
  }
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\n' \
    "$_fd" "$_fd" "$_fd" > "$_fd/conf"

  # 'launchctl bootstrap' returns 0 for a plist whose program does not
  # exist - it only registers the job. Reporting 'done' for that is a false
  # success, and my-lc already knows the program is missing.
  _l1="$SELFTEST_PREFIX-nostart"; t_guard "$_l1"
  _mkp "$_l1" "$_fd/definitely-not-here"
  _o=$(MY_LC_CONFIG="$_fd/conf" "$0" $_sf "$_l1" start 2>&1); _rc=$?
  case "$_o" in
    *'cannot start'*MISSING*) t_ok 'start refuses when the program is missing' ;;
    *) t_no 'start refuses a missing program' 'cannot start ... MISSING' "$_o" ;;
  esac
  case "$_o" in *' done'*) t_no 'no false done' 'no "done"' "$_o" ;;
    *) t_ok 'it does not report done for something that cannot work' ;; esac
  t_eq 'and it exits non-zero' 1 "$_rc"

  # a plist with no program at all is a different complaint
  _l2="$SELFTEST_PREFIX-noprog"; t_guard "$_l2"
  _mkp "$_l2" ""
  _o=$(MY_LC_CONFIG="$_fd/conf" "$0" $_sf "$_l2" start 2>&1)
  case "$_o" in *'no program at all'*) t_ok 'a plist with no program is named as such' ;;
    *) t_no 'no-program plist' 'defines no program at all' "$_o" ;; esac

  # a genuine launchctl failure must show launchctl's OWN words, not just a
  # summary: the translation is a hint, the raw text is the evidence
  TMPD_SAVE=$TMPD
  DOMAIN_SAVE=$DOMAIN
  DOMAIN="gui/$(id -u)"
  _o=$( { lc bootout "$DOMAIN/no.such.service.anywhere" || step_fail "$(translate_lc_error)"; } 2>&1 )
  case "$_o" in *'launchctl exited'*'said:'*) t_ok 'a failure prints launchctl exit code and output' ;;
    *) t_no 'raw failure output' 'launchctl exited N and said:' "$_o" ;; esac
  case "$_o" in *'No such process'*) t_ok 'the exact message is preserved, not just the summary' ;;
    *) t_no 'raw text preserved' 'No such process' "$_o" ;; esac
  # ...and a success must not print a stale message from an earlier failure
  _o=$( { lc print-disabled "$DOMAIN" >/dev/null && step_ok; } 2>&1 )
  case "$_o" in *'launchctl exited'*) t_no 'stale output suppressed' 'no evidence block' "$_o" ;;
    *) t_ok 'a success prints no stale failure text' ;; esac
  DOMAIN=$DOMAIN_SAVE; TMPD=$TMPD_SAVE
  cleanup_fixtures
}

t_undelete() {
  t_sec 'O. undelete'
  _ud="$TMPD/ud"; mkdir -p "$_ud/dir" "$_ud/st"
  _lab="$SELFTEST_PREFIX-ud"
  t_guard "$_lab"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '  <key>Label</key><string>%s</string>\n' "$_lab"
    printf '  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>\n'
    printf '</dict></plist>\n'; } > "$_ud/dir/$_lab.plist"
  printf 'AGENT_DIRS="%s/dir"\nDAEMON_DIRS="%s/dir"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\nDELETE_MODE=backup\n' \
    "$_ud" "$_ud" "$_ud" > "$_ud/conf"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents
  _u() { MY_LC_CONFIG="$_ud/conf" "$0" $_sf "$@" 2>&1; }

  _u "$_lab" delete --go >/dev/null 2>&1
  if [ -f "$_ud/dir/$_lab.plist" ]; then
    t_no 'delete moved the plist' 'gone from the dir' 'still there'
  else t_ok 'the fixture is deleted, ready to undelete'; fi

  # delete must record WHERE it came from, or undelete can only guess
  if ls "$_ud"/st/deleted/"$_lab".plist.*.origin >/dev/null 2>&1; then
    t_ok 'delete records the original location'
  else t_no 'origin recorded' 'a .origin file' 'none written'; fi

  # bare undelete is a LISTING, and must not change anything
  _o=$(_u undelete)
  case "$_o" in *"$_lab"*'would go back to'*) t_ok 'bare undelete lists what can be restored' ;;
    *) t_no 'undelete listing' "$_lab ... would go back to" "$_o" ;; esac
  if [ -f "$_ud/dir/$_lab.plist" ]; then
    t_no 'listing changes nothing' 'still deleted' 'it was restored'
  else t_ok 'listing on its own restores nothing'; fi

  # naming it restores it to the RECORDED location, and re-enables it
  _u undelete "$_lab" >/dev/null 2>&1
  if [ -f "$_ud/dir/$_lab.plist" ]; then t_ok 'undelete puts the plist back where it came from'
  else t_no 'undelete restores' "$_ud/dir/$_lab.plist" 'not restored'; fi
  if launchctl print-disabled "$DOMAIN" 2>/dev/null \
     | awk -F'"' '/=> *disabled/ { print $2 }' | grep -qxF "$_lab"; then
    t_no 'undelete re-enables' 'not disabled' 'still disabled'
  else t_ok 'undelete clears the disable that delete set'; fi

  # it must refuse to overwrite something already at the destination
  _u "$_lab" delete --go >/dev/null 2>&1
  printf 'in the way\n' > "$_ud/dir/$_lab.plist"
  _o=$(_u undelete "$_lab")
  case "$_o" in *'already at'*) t_ok 'undelete refuses to overwrite what is already there' ;;
    *) t_no 'undelete overwrite guard' 'something is already at ...' "$_o" ;; esac
  rm -f "$_ud/dir/$_lab.plist"

  # a plist in the Trash that my-lc did NOT delete must never be offered:
  # installing a launch daemon from a guessed location would be reckless
  _th="$_ud/home"; mkdir -p "$_th/.Trash"
  printf 'x\n' > "$_th/.Trash/com.someone.else.plist"
  _o=$(HOME="$_th" _u undelete)
  case "$_o" in *com.someone.else*) t_no 'foreign trash excluded' 'not offered' "$_o" ;;
    *) t_ok 'a plist my-lc did not delete is never offered' ;; esac
  cleanup_fixtures
}

t_errcolumn() {
  t_sec 'M. the ERR column tells the truth about itself'
  _cd="$TMPD/errcol"; mkdir -p "$_cd/st"
  printf 'a\nb\nc\n' > "$_cd/both.log"
  printf 'x\n'         > "$_cd/only.err"
  for _v in same split; do
    if [ "$_v" = same ]; then _e="$_cd/both.log"; _u="$_cd/both.log"
    else                      _e="$_cd/only.err"; _u="$_cd/both.log"; fi
    { printf '<?xml version="1.0" encoding="UTF-8"?>\n'
      printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
      printf '<plist version="1.0"><dict>\n'
      printf '  <key>Label</key><string>%s-ec-%s</string>\n' "$SELFTEST_PREFIX" "$_v"
      printf '  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>\n'
      printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$_e"
      printf '  <key>StandardOutPath</key><string>%s</string>\n' "$_u"
      printf '</dict></plist>\n'; } > "$_cd/$SELFTEST_PREFIX-ec-$_v.plist"
  done
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=never\n' \
    "$_cd" "$_cd" "$_cd" > "$_cd/conf"
  _sf=; [ "$SCOPE" = agents ] && _sf=--agents

  _o=$(MY_LC_CONFIG="$_cd/conf" "$0" $_sf list 2>&1)
  # a shared log cannot be called an error count: say what it is, in words
  case "$_o" in *'merged with stdout:'*) t_ok 'a shared log is described, not counted as errors' ;;
    *) t_no 'merged wording' 'merged with stdout: NNL' "$_o" ;; esac
  _sp=$(printf '%s\n' "$_o" | grep -- '-ec-split')
  case "$_sp" in *'merged'*) t_no 'a separate stderr is not called merged' 'no merged' "$_sp" ;;
    *) t_ok 'a separate stderr is not described as merged' ;; esac
  # the timestamp must say WHICH moment it is: mtime is the LAST write
  case "$_sp" in *'last '*) t_ok 'the stderr timestamp is labelled as the last write' ;;
    *) t_no 'timestamp labelled' 'NNL last <when>' "$_sp" ;; esac

  # every real stderr is coloured - that IS the case worth looking at
  printf 'AGENT_DIRS="%s"\nDAEMON_DIRS="%s"\nSTATE_DIR="%s/st"\nDEFAULT_FILTER_STATE=all\nCOLOR=always\n' \
    "$_cd" "$_cd" "$_cd" > "$_cd/confc"
  _o=$(MY_LC_CONFIG="$_cd/confc" "$0" $_sf list 2>&1 | grep -- '-ec-split')
  case "$_o" in
    *"$(printf '\033')[31m"*) t_ok 'a service with its own stderr is highlighted' ;;
    *) t_no 'stderr is red' 'a red ERR cell' "$_o" ;;
  esac
  # ...except a merged one, where an error cannot be told from ordinary output
  _o=$(MY_LC_CONFIG="$_cd/confc" "$0" $_sf list 2>&1 | grep -- '-ec-same')
  case "$_o" in
    *"$(printf '\033')[31m"*'merged'*) t_no 'merged is not coloured' 'plain text' "$_o" ;;
    *) t_ok 'a merged log is left plain, since it is not an error count' ;;
  esac
}

t_timefmt() {
  t_sec 'L. time rendering follows the config'
  _now=$(now_epoch)
  _then=$(( _now - 90000 ))
  TIME_FORMAT=relative
  case "$(when "$_then")" in
    *d*h) t_ok 'relative mode gives an age' ;;
    *) t_no 'relative mode' 'NNdNNh' "$(when "$_then")" ;;
  esac
  TIME_FORMAT=absolute
  case "$(when "$_then")" in
    20[0-9][0-9]-[01][0-9]-[0-3][0-9]_[0-2][0-9][0-5][0-9])
      t_ok "absolute mode gives a timestamp ($(when "$_then"))" ;;
    *) t_no 'absolute mode' 'YYYY-MM-DD_HHMM' "$(when "$_then")" ;;
  esac
  _save=$TIME_FMT; TIME_FMT='%Y%m%d'
  t_eq 'TIME_FMT is honoured' "$(date -r "$_then" '+%Y%m%d')" "$(when "$_then")"
  TIME_FMT=$_save
  t_eq 'an empty moment is ? and not a crash' '?' "$(when '')"

  # absolute is the DEFAULT: a timestamp can be lined up against other logs,
  # an age cannot
  _o=$("$0" --create-config 2>/dev/null | grep '^TIME_FORMAT=')
  t_eq 'the shipped default is absolute' 'TIME_FORMAT=absolute' "$_o"
  _o=$("$0" --create-config 2>/dev/null | grep '^DELETE_MODE=')
  t_eq 'the shipped delete mode is the dated backup' 'DELETE_MODE=backup' "$_o"

  # boot time must be parsed from the RIGHT number: '.*sec' also matches
  # 'usec', which captures the microseconds and dates everything to 1970
  if [ -n "$BOOT_EPOCH" ]; then
    if [ "$BOOT_EPOCH" -gt 1000000000 ] 2>/dev/null; then
      t_ok "boot time parsed as a real epoch ($(date -r "$BOOT_EPOCH" '+%Y-%m-%d'))"
    else
      t_no 'boot epoch is sane' 'a 10-digit epoch' "$BOOT_EPOCH"
    fi
    _up=$(( $(now_epoch) - BOOT_EPOCH ))
    if [ "$_up" -gt 0 ] && [ "$_up" -lt 315360000 ]; then
      t_ok 'boot time gives a plausible uptime'
    else t_no 'uptime from boot time' 'between 0 and 10 years' "$_up seconds"; fi
  else
    t_no 'boot time is readable' 'an epoch from kern.boottime' 'empty'
  fi
  TIME_FORMAT=relative
}

t_exitcodes() {
  t_sec 'I. exit codes are explained, not just numbered'
  t_eq 'sysexits 78 is a config error'    'config error'      "$(exit_meaning 78 short)"
  t_eq 'sysexits 71 is an OS error'       'OS error'          "$(exit_meaning 71 short)"
  t_eq '127 is a missing program'         'not found'         "$(exit_meaning 127 short)"
  t_eq '137 is death by SIGKILL'          'killed: KILL'      "$(exit_meaning 137 short)"
  t_eq '143 is death by SIGTERM'          'killed: TERM'      "$(exit_meaning 143 short)"
  t_eq 'an unknown code gets no invented meaning' '' "$(exit_meaning 200 short)"
  case "$(exit_meaning 78 long)" in
    EX_CONFIG*) t_ok 'the record view gets the long form' ;;
    *) t_no 'long form for 78' 'EX_CONFIG...' "$(exit_meaning 78 long)" ;;
  esac
  # the short and long forms must not be confused with each other
  if [ "$(exit_meaning 78 short)" != "$(exit_meaning 78 long)" ]; then
    t_ok 'short and long forms differ'
  else t_no 'short and long differ' 'two different strings' 'identical'; fi
}

t_watch() {
  t_sec 'E. WatchPaths — MISSING and ? are never conflated'
  _wd="$TMPD/wtest"; mkdir -p "$_wd/open" "$_wd/closed"
  : > "$_wd/open/there"
  : > "$_wd/closed/hidden"
  chmod 000 "$_wd/closed"

  t_eq 'an existing file is ok'            'ok file' "$(path_verdict "$_wd/open/there")"
  t_eq 'an existing dir is ok'             'ok dir'  "$(path_verdict "$_wd/open")"
  t_eq 'a genuinely absent path is MISSING' MISSING  "$(path_verdict "$_wd/open/nope")"

  if [ "$(id -u)" = 0 ]; then
    t_skip 'the unreadable-parent case' 'root can read everything, so ? cannot occur'
  else
    case "$(path_verdict "$_wd/closed/hidden")" in
      '?'*) t_ok 'a path under an unreadable dir is ?, never a false MISSING' ;;
      *)    t_no 'unreadable parent -> ?' '? ... not readable' "$(path_verdict "$_wd/closed/hidden")" ;;
    esac
  fi

  # and the summary that feeds the trigger suffix
  t_eq 'watch_summary flags a missing path' '!' "$(watch_summary "$_wd/open/there|$_wd/open/nope")"
  t_eq 'watch_summary is ok when all exist' 'ok' "$(watch_summary "$_wd/open/there")"

  chmod 755 "$_wd/closed"
}

t_logs() {
  t_sec 'F. the log delta'
  _ld="$TMPD/logs"; mkdir -p "$_ld"
  _el="$_ld/err"; _ol="$_ld/out"
  printf 'old-line-1\nold-line-2\n' > "$_el"
  printf 'old-out-1\n' > "$_ol"
  _lab="$SELFTEST_PREFIX-logs"
  DOMAIN_SAVE=$DOMAIN

  t_eq 'the watermark lives under /var/lib, not /var/log' \
       "1" "$(case "$STATE_DIR" in /var/lib/*) echo 1 ;; *) echo 0 ;; esac)"

  write_mark "$_lab" "$_el" "$_ol" exact
  if [ -r "$(mark_file "$_lab")" ]; then
    t_ok 'a watermark is written before the action'
    printf 'new-line-3\n' >> "$_el"
    printf 'new-out-2\n'  >> "$_ol"
    _o=$(show_log_delta "$_lab" "$_el" "$_ol")
    case "$_o" in
      *new-line-3*) t_ok 'the delta contains the line added after the mark' ;;
      *) t_no 'delta contains the new line' 'new-line-3' "$_o" ;;
    esac
    case "$_o" in
      *old-line-1*) t_no 'delta excludes the older lines' 'no old-line-1' "$_o" ;;
      *) t_ok 'the delta excludes everything from before the mark' ;;
    esac
    case "$_o" in
      *new-out-2*) t_ok 'stdout is shown as well as stderr' ;;
      *) t_no 'stdout in the delta' 'new-out-2' "$_o" ;;
    esac
    # A crash-looping daemon can leave hundreds of MB. This must stay fast
    # AND must not print the lot: counting 12.6M lines took 18s of CPU on a
    # real 1 GB log and produced ten lines of output.
    _big="$_ld/big"
    awk 'BEGIN { for (i = 1; i <= 400000; i++) print "line " i " padded out to make it wide enough to matter" }' > "$_big"
    write_mark "$_lab" "$_big" "$_ol" exact
    awk 'BEGIN { for (i = 1; i <= 400000; i++) print "new " i " padded out to make it wide enough to matter" }' >> "$_big"
    _t0=$(date '+%s')
    _o=$(show_log_delta "$_lab" "$_big" "$_ol")
    _el2=$(( $(date '+%s') - _t0 ))
    if [ "$_el2" -le 2 ]; then t_ok "a 400k-line delta renders in ${_el2}s"
    else t_no 'a large delta stays fast' 'at most 2s' "${_el2}s"; fi
    case "$_o" in
      *MB*new*) t_ok 'a large delta is reported by size, not by counting lines' ;;
      *) t_no 'large delta reported by size' 'NN.NMB new' "$(printf '%s' "$_o" | head -n 3)" ;;
    esac
    case "$_o" in
      *"new 400000"*) t_ok 'the last lines shown come from the END of the delta' ;;
      *) t_no 'large delta shows the newest lines' 'new 400000' "$(printf '%s' "$_o" | tail -n 3)" ;;
    esac
    _lines=$(printf '%s\n' "$_o" | wc -l | tr -d ' ')
    if [ "$_lines" -lt 40 ]; then t_ok "the output stays short ($_lines lines)"
    else t_no 'large delta output is capped' 'under 40 lines' "$_lines lines"; fi
    # a SMALL delta still gets an exact line count, which is the useful fact
    _sm="$_ld/small"; printf 'a\nb\nc\n' > "$_sm"
    write_mark "$_lab" "$_sm" "$_ol" exact
    printf 'd\ne\n' >> "$_sm"
    _o=$(show_log_delta "$_lab" "$_sm" "$_ol")
    case "$_o" in
      *d*e*) t_ok 'a small delta is still shown line by line' ;;
      *) t_no 'small delta shown in full' 'd and e' "$_o" ;;
    esac
    # nothing new must STILL show the tail: an empty delta is an answer,
    # but leaving the reader with no log content is not
    write_mark "$_lab" "$_sm" "$_ol" exact
    _o=$(show_log_delta "$_lab" "$_sm" "$_ol")
    case "$_o" in
      *"nothing new"*) t_ok 'an empty delta says so' ;;
      *) t_no 'empty delta reported' 'nothing new' "$_o" ;;
    esac
    case "$_o" in
      *e*) t_ok 'an empty delta still shows the tail of the log' ;;
      *) t_no 'empty delta shows the tail' 'the last lines' "$_o" ;;
    esac
    # stderr and stdout very often point at ONE file. Showing the identical
    # tail twice is noise, and the ERR count is then not stderr alone.
    # a fresh label: the earlier tests left a watermark on $_lab
    _one="$_ld/one.log"; printf 'alpha\nbeta\n' > "$_one"
    _o=$(show_log_delta "$SELFTEST_PREFIX-merged" "$_one" "$_one")
    case "$_o" in
      *'stderr+stdout (one file)'*) t_ok 'one file serving both streams is shown once' ;;
      *) t_no 'merged log shown once' 'stderr+stdout (one file)' "$_o" ;;
    esac
    _n2=$(printf '%s\n' "$_o" | grep -c alpha)
    t_eq 'a merged log is not printed twice' 1 "$_n2"
    rm -f "$_one" "$_big" "$_sm"

    # truncation must not produce a negative offset
    write_mark "$_lab" "$_el" "$_ol" exact
    : > "$_el"
    printf 'after-truncate\n' >> "$_el"
    _o=$(show_log_delta "$_lab" "$_el" "$_ol")
    case "$_o" in
      *after-truncate*) t_ok 'a truncated log restarts the delta from the start' ;;
      *) t_no 'truncation handling' 'after-truncate' "$_o" ;;
    esac
  else
    t_skip 'log delta tests' "cannot write $STATE_DIR/marks"
  fi
  DOMAIN=$DOMAIN_SAVE
  t_eq 'log_indicator reports lines for a non-empty log' \
       '1' "$(case "$(log_indicator "$_el")" in [0-9]*L*) echo 1 ;; *) echo 0 ;; esac)"
  : > "$_el"
  t_eq 'log_indicator reports - for an empty log' '-' "$(log_indicator "$_el")"
  t_eq 'log_indicator reports - for a missing log' '-' "$(log_indicator "$_ld/nope")"
}

t_completion() {
  t_sec 'G. completion'
  _scopeflag=
  [ "$SCOPE" = agents ] && _scopeflag=--agents

  # Put a fixture into each state the verbs need, so no assertion is
  # skipped merely because this particular machine happens to have no
  # service in that state. A skipped assertion proves nothing.
  _cpl=$(t_plist compl)
  _clab="$SELFTEST_PREFIX-compl"
  t_guard "$_clab"
  launchctl bootout "$DOMAIN/$_clab" >/dev/null 2>&1
  launchctl disable "$DOMAIN/$_clab" >/dev/null 2>&1
  t_eq 'the completion fixture is off' off "$(t_state "$_clab")"

  # off -> 'enable' must offer it, and the verbs needing a loaded service
  # must NOT
  _o=$(MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --complete-labels enable 2>&1)
  case "$_o" in
    *"$_clab"*) t_ok '--complete-labels enable offers a disabled service' ;;
    *) t_no 'enable completes a disabled service' "$_clab in the set" "$_o" ;;
  esac
  for _v in stop restart run kill; do
    _o=$(MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --complete-labels "$_v" 2>&1)
    case "$_o" in
      *"$_clab"*) t_no "--complete-labels $_v excludes an off service" "not $_clab" "$_o" ;;
      *) t_ok "--complete-labels $_v excludes an off service" ;;
    esac
  done

  # now bring it up, and the sets invert
  MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --all "$_clab" enable --now >/dev/null 2>&1
  if [ "$(t_state "$_clab")" = on ]; then
    for _v in disable stop restart run; do
      _o=$(MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --complete-labels "$_v" 2>&1)
      case "$_o" in
        *"$_clab"*) t_ok "--complete-labels $_v offers a running service" ;;
        *) t_no "$_v completes a running service" "$_clab in the set" "$_o" ;;
      esac
    done
    _o=$(MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --complete-labels enable 2>&1)
    case "$_o" in
      *"$_clab"*) t_no '--complete-labels enable excludes an already-on service' "not $_clab" "$_o" ;;
      *) t_ok '--complete-labels enable excludes an already-on service' ;;
    esac
  else
    t_no 'the completion fixture reached on' on "$(t_state "$_clab")"
  fi

  # narrowing really is narrowing: disable offers only enabled services
  _o=$(MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --complete-labels disable 2>/dev/null)
  _bad=0
  for _l in $_o; do
    _s=$(awk -F"$FS1" -v l="$_l" '$1==l { print $5; exit }' "$DB")
    case "$_s" in on|@on|'') ;; *) _bad=$((_bad+1)) ;; esac
  done
  t_eq 'disable completes only services whose flag is on' 0 "$_bad"

  # and it stays cheap: at most three launchctl invocations for the set
  _cnt=$(t_count_launchctl)
  if [ "$_cnt" -le 3 ]; then t_ok "the label set costs $_cnt launchctl call(s), within the budget of 3"
  else t_no 'launchctl call budget' 'at most 3' "$_cnt"; fi
}

# Count launchctl invocations for one --complete-labels run, by putting a
# counting stub ahead of the real one on PATH.
t_count_launchctl() {
  _sd="$TMPD/stub"; mkdir -p "$_sd"
  : > "$TMPD/lc.count"
  cat > "$_sd/launchctl" <<STUB
#!/bin/sh
echo x >> "$TMPD/lc.count"
exec /bin/launchctl "\$@"
STUB
  chmod 755 "$_sd/launchctl"
  _scopeflag=
  [ "$SCOPE" = agents ] && _scopeflag=--agents
  PATH="$_sd:$PATH" MY_LC_CONFIG="$T_CONF" "$0" $_scopeflag --complete-labels enable >/dev/null 2>&1
  wc -l < "$TMPD/lc.count" | tr -d ' '
}

main "$@"
