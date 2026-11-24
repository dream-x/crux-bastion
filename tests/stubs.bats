#!/usr/bin/env bats
#
# Tests for the harness itself: the stubs have to record calls into $STUB_LOG
# honestly and return the exit code, stdout and stderr they were told to. If the
# stubs break, every other test starts lying silently — so they are checked apart.

bats_require_minimum_version 1.5.0

setup() {
	load helpers

	STUB_DIR="$BATS_TEST_DIRNAME/stubs"
	PATH="$STUB_DIR:$PATH"
	export PATH
	STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
	export STUB_LOG
}

@test "tmux stub is picked up from PATH, not the real tmux" {
	run command -v tmux
	[ "$status" -eq 0 ]
	[ "$output" = "$STUB_DIR/tmux" ]
}

@test "tmux stub logs its arguments and exits 0" {
	run tmux new -As main -c /workspace
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux new -As main -c /workspace" ]
}

@test "docker stub logs under its own name" {
	run docker exec -it agents lab ls
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "docker exec -it agents lab ls" ]
}

@test "agent stubs shadow the real agents and log under their own names" {
	for agent in pi omp claude; do
		run command -v "$agent"
		[ "$status" -eq 0 ]
		[ "$output" = "$STUB_DIR/$agent" ]
	done

	run pi -p "2 + 2"
	[ "$status" -eq 0 ]
	run omp -p hi
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "pi -p '2 + 2'
omp -p hi" ]
}

@test "transport stubs shadow the real mosh, tssh and ssh" {
	# the most expensive mistake the harness could make: a transport left
	# unshadowed sends the tests off to the live bastion instead of the log
	for transport in mosh tssh ssh; do
		run command -v "$transport"
		[ "$status" -eq 0 ]
		[ "$output" = "$STUB_DIR/$transport" ]
	done

	run mosh bastion-host -- lab-host ls
	[ "$status" -eq 0 ]
	run ssh bastion-host -t "lab-host omp"
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "mosh bastion-host -- lab-host ls
ssh bastion-host -t 'lab-host omp'" ]
}

@test "arguments with spaces stay one argument in the log" {
	run tmux run "2 + 2"
	[ "$status" -eq 0 ]
	[ "$(stub_log)" = "tmux run '2 + 2'" ]
}

@test "calls append, one line per invocation" {
	tmux ls
	docker ps
	[ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "2" ]
}

@test "STUB_RC sets the exit code" {
	STUB_RC=1 run tmux list-sessions
	[ "$status" -eq 1 ]
	[ "$(stub_log)" = "tmux list-sessions" ]
}

@test "STUB_RCS gives each call its own exit code" {
	# without it there is no way to express "docker inspect succeeded, docker exec
	# returned 2", and that is exactly what the exit code pass-through of lab-host
	# is checked against
	STUB_RCS=0:2 run docker inspect -f x agents
	[ "$status" -eq 0 ]
	STUB_RCS=0:2 run docker exec agents lab ls
	[ "$status" -eq 2 ]
	# the list has run out — STUB_RC takes over from here
	STUB_RCS=0:2 STUB_RC=7 run docker ps
	[ "$status" -eq 7 ]
	[ "$(wc -l <"$STUB_LOG" | tr -d ' ')" = "3" ]
}

@test "without STUB_RCS the call counter is not even created" {
	run tmux ls
	[ "$status" -eq 0 ]
	[ ! -e "$STUB_LOG.calls" ]
}

@test "STUB_OUT goes to stdout and STUB_ERR to stderr" {
	STUB_OUT="main: 1 windows" run --separate-stderr tmux list-sessions
	[ "$status" -eq 0 ]
	[ "$output" = "main: 1 windows" ]
	[ -z "$stderr" ]

	STUB_ERR="no server running on /tmp/tmux-1000/default" STUB_RC=1 \
		run --separate-stderr tmux list-sessions
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ "$stderr" = "no server running on /tmp/tmux-1000/default" ]
}

@test "without STUB_LOG the stub still runs and writes no log" {
	unset STUB_LOG
	run tmux ls
	[ "$status" -eq 0 ]
	[ ! -e "$BATS_TEST_TMPDIR/stub.log" ]
}
