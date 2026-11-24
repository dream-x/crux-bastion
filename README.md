# crux-bastion

Persistent terminal sessions for coding agents running in a container — reachable with one
command from a laptop, tablet or phone, and surviving the network drops that kill plain `ssh`.

```console
$ cx omp                    # attach or create a session running the agent
$ cx                        # numbered menu of live sessions
$ cx run pi "2+2"           # one-shot query, clean stdout, real exit code
4
```

Close the lid, lose Wi-Fi, switch from LAN to LTE — the session keeps running on the host.
Reconnect with the same command and you are back where you stopped.

## Why

Running a coding agent over `ssh host 'docker exec -it …'` works until the link blinks. Then the
agent dies mid-task, and you have no way back into the conversation you were having with it.

The fix is not new — `tmux` has solved it for decades. What this project adds is the plumbing
around it: choosing the right transport, detecting whether a TTY exists, telling a stopped
container apart from a dead Docker daemon, and keeping exit codes honest so the whole thing
works in pipes and scripts too.

## How it works

Three thin layers, each owning exactly what the others cannot know:

```
your machine     cx (fish)      picks the transport, quotes arguments
    │                           mosh for sessions, ssh for one-shots
    ▼
container host   lab-host (sh)  TTY detection, Docker daemon and container state
    │
    ▼
container        lab (sh)       tmux: attach-or-create, list, kill, agent presets
```

The core is a single idempotent call — `tmux new -As <name>` attaches to a session if it exists
and creates it otherwise. Everything else exists to reach that call, survive a broken link, and
report the truth about what happened.

**Sessions live in the container**, so they survive a dropped connection, a closed laptop and a
killed client. They do **not** survive a container restart, a stopped Docker VM or a host reboot.

## Requirements

| where | needs |
|---|---|
| your machine | `fish`, `ssh`; `mosh` or `tssh` recommended (that is what survives roaming and sleep) |
| container host | `docker`, `mosh-server` or `tsshd` to match, ssh access |
| container | `tmux`, whichever agents you configure; `trz`/`tsz` for [file transfer](#file-transfer) |

Tested on macOS clients and a Linux container. The host layer is written for a macOS host running
Colima, but only in one place: the hint it prints when the Docker daemon is unreachable.

## Install

```bash
git clone https://github.com/dream-x/crux-bastion.git ~/src/crux-bastion

# client
ln -sfn ~/src/crux-bastion/fish/cx.fish ~/.config/fish/functions/cx.fish

# container host
scp ~/src/crux-bastion/bin/lab-host <host>:bin/lab-host
ssh <host> 'chmod 0755 ~/bin/lab-host'

# into the container: bind-mount the script so updates need no image rebuild
ssh <host> 'mkdir -p ~/stack/bin'
scp ~/src/crux-bastion/bin/lab <host>:stack/bin/lab
ssh <host> 'chmod 0755 ~/stack/bin/lab'
```

Add the mount to your compose file:

```yaml
services:
  agents:
    volumes:
      - ./bin/lab:/usr/local/bin/lab:ro
```

For [file transfer](#file-transfer) also mount the tmux bindings, the same way:

```yaml
      - ./bin/lab.tmux.conf:/etc/tmux.conf:ro
```

Updating `lab` later is `scp` plus `docker restart <container>` — see [Gotchas](#gotchas) for why
the restart is not optional.

## Configuration

Everything is environment variables; there is no config file.

| variable | layer | default | meaning |
|---|---|---|---|
| `CX_HOST` | cx | `bastion` | ssh alias of the container host |
| `CX_TRANSPORT` | cx | `mosh` | what carries sessions: `mosh`, `tssh` (UDP mode, keeps trzsz working) or `ssh` |
| `LAB_CONTAINER` | lab-host | `agents` | container name |
| `LAB_AGENTS` | lab | `claude codex omp` | space-separated agent names that get presets |
| `LAB_WORKDIR` | lab | `/workspace` | working directory for sessions |
| `LAB_UPLOAD_DIR` | lab | `/exchange/upload` | where `lab up` puts uploaded files, a fresh directory per upload |
| `LAB_DRY_RUN` | all | unset | print the command instead of running it |

The defaults are plausible examples, not magic: any agent on `PATH` inside the container can be
added to `LAB_AGENTS`, and a preset is just `tmux new -As <agent> -c <workdir> <agent>`.

`CX_HOST` belongs in your shell config, `LAB_CONTAINER` in the **host's** environment
(`~/.zshenv` for non-interactive ssh), and `LAB_AGENTS` in the container's environment.

## Commands

```
cx                        session menu, pick by number
cx attach <name>          attach or create a named session
cx <agent>                attach or create a session running that agent
cx run <agent> <text>     one-shot query: no tmux, clean stdout, agent's exit code
cx ls                     list sessions
cx kill <name>            kill a session
cx -- <args>              pass everything through untouched

inside a session (tmux prefix, then):
U                         upload files from your machine, their paths are typed into the prompt
D                         a shell popup for `tsz <file>`, downloads to your machine
```

Exit codes:

| code | meaning |
|---|---|
| 0 | success |
| 1 | tmux error, e.g. no such session |
| 2 | bad arguments |
| 3 | container not running |
| 4 | Docker unavailable — daemon down or no CLI in PATH |

`run` is deliberately transparent: it `exec`s the agent, so you get the **agent's** exit code,
including 3 and 4. Distinguishing them is by stderr — a bastion failure always carries a
`lab:` or `lab-host:` line, an agent's code arrives silently.

## File transfer

An agent often needs a file that is on your machine — a screenshot, a log, a PDF. mosh
cannot help: it redraws a screen instead of passing the byte stream through, so in-band
transfer protocols die in it. [trzsz](https://trzsz.github.io/) does work end to end once
the transport passes bytes through: `tssh` (the trzsz-ssh client) in UDP mode survives
roaming and sleep the way mosh does, and keeps the stream intact.

```
your machine     tssh --udp      shows the file dialog, sends / receives the files
    │
container host   tsshd           the UDP end of the session, one process per session
    │
container        tmux popup      trz / tsz, started by prefix + U / D
```

Set it up once:

```bash
brew install trzsz-ssh                       # your machine: tssh
# container host: tsshd from https://github.com/trzsz/tsshd/releases, on PATH for ssh
# container: trz and tsz from https://github.com/trzsz/trzsz-go/releases
set -Ux CX_TRANSPORT tssh                    # fish, your machine
```

Then, inside any `cx` session, **prefix + U** opens a popup and the client's file dialog;
the files land in a fresh directory under `$LAB_UPLOAD_DIR`, and their paths are typed
into the agent's prompt — without Enter, so you still decide what to say about them.
**prefix + D** opens a shell popup in the pane's directory: `tsz <file>` sends a file to
your machine, `exit` closes the popup.

The popup matters: in tmux, trz writes its handshake straight to the client's terminal and
reads the answer from the keyboard of the pane it runs in. Started in the agent's own pane,
that answer would be typed into the agent's prompt.

A detach (prefix + d) ends the session's tsshd. If the client dies instead — the laptop is
closed for good, the terminal is killed — tsshd keeps waiting for it to come back, for ten
days by default. Shorten that for the bastion in `~/.ssh/config`:

```
Host crux
    #!! UdpAliveTimeout 86400
```

## Gotchas

The things that cost the most time to find. Each is a live-system behaviour that unit tests
happily miss.

**tmux resolves targets by prefix.** `tmux kill-session -t wor` kills a session named `work` and
exits 0 — no warning, no hint that the wrong thing died. Meanwhile `tmux new -As foo` is exact,
so attach and kill disagree about what a name means. Use `=name` to force an exact match:

```sh
tmux has-session -t "=$name"
tmux kill-session -t "=$name"
```

**Docker error text changes between versions.** Matching `Error: No such object` worked until
Docker 29 started writing `error: no such object`. A case-sensitive match turned a whole branch
into dead code, so instead of "container is not running" users got a raw Docker error. Lowercase
before matching, and order the branches carefully — the dead-socket message contains
`no such file or directory`, which a broad pattern misreads as a missing container.

**zsh expands a word-initial `=`.** With the `EQUALS` option on by default, `lab-host attach =ls`
arrives as `/bin/ls`, and `run pi =hello` aborts the whole command line with `zsh: hello not
found`. If your quoting has a "safe characters, no quotes needed" fast path, keep `=` out of the
**first** character class. Test your quoting by replaying the built command through the shell that
actually runs on the far side — replaying through `sh` hides this entirely.

**tssh reads options after the host name.** `tssh host sh -c 'exit 3'` takes `-c` as its
own cipher option and fails the handshake with "no common algorithm". The remote command
has to travel as one string — the one already quoted for ssh. tsshd then splits it into
words itself, with no shell on the far side, following the same POSIX quoting rules.

**tmux 3.3 does not expand formats in a popup's command.** `display-popup "echo #{pane_id}"`
runs `echo` followed by a shell comment. Inside the popup, `tmux display-message -p` still
answers for the pane under it, which is how `lab up` finds where to type.

**mosh does not propagate the remote exit code.** It is a terminal emulator: it returns a rendered
screen and its own status, so `kill nope` comes back as success. Route anything whose output or
exit code matters over plain ssh, and keep mosh for interactive sessions. This also means a
non-zero mosh exit only ever indicates a transport problem — which makes it a safe trigger for an
ssh fallback, as long as the retried command is idempotent.

## Development

```bash
brew install bats-core shellcheck fish tmux

bats tests                                        # 152 cases
LAB_SH=/bin/dash LAB_TESTS_STRICT=1 bats tests    # the shell the container actually uses
shellcheck -s sh bin/* tests/stubs/*
fish -n fish/cx.fish
```

Tests never create sessions, touch Docker or wake an agent: `tests/stubs/` goes to the front of
`PATH` and every external command is replaced by a stub that records its arguments.
`LAB_TESTS_STRICT=1` turns "tool missing, skipping" into a failure, so a missing dependency cannot
quietly disable coverage.

Two conventions worth keeping if you contribute: the scripts are POSIX `sh` because the container
runs `dash`, not bash — `shellcheck -s sh` enforces it; and behaviour learned from a live system
gets a comment explaining *why*, since that is the part no test can capture.

## License

MIT
