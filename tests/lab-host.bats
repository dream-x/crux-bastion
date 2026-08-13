#!/usr/bin/env bats
#
# Tests for `lab-host`: telling the docker states apart (daemon down, no such container,
# stopped, running), TTY detection, passing TERM and arguments through. The real docker
# is never called — the stubs from tests/stubs come first in PATH.
#
# LAB_SH picks the interpreter, same as in lab.bats: `LAB_SH=/bin/dash bats …` runs the
# same set on dash, where, unlike bash, an unset TERM is not filled in by the shell.

bats_require_minimum_version 1.5.0

setup() {
	load helpers

	LABHOST="$BATS_TEST_DIRNAME/../bin/lab-host"
	# an array, not a string: only this way does the call survive both `run` and script(1)
	LABHOST_CMD=("$LABHOST")
	if [ -n "${LAB_SH:-}" ]; then
		LABHOST_CMD=("$LAB_SH" "$LABHOST")
	fi

	PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
	export PATH
	STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	export STUB_LOG
	# The expected strings depend on TERM and on the container name, so both are
	# pinned here: the tests must not depend on the developer's terminal, nor on
	# whichever name the script happens to default to.
	TERM=screen-256color
	export TERM
	LAB_CONTAINER=agents
	export LAB_CONTAINER
	unset LAB_DRY_RUN
}

# the first command lab-host always runs on its own
INSPECT="docker inspect -f {{.State.Running}} agents"

@test "lab-host is executable" {
	[ -x "$LABHOST" ]
}

@test "--help exits 0 and never touches docker" {
	run --separate-stderr "${LABHOST_CMD[@]}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"lab-host [args...]"* ]]
	[ -z "$stderr" ]
	[ -z "$(stub_log)" ]
}

@test "-h is the short form of --help" {
	run "${LABHOST_CMD[@]}" -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"usage:"* ]]
}

@test "a running container gets the command through docker exec" {
	STUB_OUT=true run "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "$INSPECT
docker exec -i -e TERM=screen-256color agents lab ls" ]
}

@test "the exit code of the container command is the exit code of lab-host" {
	# `cx run` replaces the old per-agent wrapper scripts in pipes and scripts, so the
	# exit code has to travel all the way. Different codes for different calls: inspect
	# succeeded, the command itself returned 2
	STUB_OUT=true STUB_RCS=0:2 run "${LABHOST_CMD[@]}" run pi hi
	[ "$status" -eq 2 ]
	[ "$(stub_log)" = "$INSPECT
docker exec -i -e TERM=screen-256color agents lab run pi hi" ]

	# the call counter is shared by the whole run: the second pass would inherit it used up
	stub_reset
	STUB_OUT=true STUB_RCS=0:1 run "${LABHOST_CMD[@]}" kill nosuch
	[ "$status" -eq 1 ]
}

@test "a code that collides with a host state is passed through untouched" {
	# 3 and 4 are lab-host's own codes ("no container", "docker unavailable"), but
	# `run` is transparent: the agent may return them itself, and lab-host has no right
	# to replace them with its own meaning. The message is what tells them apart:
	# lab-host announces its own trouble with a "lab-host: …" line, someone else's
	# code arrives silently.
	STUB_OUT=true STUB_RCS=0:3 run --separate-stderr "${LABHOST_CMD[@]}" run pi hi
	[ "$status" -eq 3 ]
	[[ "$stderr" != *"lab-host:"* ]]
	[ "$(stub_log)" = "$INSPECT
docker exec -i -e TERM=screen-256color agents lab run pi hi" ]

	stub_reset
	STUB_OUT=true STUB_RCS=0:4 run --separate-stderr "${LABHOST_CMD[@]}" run pi hi
	[ "$status" -eq 4 ]
	[[ "$stderr" != *"lab-host:"* ]]
}

@test "a docker warning on a successful inspect does not break the chain" {
	# docker prints warnings (an outdated config.json, a credential helper, a context)
	# on a successful inspect too: merged with the state into one line they matched
	# neither true nor false — and a perfectly alive container was declared
	# "cannot tell whether … is running" with code 1
	STUB_OUT=true STUB_ERR="WARNING: Error loading config file: /Users/x/.docker/config.json" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[[ "$stderr" != *"cannot tell whether"* ]]
	[ "$(stub_log)" = "$INSPECT
docker exec -i -e TERM=screen-256color agents lab ls" ]
}

@test "a stopped container exits 3 and never runs the command" {
	STUB_OUT=false run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 3 ]
	[[ "$stderr" == *"is not running"* ]]
	[[ "$stderr" == *"docker start agents"* ]]
	[ "$(stub_log)" = "$INSPECT" ]
}

@test "a missing container exits 3, not 4 — the daemon is fine" {
	STUB_RC=1 STUB_ERR="Error: No such object: agents" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 3 ]
	[[ "$stderr" == *"no container named 'agents'"* ]]
	[ "$(stub_log)" = "$INSPECT" ]
}

# Exactly the message docker 29.7.1 prints for `docker inspect` of a container that does
# not exist: all lowercase and with an empty line in front of it (the -f template rendered
# to nothing). A `No such` pattern with a capital letter did not catch this branch, and on
# a live machine "there is no container" fell through into "unknown docker error" with
# code 1 instead of 3.
@test "a missing container is recognised in docker 29 lowercase wording" {
	STUB_RC=1 STUB_ERR="error: no such object: agents" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 3 ]
	[[ "$stderr" == *"no container named 'agents'"* ]]
	[[ "$stderr" == *"docker ps -a"* ]]
	[ "$(stub_log)" = "$INSPECT" ]
}

@test "the daemon-only wording 'No such container' also exits 3" {
	STUB_RC=1 STUB_ERR="Error response from daemon: No such container: agents" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 3 ]
	[[ "$stderr" == *"no container named 'agents'"* ]]
}

@test "an unreachable daemon exits 4 and says colima start" {
	STUB_RC=1 STUB_ERR="Cannot connect to the Docker daemon at unix:///Users/dev/.colima/default/docker.sock. Is the docker daemon running?" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"colima start"* ]]
	[[ "$stderr" != *"Cannot connect to the Docker daemon"* ]]
	[ "$(stub_log)" = "$INSPECT" ]
}

@test "the other daemon-down wordings also exit 4" {
	STUB_RC=1 STUB_ERR="error during connect: Get \"http://docker/v1.45/info\": EOF" \
		run "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 4 ]

	STUB_RC=1 STUB_ERR="dial unix /var/run/docker.sock: connect: no such file or directory" \
		run "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 4 ]
}

# The docker 29 message about a dead socket, taken from a live machine word for word.
# It contains "no such file or directory", which is why it also guards the order of the
# branches: a wide `no such` pattern would take a Colima that is down for a container
# that does not exist and would advise `docker ps -a` instead of `colima start`.
@test "docker 29 socket wording exits 4, not 3, despite saying 'no such file'" {
	STUB_RC=1 \
		STUB_ERR="failed to connect to the docker API at unix:///nonexistent/docker.sock; check if the path is correct and if the daemon is running: dial unix /nonexistent/docker.sock: connect: no such file or directory" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"colima start"* ]]
	[[ "$stderr" != *"docker ps -a"* ]]
}

@test "a refused tcp daemon exits 4" {
	STUB_RC=1 \
		STUB_ERR="failed to connect to the docker API at tcp://127.0.0.1:1: dial tcp 127.0.0.1:1: connect: connection refused" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"colima start"* ]]
}

@test "an unknown docker error is forwarded verbatim with code 1" {
	STUB_RC=1 STUB_ERR="permission denied while trying to connect" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"permission denied while trying to connect"* ]]
	[ "$(stub_log)" = "$INSPECT" ]
}

@test "an inspect answer that is neither true nor false exits 1" {
	STUB_OUT="<no value>" run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"cannot tell whether"* ]]
	[ "$(stub_log)" = "$INSPECT" ]
}

@test "a missing docker binary exits 4 instead of a shell error" {
	# PATH is cut down for the child only: bats itself would not survive even the mktemp
	# call inside `run` without its own PATH. The script is invoked through its shebang
	# even when LAB_SH is set — what is checked here is `command -v docker`, and that
	# does not depend on the dialect
	run --separate-stderr env PATH="$BATS_TEST_TMPDIR" "$LABHOST" ls
	[ "$status" -eq 4 ]
	[[ "$stderr" == *"docker not found in PATH"* ]]
	[ -z "$(stub_log)" ]
}

@test "without a tty docker gets -i, not -it" {
	STUB_OUT=true run "${LABHOST_CMD[@]}" ls </dev/null
	[ "$status" -eq 0 ]
	[[ "$(stub_log)" == *"docker exec -i -e"* ]]
	[[ "$(stub_log)" != *"docker exec -it"* ]]
}

@test "with a real tty docker gets -it" {
	need_tool script
	STUB_OUT=true run tty_run "${LABHOST_CMD[@]}" ls
	[ "$(stub_log)" = "$INSPECT
docker exec -it -e TERM=screen-256color agents lab ls" ]
}

@test "a tty on one end only is not enough for -it" {
	# mosh and ssh can hand over one end without the other, and `docker exec -it` with
	# a redirected stdout marks the output up with escape sequences and breaks the pipe.
	# The terminal here is real (script), while stdout is a file.
	need_tool script
	STUB_OUT=true run tty_run sh -c \
		"$(printf '%q ' "${LABHOST_CMD[@]}" ls) > $(printf '%q' "$BATS_TEST_TMPDIR/out")"
	[[ "$(stub_log)" == *"docker exec -i -e"* ]]
	[[ "$(stub_log)" != *"docker exec -it"* ]]
}

@test "TERM is passed through so tmux keeps its colors" {
	TERM=tmux-256color STUB_OUT=true run "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[[ "$(stub_log)" == *"-e TERM=tmux-256color"* ]]
}

@test "an empty TERM is not passed at all" {
	TERM= STUB_OUT=true run "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "$INSPECT
docker exec -i agents lab ls" ]
}

@test "a TERM that is unset entirely is not passed either" {
	# This branch cannot be checked through the shebang: /bin/sh on macOS is bash 3.2,
	# and an unset TERM it fills in by itself (dumb). Inside the container sh is dash,
	# which does not do that, so the check goes through dash directly.
	need_tool dash
	STUB_OUT=true run env -u TERM dash "$LABHOST" ls
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "$INSPECT
docker exec -i agents lab ls" ]
}

@test "LAB_CONTAINER renames the container everywhere" {
	LAB_CONTAINER=lab2 STUB_OUT=true run "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "docker inspect -f {{.State.Running}} lab2
docker exec -i -e TERM=screen-256color lab2 lab ls" ]

	# With no LAB_CONTAINER at all the name comes from the script's own default. Which
	# name that is stays the script's business, but a name there must be: an empty one
	# would make docker read the next word as the container.
	stub_reset
	STUB_OUT=true run env -u LAB_CONTAINER "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 0 ]
	lh_log=$(stub_log)
	[[ "${lh_log%%$'\n'*}" == "docker inspect -f {{.State.Running}} "?* ]]
}

@test "LAB_CONTAINER is named in the not-running message" {
	LAB_CONTAINER=lab2 STUB_OUT=false run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 3 ]
	[[ "$stderr" == *"'lab2'"* ]]
}

@test "arguments reach lab unchanged, spaces and all" {
	STUB_OUT=true run "${LABHOST_CMD[@]}" run pi "2 + 2"
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "$INSPECT
docker exec -i -e TERM=screen-256color agents lab run pi '2 + 2'" ]
}

@test "no arguments means bare lab, the session menu" {
	STUB_OUT=true run "${LABHOST_CMD[@]}"
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "$INSPECT
docker exec -i -e TERM=screen-256color agents lab" ]
}

@test "-- forwards everything, so lab's own help is reachable" {
	STUB_OUT=true run "${LABHOST_CMD[@]}" -- --help
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "$INSPECT
docker exec -i -e TERM=screen-256color agents lab --help" ]
}

@test "lab-host does not parse the lab grammar" {
	STUB_OUT=true run "${LABHOST_CMD[@]}" frobnicate
	[ "$status" -eq 0 ]
	[[ "$(stub_log)" == *"agents lab frobnicate" ]]
}

@test "LAB_DRY_RUN prints the docker command instead of running it" {
	LAB_DRY_RUN=1 STUB_OUT=true run "${LABHOST_CMD[@]}" run pi "2 + 2"
	[ "$status" -eq 0 ]
	[ "$output" = "docker exec -i -e TERM=screen-256color agents lab run pi '2 + 2'" ]
	[ "$(stub_log)" = "$INSPECT" ]
}

@test "LAB_DRY_RUN still reports a dead daemon" {
	LAB_DRY_RUN=1 STUB_RC=1 STUB_ERR="Cannot connect to the Docker daemon at unix:///x.sock" \
		run --separate-stderr "${LABHOST_CMD[@]}" ls
	[ "$status" -eq 4 ]
	[ -z "$output" ]
	[[ "$stderr" == *"colima start"* ]]
}
