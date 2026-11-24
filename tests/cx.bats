#!/usr/bin/env bats
#
# Tests for `cx`: picking the transport (mosh versus ssh), the fallback, and the quoting
# of arguments. Neither the real mosh nor the real ssh is ever called — the stubs come
# first in PATH.
#
# `cx` is not a script but a fish function, so every test starts `fish --no-config` and
# sources the file exactly the way fish autoloading will later. The user config is turned
# off on purpose: it holds its own functions, wrappers and PATH edits, and a test must
# not depend on them.
#
# Without fish and without script(1) half of the set is skipped silently — so that this
# does not slip through unnoticed before a commit, there is LAB_TESTS_STRICT=1: with it
# a missing tool fails the test instead of skipping it.

bats_require_minimum_version 1.5.0

setup() {
	load helpers

	CX="$BATS_TEST_DIRNAME/../fish/cx.fish"
	STUB_DIR="$BATS_TEST_DIRNAME/stubs"
	# fish is looked up before PATH is shadowed and is called by its full path: in the
	# cut-down PATH (the "mosh is not installed" test) it could not be found otherwise
	need_tool fish
	FISH=$(command -v fish)
	PATH="$STUB_DIR:$PATH"
	export PATH
	STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	export STUB_LOG
	# The host is pinned here so the expected strings do not depend on whichever
	# default the function happens to carry; that default gets its own test below.
	CX_HOST=bastion-host
	export CX_HOST
	# the developer's own choice of transport must not leak into the expected commands
	unset CX_TRANSPORT
}

# run a piece of fish on top of a loaded cx
cx_fish() {
	"$FISH" --no-config --command "source '$CX'; $*"
}

# the same, but with a real terminal on both ends
cx_tty() {
	tty_run "$FISH" --no-config --command "source '$CX'; $*"
}

# Run the assembled string through a real shell: the remote side will split it exactly
# the same way, and printf shows where the argument boundaries are. The `lab-host` name
# is dropped because what is checked here is the quoting of the arguments, not looking
# the command up in PATH.
#
# There are two shells. sh — because the quoting is meant to be POSIX-portable. zsh —
# because on the bastion ssh lands in exactly that shell (see the README on `~/.zshenv`),
# and zsh has its own extensions on top of POSIX: with `sh -c` alone a word starting with
# `=` sailed right past the tests (the zsh EQUALS option). A disagreement between the two
# shells is a bug, so it fails the test instead of going unnoticed.
split_remote() {
	local line="${1#lab-host }" out_sh out_zsh
	out_sh=$(sh -c "printf '[%s]' $line") || return $?
	if command -v zsh >/dev/null 2>&1; then
		out_zsh=$(zsh -c "printf '[%s]' $line") || return $?
		if [ "$out_sh" != "$out_zsh" ]; then
			printf 'sh and zsh disagree: sh=%s zsh=%s\n' "$out_sh" "$out_zsh" >&2
			return 1
		fi
	elif [ -n "${LAB_TESTS_STRICT:-}" ]; then
		# the same strictness as need_tool has, but without a skip: without zsh the
		# check through sh still checks something, so there is no point in skipping
		# the whole test
		printf 'required tool not found: zsh\n' >&2
		return 1
	fi
	printf '%s' "$out_sh"
}

# a PATH with no mosh in it — neither the real one nor a stub: a copy of the ssh stub
# plus the system directories (the stub needs dirname). The real mosh lives in
# /opt/homebrew/bin and does not make it in here.
nomosh_path() {
	mkdir -p "$BATS_TEST_TMPDIR/nomosh"
	cp "$STUB_DIR/_stub.sh" "$STUB_DIR/ssh" "$BATS_TEST_TMPDIR/nomosh/"
	printf '%s' "$BATS_TEST_TMPDIR/nomosh:/usr/bin:/bin"
}

@test "cx.fish is valid fish syntax" {
	# the only linter available: shellcheck does not understand fish
	run "$FISH" -n "$CX"
	[ "$status" -eq 0 ]
}

@test "sourcing cx.fish defines cx" {
	run cx_fish 'functions -q cx'
	[ "$status" -eq 0 ]
}

@test "--help exits 0 and touches neither mosh nor ssh" {
	run --separate-stderr cx_fish 'cx --help' </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"cx run <agent> <text>"* ]]
	# the list of one-shot commands in the help comes from the same variable that
	# the transport choice is made from
	[[ "$output" == *"(run, ls, kill, --help, -h)"* ]]
	[ -z "$stderr" ]
	[ -z "$(stub_log)" ]
}

@test "every command in \$__cx_oneshot really goes over ssh" {
	# The test walks the list itself instead of a copy of it: a command added to the
	# list must go over ssh, otherwise it silently leaves over mosh — with no exit code
	# and with a painted screen instead of stdout. Through `--` so that `--help` and
	# `-h`, which bare are intercepted locally, are checked the same way.
	need_tool script
	run cx_fish 'printf "%s\n" $__cx_oneshot' </dev/null
	[ "$status" -eq 0 ]
	[ -n "$output" ]

	cx_cmds="$output"
	for cx_cmd in $cx_cmds; do
		stub_reset
		run cx_tty "cx -- $cx_cmd"
		[ "$status" -eq 0 ]
		[[ "$(stub_log)" == "ssh bastion-host "* ]]
		[[ "$(stub_log)" != *mosh* ]]
	done
}

@test "-h is the short form of --help" {
	run cx_fish 'cx -h' </dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage:"* ]]
}

@test "without a tty the command goes over ssh, without -t" {
	run cx_fish 'cx ls' </dev/null
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host ls'" ]
}

@test "no arguments means bare lab-host, the session menu" {
	run cx_fish 'cx' </dev/null
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host lab-host" ]
}

@test "the exit code of the remote side is the exit code of cx" {
	STUB_RC=4 run cx_fish 'cx ls' </dev/null
	[ "$status" -eq 4 ]
}

@test "with a tty the session goes over mosh" {
	need_tool script
	run cx_tty 'cx omp'
	[ "$status" -eq 0 ]
	# the arguments leave as a list: the mosh wrapper quotes them itself
	[ "$(stub_log)" = "mosh bastion-host -- lab-host omp" ]
}

@test "a tty on one end only is not enough for mosh" {
	# a mosh client without a terminal does not start at all, and lab-host decides by
	# the TTY whether to give `docker exec -it`. The terminal here is real, stdout is
	# a file.
	need_tool script
	run tty_run sh -c \
		"$(printf '%q ' "$FISH" --no-config --command "source '$CX'; cx omp") > $(printf '%q' "$BATS_TEST_TMPDIR/out")"
	[ "$(stub_log)" = "ssh bastion-host 'lab-host omp'" ]
}

@test "mosh gets the arguments as a list, spaces intact" {
	need_tool script
	run cx_tty "cx attach 'two words'"
	# the quotes in the stub log mean the argument arrived as a single word
	[ "$(stub_log)" = "mosh bastion-host -- lab-host attach 'two words'" ]
}

@test "a normal exit from mosh does not re-attach over ssh" {
	need_tool script
	run cx_tty 'cx omp'
	[ "$status" -eq 0 ]
	[[ "$(stub_log)" != *ssh* ]]
}

@test "a failing mosh client falls back to ssh -t" {
	need_tool script
	STUB_RC=5 run cx_tty 'cx omp'
	# the exit code comes from ssh, the one the fallback went to, not from mosh
	[ "$status" -eq 5 ]
	[ "$(stub_log)" = "mosh bastion-host -- lab-host omp
ssh bastion-host -t 'lab-host omp'" ]
	# the message and the session output share one pty, so this looks for a substring
	[[ "$output" == *"mosh exited 5"* ]]
	[[ "$output" == *"falling back to ssh"* ]]
}

@test "without mosh installed the session goes over ssh -t" {
	need_tool script
	cx_path=$(nomosh_path)
	! PATH="$cx_path" command -v mosh >/dev/null || skip "mosh is still reachable"
	run tty_run env PATH="$cx_path" "$FISH" --no-config --command "source '$CX'; cx omp"
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host -t 'lab-host omp'" ]
}

@test "one-shot run never goes over mosh, even with a tty" {
	need_tool script
	# mosh paints a screen instead of clean stdout and loses the exit code, while
	# `run` is the replacement for the old per-agent wrappers, pipes and scripts included
	run cx_tty 'cx run pi 2+2'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host run pi 2+2'" ]
}

@test "ls and kill go over ssh too, so their exit code survives" {
	# mosh does not forward the exit code of the remote command at all and returns 0 on
	# a clean exit: `cx kill nope` through it would return 0 for a session that does not
	# exist, and `cx ls` would get a full-screen redraw for the sake of a single line
	need_tool script
	STUB_RC=1 run cx_tty 'cx kill nope'
	[ "$status" -eq 1 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host kill nope'" ]

	stub_reset
	run cx_tty 'cx ls'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host ls'" ]
}

@test "a failing kill is not retried over ssh after mosh" {
	# retrying a non-idempotent command: if the kill already went through and it was
	# the transport that died, the second pass answers "no such session" and turns
	# a success into an error
	need_tool script
	STUB_RC=5 run cx_tty 'cx kill test'
	[ "$(stub_log)" = "ssh bastion-host 'lab-host kill test'" ]
	[[ "$(stub_log)" != *mosh* ]]
}

@test "CX_HOST picks another bastion" {
	CX_HOST=other-bastion run cx_fish 'cx ls' </dev/null
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh other-bastion 'lab-host ls'" ]
}

@test "an empty CX_HOST does not become an empty host name" {
	# An empty variable does not count as a value: the built-in default has to win.
	# Which name that is stays cx's own business, but a name there must be — an empty
	# one would leave ssh with no host and a message nobody can read.
	CX_HOST= run cx_fish 'cx ls' </dev/null
	[ "$status" -eq 0 ]
	cx_re="^ssh [^[:space:]]+ 'lab-host ls'$"
	[[ "$(stub_log)" =~ $cx_re ]]
}

@test "-- reaches the help of lab itself instead of the local one" {
	# `--` must not get lost along the way: without it lab-host would eat --help itself
	run cx_fish 'cx -- --help' </dev/null
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host -- --help'" ]
}

@test "a one-shot behind -- still goes over ssh, with -- intact" {
	# regression: the rule "one-shot commands go over ssh" looked at the first word
	# only, so everything behind the `--` loophole left over mosh — with a painted
	# screen instead of clean stdout and with the exit code lost
	need_tool script
	STUB_RC=1 run cx_tty 'cx -- kill nope'
	[ "$status" -eq 1 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host -- kill nope'" ]

	stub_reset
	run cx_tty 'cx -- run pi 2+2'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host -- run pi 2+2'" ]

	stub_reset
	run cx_tty 'cx -- ls'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host -- ls'" ]

	stub_reset
	run cx_tty 'cx -- --help'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host -- --help'" ]
}

@test "a kill behind -- is not retried over ssh after mosh either" {
	# the same non-idempotence as with a bare `cx kill`: over mosh the command went
	# first, and when the client died the fallback repeated a kill that had already
	# happened
	need_tool script
	STUB_RC=5 run cx_tty 'cx -- kill test'
	[ "$(stub_log)" = "ssh bastion-host 'lab-host -- kill test'" ]
	[[ "$(stub_log)" != *mosh* ]]
}

@test "a session behind -- still goes over mosh" {
	# `--` is stripped only for the transport choice: a session behind it stays a session
	need_tool script
	run cx_tty 'cx -- attach work'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "mosh bastion-host -- lab-host -- attach work" ]
}

@test "an argument with spaces survives the remote shell as one word" {
	run cx_fish "__cx_remote run omp 'text with spaces'"
	[ "$status" -eq 0 ]
	run split_remote "$output"
	[ "$status" -eq 0 ]
	[ "$output" = "[run][omp][text with spaces]" ]
}

@test "a quote inside an argument survives the remote shell" {
	run cx_fish "__cx_remote run pi \"it's\""
	[ "$status" -eq 0 ]
	[ "$output" = "lab-host run pi 'it'\\''s'" ]
	run split_remote "$output"
	[ "$output" = "[run][pi][it's]" ]
}

@test "an empty argument stays an argument" {
	run cx_fish "__cx_remote run pi ''"
	[ "$status" -eq 0 ]
	[ "$output" = "lab-host run pi ''" ]
	run split_remote "$output"
	[ "$output" = "[run][pi][]" ]
}

@test "a multiline argument stays one argument" {
	run cx_fish '__cx_remote run pi (printf "a\nb" | string collect)'
	[ "$status" -eq 0 ]
	run split_remote "$output"
	[ "$output" = "[run][pi][a
b]" ]
}

@test "an argument ending in a newline cannot smuggle a second command" {
	# a PCRE `$` also matches before the final newline, so "foo\n" passed as "needs no
	# quoting" and left raw: the remote shell saw `lab-host attach foo`, and then `bar`
	# as a separate command
	run cx_fish '__cx_remote attach (printf "foo\n" | string collect -N) bar'
	[ "$status" -eq 0 ]
	# one line, three words: the newline is gone and no second command appeared
	[ "${#lines[@]}" -eq 1 ]
	[ "$output" = "lab-host attach foo bar" ]
	run split_remote "$output"
	[ "$output" = "[attach][foo][bar]" ]
}

@test "an argument of nothing but newlines does not duplicate the command" {
	# command substitution in fish tore such an argument into two elements, and the
	# remote shell got one and the same command twice
	run cx_fish '__cx_remote run pi (printf "\n" | string collect -N)'
	[ "$status" -eq 0 ]
	[ "${#lines[@]}" -eq 1 ]
	[ "$output" = "lab-host run pi ''" ]
}

@test "a plain argument is not quoted, so the command stays readable" {
	run cx_fish '__cx_remote run pi 2+2'
	[ "$status" -eq 0 ]
	[ "$output" = "lab-host run pi 2+2" ]
	run split_remote "$output"
	[ "$status" -eq 0 ]
	[ "$output" = "[run][pi][2+2]" ]
}

@test "an argument starting with = is quoted, or zsh expands it" {
	# The remote shell on the bastion is zsh, and it has EQUALS on by default: a word
	# starting with `=` is replaced by the path to the command of that name. Raw, `=ls`
	# arrived as `/bin/ls`, while `=hello` brought the whole command line down
	# ("zsh: hello not found", rc=1) — lab-host was never called at all. This hits
	# `cx run`: one-shot commands always go over ssh, whereas mosh quotes on its own.
	run cx_fish '__cx_remote run pi =hello'
	[ "$status" -eq 0 ]
	[ "$output" = "lab-host run pi '=hello'" ]
	run split_remote "$output"
	[ "$status" -eq 0 ]
	[ "$output" = "[run][pi][=hello]" ]
}

@test "= inside a word still needs no quoting" {
	# Only `lab-host` stands in the command position, so it will not become the
	# assignment `LANG=C` in any shell, and EQUALS looks at the first character of
	# a word only
	run cx_fish '__cx_remote run pi LANG=C'
	[ "$status" -eq 0 ]
	[ "$output" = "lab-host run pi LANG=C" ]
	run split_remote "$output"
	[ "$status" -eq 0 ]
	[ "$output" = "[run][pi][LANG=C]" ]
}

@test "CX_TRANSPORT=tssh carries a session over tssh --udp, the command as one string" {
	# tssh takes options from anywhere on its command line, so the remote command has to
	# be one string — the same one ssh gets, quoting included
	need_tool script
	CX_TRANSPORT=tssh run cx_tty "cx attach 'two words'"
	[ "$status" -eq 0 ]
	# the stub wraps an argument with spaces in quotes without escaping the inner ones
	[ "$(stub_log)" = "tssh --udp -t bastion-host 'lab-host attach 'two words''" ]
}

@test "a lab-host verdict over tssh is passed through, not retried over ssh" {
	# tssh, unlike mosh, carries the remote exit code: 3 is "no container", and asking
	# again over ssh would only print the same error twice
	need_tool script
	CX_TRANSPORT=tssh STUB_RC=3 run cx_tty 'cx omp'
	[ "$status" -eq 3 ]
	[ "$(stub_log)" = "tssh --udp -t bastion-host 'lab-host omp'" ]
}

@test "a failing tssh client falls back to ssh -t" {
	# 16 is what tssh returns when it cannot log in or cannot start tsshd
	need_tool script
	STUB_RCS=16:0 CX_TRANSPORT=tssh run cx_tty 'cx omp'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tssh --udp -t bastion-host 'lab-host omp'
ssh bastion-host -t 'lab-host omp'" ]
	[[ "$output" == *"tssh exited 16, falling back to ssh"* ]]
}

@test "one-shot commands stay on ssh with CX_TRANSPORT=tssh" {
	need_tool script
	CX_TRANSPORT=tssh run cx_tty 'cx ls'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host 'lab-host ls'" ]
}

@test "CX_TRANSPORT=ssh skips mosh even with a tty" {
	need_tool script
	CX_TRANSPORT=ssh run cx_tty 'cx omp'
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "ssh bastion-host -t 'lab-host omp'" ]
}

@test "an unknown CX_TRANSPORT exits 2 and connects nowhere" {
	CX_TRANSPORT=telnet run --separate-stderr cx_fish 'cx omp' </dev/null
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown CX_TRANSPORT 'telnet'"* ]]
	[ -z "$(stub_log)" ]
}
