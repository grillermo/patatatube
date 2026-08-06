"""Gunicorn config — process naming that survives fork without tripping EXC_GUARD.

Background (2026-08-06): workers were dying at boot with

    [ERROR] Worker (pid:21137) was sent SIGKILL! Perhaps out of memory?

It was never memory. The crash report showed EXC_GUARD / GUARD_TYPE_MACH_PORT
with "crashed on child side of fork pre-exec", faulting in:

    spt_setproctitle -> darwin_set_process_title
      -> _LSSetApplicationInformationItem            (LaunchServices)
        -> xpc_connection_send_message_with_reply_sync
          -> mach_msg2_trap                          <- kernel kills the process

On macOS, setproctitle() renames a process through a *synchronous
LaunchServices XPC round-trip*. Doing that on the child side of a fork from a
multi-threaded parent is illegal: the inherited Mach port is guarded, and
touching it is fatal. libxpc's pthread_atfork handlers usually reset the child's
connection state, which is why this only killed ~1 worker per ./serve rather
than all of them -- the fatal window needs an XPC call in flight at fork().
Rare, racy, and unfixable by try/except: SIGKILL is not catchable.

The fix relies on two measured facts:
  1. A title set BEFORE forking is inherited by every child (fork copies it).
  2. On macOS only the LaunchServices call actually moves the needle -- an
     argv[0] override via `exec -a` does nothing, because ps reads the kernel's
     saved exec path.

So: name the process exactly once, in the arbiter, before any fork, and make
every post-fork naming call a no-op. Workers therefore inherit the name instead
of setting it themselves. Per-worker distinct names are deliberately NOT
attempted -- that would require the post-fork LS call that caused the crash.
"""

import gunicorn.util
from setproctitle import setproctitle

PROCESS_NAME = "[PatataTube]"

# Disarm gunicorn's own naming. arbiter.py does `from gunicorn import util` and
# calls `util._setproctitle(...)`, so patching the module attribute intercepts
# every call site -- including arbiter.py:605, which runs under "# Process
# Child", i.e. post-fork. That call is the same hazard as the one that killed
# pid 21137; leaving the setproctitle package installed without this patch would
# re-arm it. Patching here is safe because a config file is imported by the
# arbiter before workers are spawned, so children inherit the patched module.
gunicorn.util._setproctitle = lambda title: None


def on_starting(server):
    """Arbiter hook: runs at arbiter.py:137, before manage_workers() at :201.

    Single-threaded, post-exec, pre-fork -- the only point where the
    LaunchServices call is safe. Every worker inherits this title.
    """
    setproctitle(PROCESS_NAME)
