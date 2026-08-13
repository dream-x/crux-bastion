# Helpers shared by every bats file of the suite, one copy for all of them.
# They used to live as copies inside lab.bats, lab-host.bats and cx.bats — and had
# already started to drift apart (in one copy the Linux branch of `script(1)` lost
# arguments containing spaces, in another one it did not).

# the stub log: an empty string when no call was made at all
stub_log() {
	if [ -e "$STUB_LOG" ]; then
		cat "$STUB_LOG"
	fi
}

# Forget everything the stubs recorded: needed when a single test does two runs in
# a row and the STUB_RCS call counter left over from the first one gets in the way
# of the second.
stub_reset() {
	rm -f "$STUB_LOG" "$STUB_LOG.calls"
}

# Run with a real TTY on both ends: the `docker exec -it` and mosh branches cannot
# be checked otherwise — under bats neither stdin nor stdout is a terminal.
#
# The syntax of script(1) differs between BSD (macOS) and util-linux (Linux): BSD
# takes the command as a list, util-linux takes a single string after -c. The string
# is assembled with printf %q, otherwise `cx attach 'two words'` would fall apart
# into two arguments there.
tty_run() {
	case "$(uname -s)" in
	Darwin | *BSD) script -q /dev/null "$@" ;;
	*) script -qec "$(printf '%q ' "$@")" /dev/null ;;
	esac
}

# An external tool without which a test checks nothing. Skipping is the default,
# with LAB_TESTS_STRICT=1 it is a failure instead: a silent skip takes out a dozen
# and a half tests at once (the whole of cx.bats without fish, every TTY branch
# without script), and there is nobody to notice — the project has no CI. On a
# developer machine a skip is more convenient, in the pre-commit check strict mode is.
need_tool() {
	command -v "$1" >/dev/null 2>&1 && return 0
	if [ -n "${LAB_TESTS_STRICT:-}" ]; then
		printf 'required tool not found: %s\n' "$1" >&2
		return 1
	fi
	skip "no $1 to run this check"
}
