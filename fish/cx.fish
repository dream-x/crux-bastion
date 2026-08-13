# cx — the bastion client on the local machine: a short command leading to the agent
# sessions on the bastion host.
#
# Three layers: cx (here) → lab-host (on the bastion host) → lab (in the container). cx
# does not parse the command grammar: the arguments go into lab-host as they are. The only
# thing it knows about that grammar is which commands are one-shot (the `$__cx_oneshot`
# list below), and it is exactly cx that is obliged to know it: the transport is chosen at
# this end, before any connection to the bastion host at all. The list is a single one for
# the file — both the transport choice and the line in the help derive from it.
#
# It is installed as a symlink from the repository into ~/.config/fish/functions/cx.fish,
# so the file name must match the function name — otherwise fish's autoloading will not
# find it.
#
# The exit codes are the ones the remote lab-host returned (1 — a tmux error, 2 — bad
# arguments, 3 — the container is not running, 4 — docker is unavailable). `cx run` has
# someone else's code: lab hands the process over to the agent, and the agent's code
# arrives, including 3 and 4 — trouble in the bastion is told apart from them by a
# "lab-host: …" or "lab: …" line on stderr. The second caveat: mosh does not propagate the
# remote command's code at all, so a meaningful exit code exists only in the ssh branches —
# for one-shot commands and for calls without a terminal. Only sessions go over mosh (`cx`,
# `cx attach`, `cx omp|pi|claude`), and they have no need for an exit code. A leading `--`
# does not affect that division: the transport is chosen by the first word after it.
#
# CX_HOST — the ssh alias of the bastion host (bastion by default, defined in ~/.ssh/config).

# One-shot commands: they print a line or two and are done, so they go over ssh rather than
# through mosh. The list is a single one for the file: both the transport choice and the
# line in the help derive from it. `-h` is in it for completeness — a bare `cx -h` is
# intercepted locally and never reaches the transport, but `cx -- -h` travels off for lab's
# own help, and that one is one-shot too.
set -g __cx_oneshot run ls kill --help -h

function __cx_usage --description 'cx help'
    # the list of one-shot commands is substituted rather than retyped: a copy would drift
    # apart from the transport check exactly when a new subcommand is added to lab
    # `--` is mandatory: the list contains `--help`, and without it `string join` would read
    # that as an option of its own and would fail right inside the help
    set -l cx_oneshot_list (string join -- ', ' $__cx_oneshot)
    echo "cx — agent sessions on the bastion host (bastion client)

usage:
  cx                       session menu on the bastion host, pick by number
  cx ls                    list sessions
  cx attach <name>         attach or create a session
  cx omp|pi|claude         attach or create a session running that agent
  cx run <agent> <text>    one-shot request, no tmux, clean stdout
  cx kill <name>           kill a session
  cx -- --help             help of lab itself, from inside the container
  cx --help                this help

transport: sessions go over mosh when both ends have a terminal, ssh otherwise;
           one-shot commands always go over ssh, so their exit code survives
           ($cx_oneshot_list); a leading -- does not change
           that (cx -- kill x is still one-shot)
environment: CX_HOST picks the ssh alias (default: bastion)"
end

function __cx_remote --description 'the command line for the remote shell: lab-host with POSIX quoting'
    # ssh joins its own arguments with spaces and hands them to the remote shell as a single
    # string, so the quoting has to be done here: without it `cx run omp "two words"` would
    # arrive as two arguments. Only what actually requires it is quoted — otherwise the
    # command cannot be read either in `ps` or in the stub's log.
    #
    # The string is assembled by concatenation rather than through `set -a`: the argument
    # `--` (and it does arrive, in `cx -- --help`) would be eaten by the `set` builtin as
    # the end of its own options.
    set -l cx_line lab-host
    for cx_arg in $argv
        # Trailing newlines are stripped straight away: fish's command substitution does not
        # carry them over, and an argument made of nothing but \n falls apart in it into two
        # empty elements — and one and the same command travels to the remote shell twice.
        # Newlines inside the argument are preserved as they are.
        set -l cx_clean (string replace -r -- '\n+\z' '' $cx_arg | string collect)
        if test -z "$cx_clean"
            # an empty argument is an argument too, and it is obliged to arrive empty: the
            # general branch below would turn it into a lone space. The check comes first
            # also because `string match` with no strings would read stdin
            set cx_line "$cx_line ''"
        else if string match -qr -- '\A[A-Za-z0-9_.,:@/+-][A-Za-z0-9_.,:=@/+-]*\z' $cx_clean
            # The anchors are \A and \z specifically, not ^ and $: in PCRE `$` also matches
            # before a final newline, so "foo\n" passed for "no quoting needed" and travelled
            # raw — the remote shell saw a second command right after it.
            #
            # The first character is a class of its own, without `=`: the remote shell we
            # tested against is zsh (its `~/.zshenv` is read by a non-interactive ssh too),
            # and zsh has EQUALS enabled by default — a word starting with `=` is replaced
            # by the path to the command of that name. `attach =ls` arrived as `/bin/ls`,
            # and `run pi =hello` brought the whole line down ("zsh: hello not found")
            # before it ever reached lab-host. Inside a word `=` is harmless: the only thing
            # standing in command position is `lab-host` itself, so `LANG=C` will not turn
            # into an assignment and there is no reason to quote it.
            set cx_line "$cx_line $cx_clean"
        else
            # the classic POSIX substitution: single quotes around it, and a single quote
            # inside turns into '\'' — it survives any characters, including a newline
            # (which `string collect` preserves, otherwise the argument would fall apart)
            set cx_line "$cx_line '"(string replace --all -- "'" "'\\''" $cx_clean | string collect)"'"
        end
    end
    printf '%s\n' $cx_line
end

function cx --description 'agent sessions on the bastion host: mosh with a fallback to ssh'
    # an empty CX_HOST does not count as set: the same semantics as ${LAB_CONTAINER:-claude}
    # in lab-host, otherwise ssh would get an empty host name and would complain in a way
    # nobody can make sense of
    set -l cx_host bastion
    test -n "$CX_HOST"; and set cx_host $CX_HOST

    switch "$argv[1]"
        case -h --help
            __cx_usage
            return 0
    end

    # The decision about the transport is taken on the same command that lab will see —
    # that is, already without the leading `--`. The `--` itself does not go anywhere and
    # travels on (lab-host will strip it, exactly one): without this step everything that
    # goes through the `cx -- ...` loophole bypassed the rule below and went over mosh.
    set -l cx_words $argv
    if test (count $cx_words) -gt 0; and test "$cx_words[1]" = --
        set -e cx_words[1]
    end

    # Only sessions go over mosh: mosh is a terminal emulator, it hands back a painted
    # screen instead of clean stdout and does not propagate the exit code (`cx kill nope`
    # over mosh would return 0 for a session that does not exist). The older one-shot
    # wrappers this replaces could handle pipes and scripts, and the replacement is obliged
    # to handle them too.
    set -l cx_is_oneshot 0
    if contains -- "$cx_words[1]" $__cx_oneshot
        set cx_is_oneshot 1
    end

    # A terminal is needed at both ends: the mosh client will not start without one at all,
    # and lab-host decides by the TTY whether to give `docker exec -it`.
    set -l cx_tty 0
    if isatty stdin; and isatty stdout
        set cx_tty 1
    end

    if test $cx_is_oneshot -eq 0; and test $cx_tty -eq 1; and command -q mosh
        # the arguments go as a list: the mosh wrapper quotes them itself (shell_quote), so
        # a second helping of quotes here would only break things
        mosh $cx_host -- lab-host $argv
        set -l cx_rc $status
        if test $cx_rc -eq 0
            return 0
        end
        # Any non-zero code from mosh is trouble with the transport, not with the remote
        # command: mosh does not propagate the remote command's code and returns 0 on a
        # normal exit as well (including when the user detaches). That is why the fallback
        # does not fire on an ordinary exit from a session, and does fire when the client
        # could not connect.
        #
        # Re-running here is safe precisely because only sessions go over mosh:
        # attach-or-create is idempotent, and a repeat brings you back into the same
        # session. The non-idempotent `kill` never lands in this branch at all (see
        # $__cx_oneshot).
        echo "cx: mosh exited $cx_rc, falling back to ssh" >&2
    end

    set -l cx_remote (__cx_remote $argv | string collect -a)
    if test $cx_tty -eq 1; and test $cx_is_oneshot -eq 0
        ssh $cx_host -t $cx_remote
    else
        ssh $cx_host $cx_remote
    end
end
