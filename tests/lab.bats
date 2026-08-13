#!/usr/bin/env bats
#
# Tests for `lab`: parsing the grammar, validating session names, exit codes and
# LAB_DRY_RUN. The real tmux is never called — the stubs from tests/stubs come first
# in PATH.
#
# LAB_SH picks the interpreter: by default the script runs through its shebang
# (`/bin/sh`, which on macOS is bash in POSIX mode), while inside the container dash
# executes it. A second pass, `LAB_SH=/bin/dash bats tests`, runs the same set on the
# interpreter that actually does the work.

bats_require_minimum_version 1.5.0

setup() {
	load helpers

	LAB="$BATS_TEST_DIRNAME/../bin/lab"
	# an array, not a string: only this way does the call survive both `run` and script(1)
	LAB_CMD=("$LAB")
	if [ -n "${LAB_SH:-}" ]; then
		LAB_CMD=("$LAB_SH" "$LAB")
	fi

	# PATH before the substitution: it is how the real tmux is found for the
	# integration check
	REAL_PATH="$PATH"
	PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
	export PATH
	STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	export STUB_LOG
	# the developer's environment must not leak into the tests: the expected commands
	# depend on LAB_PI_MODEL, LAB_WORKDIR and LAB_AGENTS
	unset LAB_PI_MODEL LAB_WORKDIR LAB_DRY_RUN LAB_AGENTS
}

teardown() {
	# A single test brings up a real tmux server; were it to die halfway through, the
	# server would stay alive holding the test's streams open, and bats would wait for
	# EOF until the timeout. LAB_TEST_TMUX is set by the test itself and is visible
	# here: bats keeps setup, the body and teardown in one process.
	if [ -n "${LAB_TEST_TMUX:-}" ]; then
		TMUX_TMPDIR="$BATS_TEST_TMPDIR" "$LAB_TEST_TMUX" kill-server >/dev/null 2>&1 || true
	fi
}

@test "lab is executable" {
	[ -x "$LAB" ]
}

@test "--help exits 0 and prints the grammar" {
	run --separate-stderr "${LAB_CMD[@]}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"lab attach <name>"* ]]
	[[ "$output" == *"lab run <agent> <text>"* ]]
	[[ "$output" == *"LAB_WORKDIR"* ]]
	# the agent list in the help is assembled from $LAB_AGENTS, there is no second copy
	[[ "$output" == *"lab claude|codex|omp"* ]]
	# the rule about a leading dash is enforced by check_name, so the help is obliged
	# to mention it
	[[ "$output" == *'never starting with "-"'* ]]
	# the contract of `run`: the exit code is somebody else's, and the help says so
	[[ "$output" == *"returns the agent's own code"* ]]
	[ -z "$stderr" ]
	[ -z "$(stub_log)" ]
}

@test "-h is the short form of --help" {
	run "${LAB_CMD[@]}" -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage:"* ]]
}

@test "unknown subcommand exits 2 and says so on stderr" {
	run --separate-stderr "${LAB_CMD[@]}" frobnicate
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ "$stderr" == *"unknown command: frobnicate"* ]]
	[ -z "$(stub_log)" ]
}

@test "a glob is not a command and not an agent" {
	# the agent list is compared by pattern matching inside a case: without quotes in
	# the pattern, `*` would match any of them and would travel on to tmux as a
	# session name
	run --separate-stderr "${LAB_CMD[@]}" '*'
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown command: *"* ]]

	run --separate-stderr "${LAB_CMD[@]}" run '*' hi
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown agent: '*'"* ]]
	[ -z "$(stub_log)" ]
}

@test "two agent names in one word are not an agent" {
	# regression: the check looked for a substring in " claude codex omp ", and gluing
	# neighbouring elements together passed for a known agent. `lab 'claude codex'`
	# opened a session with a space in its name, right past check_name, while
	# `lab run 'codex omp'` made it all the way to exec and died with a raw "not found"
	# and code 127 instead of a clear code 2
	for lab_pair in 'claude codex' 'codex omp' 'claude codex omp'; do
		run --separate-stderr "${LAB_CMD[@]}" "$lab_pair"
		[ "$status" -eq 2 ]
		[[ "$stderr" == *"unknown command: $lab_pair"* ]]

		run --separate-stderr "${LAB_CMD[@]}" run "$lab_pair" hi
		[ "$status" -eq 2 ]
		[[ "$stderr" == *"unknown agent: '$lab_pair'"* ]]
	done
	[ -z "$(stub_log)" ]
}

@test "an agent name with a stray space is not an agent" {
	run --separate-stderr "${LAB_CMD[@]}" run ' omp' hi
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown agent: ' omp'"* ]]

	run --separate-stderr "${LAB_CMD[@]}" 'omp '
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown command: omp "* ]]
	[ -z "$(stub_log)" ]
}

@test "unknown option exits 2" {
	run --separate-stderr "${LAB_CMD[@]}" --wat
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown option: --wat"* ]]
}

@test "an explicitly empty command exits 2 instead of opening the menu" {
	# `lab ""` arrives from `cx ""`; without remembering the number of arguments
	# before the shift it is indistinguishable from a bare `lab`, and instead of an
	# error it used to open the menu
	run --separate-stderr "${LAB_CMD[@]}" ""
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"empty command"* ]]
	[ -z "$(stub_log)" ]
}

@test "session name with a dot exits 2" {
	run --separate-stderr "${LAB_CMD[@]}" attach my.session
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"bad session name: 'my.session'"* ]]
	[ -z "$(stub_log)" ]
}

@test "session name with a space exits 2" {
	run --separate-stderr "${LAB_CMD[@]}" attach "my session"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"bad session name: 'my session'"* ]]
	[ -z "$(stub_log)" ]
}

@test "session name with a slash or colon exits 2" {
	run "${LAB_CMD[@]}" attach foo/bar
	[ "$status" -eq 2 ]

	run "${LAB_CMD[@]}" attach foo:bar
	[ "$status" -eq 2 ]
}

@test "a session name starting with a dash exits 2, it would be a tmux option" {
	# tmux would read `new -As -A` as an option of its own and open a session named `-A`
	run --separate-stderr "${LAB_CMD[@]}" attach -A
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"must not start with -"* ]]
	[ -z "$(stub_log)" ]

	run --separate-stderr "${LAB_CMD[@]}" kill --help
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"must not start with -"* ]]
	[ -z "$(stub_log)" ]
}

@test "empty session name exits 2" {
	run --separate-stderr "${LAB_CMD[@]}" attach ""
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"empty session name"* ]]
}

@test "letters, digits, underscore and dash are valid names" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" attach a-b_C9
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As a-b_C9 -c /workspace" ]
}

@test "attach without a name exits 2" {
	run --separate-stderr "${LAB_CMD[@]}" attach
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"attach needs exactly one session name"* ]]
}

@test "attach with extra arguments exits 2" {
	run "${LAB_CMD[@]}" attach one two
	[ "$status" -eq 2 ]
}

@test "LAB_DRY_RUN prints the tmux command instead of running it" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" attach foo
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As foo -c /workspace" ]
	[ -z "$(stub_log)" ]
}

@test "without LAB_DRY_RUN attach really calls tmux" {
	run "${LAB_CMD[@]}" attach foo
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux new -As foo -c /workspace" ]
}

@test "LAB_WORKDIR moves the session directory" {
	# in the tests and while debugging outside the container /workspace does not exist
	LAB_WORKDIR=/tmp LAB_DRY_RUN=1 run "${LAB_CMD[@]}" attach foo
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As foo -c /tmp" ]

	LAB_WORKDIR=/tmp LAB_DRY_RUN=1 run "${LAB_CMD[@]}" omp
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As omp -c /tmp omp" ]
}

@test "ls takes no arguments" {
	run --separate-stderr "${LAB_CMD[@]}" ls extra
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"ls takes no arguments"* ]]
}

@test "kill needs exactly one valid name" {
	run "${LAB_CMD[@]}" kill
	[ "$status" -eq 2 ]

	run "${LAB_CMD[@]}" kill one two
	[ "$status" -eq 2 ]

	run --separate-stderr "${LAB_CMD[@]}" kill bad.name
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"bad session name"* ]]
}

@test "ls asks tmux for the whole format, not just the name" {
	STUB_OUT=$'main: 1 windows\nomp: 2 windows (attached)' \
		run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "main: 1 windows" ]
	[ "${lines[1]}" = "omp: 2 windows (attached)" ]
	[ -z "$stderr" ]
	[ "$(stub_log)" = "tmux list-sessions -F '#{session_name}: #{session_windows} windows#{?session_attached, (attached),}'" ]
}

@test "a tmux warning on a successful list is not a session" {
	# stdout and stderr must not be merged into one variable: a tmux warning would
	# become an extra line in `lab ls` and an extra number in the menu
	STUB_OUT="main: 1 windows" STUB_ERR="some tmux warning" \
		run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[ "$output" = "main: 1 windows" ]
	[[ "$output" != *"some tmux warning"* ]]
}

@test "tmux exiting 0 with no sessions at all still says 'no sessions'" {
	STUB_RC=0 run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"no sessions"* ]]
}

@test "ls without a tmux server says 'no sessions', not the raw tmux error" {
	STUB_RC=1 STUB_ERR="no server running on /tmp/tmux-1000/default" \
		run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[[ "$stderr" == *"no sessions"* ]]
	[[ "$stderr" != *"no server running"* ]]
}

@test "the 'no sessions' wording of tmux is recognised too" {
	STUB_RC=1 STUB_ERR="no sessions" run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"lab: no sessions"* ]]
}

@test "a missing socket is 'no sessions', a broken one is an error" {
	# tmux prints "error connecting to …" both for a socket that is not there (no
	# sessions) and for one that is alive but unreachable (that is real trouble) —
	# only the reason in the brackets tells them apart
	STUB_RC=1 STUB_ERR="error connecting to /tmp/tmux-1000/default (No such file or directory)" \
		run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"lab: no sessions"* ]]

	STUB_RC=1 STUB_ERR="error connecting to /tmp/tmux-1000/default (Permission denied)" \
		run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"Permission denied"* ]]
}

@test "ls forwards an unexpected tmux error and exits 1" {
	STUB_RC=1 STUB_ERR="lost server" run --separate-stderr "${LAB_CMD[@]}" ls
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[[ "$stderr" == *"lost server"* ]]
}

@test "kill checks the session exists, then kills it — by exact name" {
	# the `=` is mandatory: without it tmux resolves the target by prefix, and
	# `kill wor` silently kills `work`
	run "${LAB_CMD[@]}" kill foo
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux has-session -t =foo
tmux kill-session -t =foo" ]
}

@test "kill really kills only the exact session, not a prefix match" {
	# The only check against a real tmux: the stub knows nothing about resolving
	# targets, and resolving is exactly what is checked here. The server comes up on
	# its own TMUX_TMPDIR, so the developer's other sessions are neither visible nor
	# harmed.
	need_tool tmux
	LAB_TEST_TMUX=$(PATH="$REAL_PATH" command -v tmux)
	export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
	unset TMUX
	# the server is handed empty streams: a daemon inherits them from its client, and
	# a live server on the test's stdout would make bats wait for EOF until the timeout
	"$LAB_TEST_TMUX" new -d -s foobar >/dev/null 2>&1 </dev/null

	run env PATH="$REAL_PATH" TMUX_TMPDIR="$BATS_TEST_TMPDIR" "${LAB_CMD[@]}" kill foo
	[ "$status" -eq 1 ]
	[[ "$output" == *"no such session: foo"* ]]

	run "$LAB_TEST_TMUX" has-session -t =foobar
	[ "$status" -eq 0 ]

	run env PATH="$REAL_PATH" TMUX_TMPDIR="$BATS_TEST_TMPDIR" "${LAB_CMD[@]}" kill foobar
	[ "$status" -eq 0 ]
	run "$LAB_TEST_TMUX" has-session -t =foobar
	[ "$status" -ne 0 ]
}

@test "kill of a missing session exits 1 and never calls kill-session" {
	STUB_RC=1 run --separate-stderr "${LAB_CMD[@]}" kill foo
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"no such session: foo"* ]]
	[ "$(stub_log)" = "tmux has-session -t =foo" ]
}

@test "a kill-session that fails after a successful has-session is not swallowed" {
	# different codes for different calls: has-session worked, kill-session did not
	STUB_RCS=0:1 run "${LAB_CMD[@]}" kill foo
	[ "$status" -eq 1 ]
	[ "$(stub_log)" = "tmux has-session -t =foo
tmux kill-session -t =foo" ]
}

@test "LAB_DRY_RUN kill prints the command and calls nothing" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" kill foo
	[ "$status" -eq 0 ]
	[ "$output" = "tmux kill-session -t =foo" ]
	[ -z "$(stub_log)" ]
}

@test "bare lab without sessions starts main" {
	STUB_RC=1 STUB_ERR="no server running on /tmp/tmux-1000/default" LAB_DRY_RUN=1 \
		run --separate-stderr "${LAB_CMD[@]}"
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As main -c /workspace" ]
	[[ "$stderr" == *"no sessions, starting main"* ]]
}

@test "bare lab numbers the sessions and attaches the picked one" {
	STUB_OUT=$'main\nomp' LAB_DRY_RUN=1 \
		run --separate-stderr "${LAB_CMD[@]}" <<<"2"
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As omp -c /workspace" ]
	[[ "$stderr" == *"1) main"* ]]
	[[ "$stderr" == *"2) omp"* ]]
	[[ "$stderr" == *"pick a session number"* ]]
	[ "$(stub_log)" = "tmux list-sessions -F #{session_name}" ]
}

@test "picking from the menu really attaches" {
	STUB_OUT=$'main\nomp' run "${LAB_CMD[@]}" <<<"1"
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux list-sessions -F #{session_name}
tmux new -As main -c /workspace" ]
}

@test "the menu attaches a session whose name lab itself would reject" {
	# the name came from tmux, and tmux allows spaces: the menu is obliged to open
	# everything it showed, otherwise such a session is unreachable through lab at all
	STUB_OUT=$'main\nmy proj' LAB_DRY_RUN=1 \
		run --separate-stderr "${LAB_CMD[@]}" <<<"2"
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As 'my proj' -c /workspace" ]
	[[ "$stderr" == *"2) my proj"* ]]
}

@test "empty input cancels the menu" {
	STUB_OUT=$'main\nomp' run "${LAB_CMD[@]}" <<<""
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux list-sessions -F #{session_name}" ]
}

@test "closed stdin cancels the menu" {
	STUB_OUT=$'main\nomp' run "${LAB_CMD[@]}" </dev/null
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux list-sessions -F #{session_name}" ]
}

@test "a non-numeric pick exits 2" {
	STUB_OUT=$'main\nomp' run --separate-stderr "${LAB_CMD[@]}" <<<"abc"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"not a session number: 'abc'"* ]]
}

@test "the menu picks are bounded on both ends" {
	STUB_OUT=$'main\nomp' run --separate-stderr "${LAB_CMD[@]}" <<<"0"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"no session number 0"* ]]

	STUB_OUT=$'main\nomp' run --separate-stderr "${LAB_CMD[@]}" <<<"3"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"no session number 3"* ]]

	STUB_OUT=$'main\nomp' LAB_DRY_RUN=1 run --separate-stderr "${LAB_CMD[@]}" <<<"2"
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As omp -c /workspace" ]
}

@test "an overlong digit string is refused, not passed to the shell arithmetic" {
	# dash answers such a thing with "Illegal number" and falls through every branch:
	# the user used to get four raw shell errors and an "empty session name"
	STUB_OUT=$'main\nomp' run --separate-stderr "${LAB_CMD[@]}" <<<"99999999999999999999"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"no session number 99999999999999999999"* ]]
	[[ "$stderr" != *"Illegal number"* ]]
	[[ "$stderr" != *"empty session name"* ]]
}

@test "the menu survives an unexpected tmux error with code 1" {
	STUB_RC=1 STUB_ERR="lost server" run --separate-stderr "${LAB_CMD[@]}" </dev/null
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"lost server"* ]]
}

@test "run needs an agent and a request" {
	run --separate-stderr "${LAB_CMD[@]}" run
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"run needs an agent and a request"* ]]

	# a known agent on purpose: the arity check has to be the only reason for the 2,
	# not the agent name
	run --separate-stderr "${LAB_CMD[@]}" run omp
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"run needs an agent and a request"* ]]
}

@test "agent presets take no arguments" {
	for agent in claude codex omp; do
		run --separate-stderr "${LAB_CMD[@]}" "$agent" extra
		[ "$status" -eq 2 ]
		[[ "$stderr" == *"$agent takes no arguments"* ]]
	done
}

@test "omp preset opens a session named omp with omp inside" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" omp
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As omp -c /workspace omp" ]
}

@test "claude preset opens a session named claude" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" claude
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As claude -c /workspace claude" ]
}

@test "codex preset opens a session named codex" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" codex
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As codex -c /workspace codex" ]
}

@test "LAB_AGENTS is overridable from the environment" {
	# The agent list is one variable and nothing else: a lab in another container may
	# carry a different set of tools, and the help, the presets and the `run` check all
	# have to follow it. A name outside the list stays unknown — including the ones the
	# default list has.
	LAB_AGENTS='parrot toucan' run "${LAB_CMD[@]}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"lab parrot|toucan"* ]]

	LAB_AGENTS='parrot' LAB_DRY_RUN=1 run "${LAB_CMD[@]}" parrot
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As parrot -c /workspace parrot" ]

	LAB_AGENTS='parrot' LAB_DRY_RUN=1 run "${LAB_CMD[@]}" run parrot hi
	[ "$status" -eq 0 ]
	[ "$output" = "parrot -p hi" ]

	LAB_AGENTS='parrot' run --separate-stderr "${LAB_CMD[@]}" run omp hi
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown agent: 'omp'"* ]]
	[[ "$stderr" == *"known: parrot"* ]]

	LAB_AGENTS='parrot' run --separate-stderr "${LAB_CMD[@]}" omp
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown command: omp"* ]]
	[ -z "$(stub_log)" ]
}

# pi is not in the default agent list any more, so the cases below put it there
# themselves: the preset still exists and its shape is still pinned here.
@test "pi preset takes the model from LAB_PI_MODEL" {
	LAB_AGENTS='pi' LAB_DRY_RUN=1 LAB_PI_MODEL=some-model:latest run "${LAB_CMD[@]}" pi
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As pi -c /workspace pi --provider ollama --model some-model:latest" ]
}

@test "without LAB_PI_MODEL pi keeps the provider and invents no model" {
	# the provider is fixed — inside the container pi only ever goes to the local
	# Ollama; without LAB_PI_MODEL the model comes from pi's own ~/.pi/agent/models.json
	LAB_AGENTS='pi' LAB_DRY_RUN=1 run "${LAB_CMD[@]}" pi
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As pi -c /workspace pi --provider ollama" ]
}

@test "omp gets no model even when LAB_PI_MODEL is set" {
	LAB_DRY_RUN=1 LAB_PI_MODEL=some-model:latest run "${LAB_CMD[@]}" omp
	[ "$status" -eq 0 ]
	[ "$output" = "tmux new -As omp -c /workspace omp" ]
}

@test "a preset really calls tmux" {
	LAB_AGENTS='pi' LAB_PI_MODEL=some-model:latest run "${LAB_CMD[@]}" pi
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux new -As pi -c /workspace pi --provider ollama --model some-model:latest" ]
}

@test "run pi builds a one-shot call with the model" {
	LAB_AGENTS='pi' LAB_DRY_RUN=1 LAB_PI_MODEL=some-model:latest run "${LAB_CMD[@]}" run pi "2 + 2"
	[ "$status" -eq 0 ]
	[ "$output" = "pi --provider ollama --model some-model:latest -p '2 + 2'" ]
}

@test "run pi without LAB_PI_MODEL keeps pi's own model, not its own provider" {
	LAB_AGENTS='pi' LAB_DRY_RUN=1 run "${LAB_CMD[@]}" run pi "2 + 2"
	[ "$status" -eq 0 ]
	[ "$output" = "pi --provider ollama -p '2 + 2'" ]
}

@test "run omp and run claude go straight to the agent" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" run omp "2 + 2"
	[ "$status" -eq 0 ]
	[ "$output" = "omp -p '2 + 2'" ]

	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" run claude "2 + 2"
	[ "$status" -eq 0 ]
	[ "$output" = "claude -p '2 + 2'" ]

	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" run codex "2 + 2"
	[ "$status" -eq 0 ]
	[ "$output" = "codex -p '2 + 2'" ]
}

@test "run joins the request into a single prompt" {
	LAB_DRY_RUN=1 run "${LAB_CMD[@]}" run omp 2 + 2
	[ "$status" -eq 0 ]
	[ "$output" = "omp -p '2 + 2'" ]
}

@test "run calls the agent and never tmux" {
	LAB_WORKDIR="$BATS_TEST_TMPDIR" run "${LAB_CMD[@]}" run omp "2 + 2"
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "omp -p '2 + 2'" ]
}

@test "run passes the agent's exit code through, even when it collides with a host state" {
	# `run` hands the process over to the agent through exec, so it returns exactly the
	# agent's code — including 3 and 4, which for lab-host mean "no container" and
	# "docker unavailable". That is a deliberate contract: the replacement for the old
	# per-agent wrapper scripts must carry the agent's code through whole, while the
	# bastion announces its own trouble with a "lab: …" / "lab-host: …" line on stderr.
	# Both the code and the absence of such a line are checked — that line is what
	# tells them apart.
	for rc in 3 4 7; do
		stub_reset
		STUB_RC=$rc LAB_WORKDIR="$BATS_TEST_TMPDIR" \
			run --separate-stderr "${LAB_CMD[@]}" run omp hi
		[ "$status" -eq "$rc" ]
		[ "$(stub_log)" = "omp -p hi" ]
		[[ "$stderr" != *"lab: "* ]]
	done
}

@test "run with an unknown agent exits 2 and calls nothing" {
	run --separate-stderr "${LAB_CMD[@]}" run frobnicate "2 + 2"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown agent: 'frobnicate'"* ]]
	[[ "$stderr" == *"claude, codex, omp"* ]]
	[ -z "$(stub_log)" ]
}

@test "a subcommand name is not an agent" {
	run --separate-stderr "${LAB_CMD[@]}" run ls "2 + 2"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"unknown agent: 'ls'"* ]]
}

@test "run with an empty request exits 2" {
	run --separate-stderr "${LAB_CMD[@]}" run omp ""
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"empty request"* ]]
	[ -z "$(stub_log)" ]
}

@test "run reports a missing workdir instead of a raw shell error" {
	LAB_WORKDIR="$BATS_TEST_TMPDIR/nope" run --separate-stderr "${LAB_CMD[@]}" run omp hi
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"cannot enter"* ]]
	[[ "$stderr" != *"can't cd"* ]]
	[ -z "$(stub_log)" ]
}
