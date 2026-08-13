#!/bin/sh
# The shared implementation of the test stubs (tmux, docker, mosh, ssh).
#
# A stub does nothing real: it records the arguments it got into $STUB_LOG and exits
# with the code $STUB_RC. That is how the tests check which command exactly the script
# built, without creating real sessions and without touching docker.
#
# Environment variables:
#   STUB_LOG  — the call log file; when unset, no log is written
#   STUB_RC   — the exit code of the stub (0 by default)
#   STUB_RCS  — per-call exit codes, colon separated: "0:2" means "0 for the first
#               call, 2 for the second". Needed where a single script calls a stub
#               twice and the codes have to differ (docker inspect succeeded, docker
#               exec returned 2). Once the list runs out, STUB_RC takes over. The
#               counter is shared by all stubs and lives in a file next to STUB_LOG,
#               so STUB_RCS requires STUB_LOG to be set.
#   STUB_OUT  — text for stdout (nothing by default)
#   STUB_ERR  — text for stderr (nothing by default)
#
# Log line format: the stub name and its arguments separated by spaces; an argument
# containing whitespace is wrapped in single quotes — otherwise the log could not
# tell `run pi "2 + 2"` from `run pi 2 + 2`.
#
# A stub pulls it in like this:
#   . "$(dirname "$0")/_stub.sh"
#   stub_main "tmux" "$@"

stub_main() {
	stub_name=$1
	shift

	if [ -n "${STUB_LOG:-}" ]; then
		stub_line=$stub_name
		for stub_arg in "$@"; do
			case $stub_arg in
			*[[:space:]]*) stub_line="$stub_line '$stub_arg'" ;;
			*) stub_line="$stub_line $stub_arg" ;;
			esac
		done
		printf '%s\n' "$stub_line" >>"$STUB_LOG"
	fi

	[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
	[ -n "${STUB_ERR:-}" ] && printf '%s\n' "$STUB_ERR" >&2

	exit "$(stub_rc)"
}

# The exit code of this call: from STUB_RCS by call number, otherwise STUB_RC.
# The call number is counted in a file because every stub is a separate process.
stub_rc() {
	if [ -z "${STUB_RCS:-}" ] || [ -z "${STUB_LOG:-}" ]; then
		printf '%s' "${STUB_RC:-0}"
		return 0
	fi

	stub_n=0
	if [ -f "$STUB_LOG.calls" ]; then
		stub_n=$(cat "$STUB_LOG.calls")
	fi
	stub_n=$((stub_n + 1))
	printf '%s' "$stub_n" >"$STUB_LOG.calls"

	stub_i=0
	# the colons are turned into spaces and the shell itself splits the list —
	# touching IFS for the sake of a single line would cost more (it would have
	# to be restored afterwards)
	for stub_one in $(printf '%s\n' "$STUB_RCS" | tr ':' ' '); do
		stub_i=$((stub_i + 1))
		if [ "$stub_i" -eq "$stub_n" ]; then
			printf '%s' "$stub_one"
			return 0
		fi
	done
	printf '%s' "${STUB_RC:-0}"
}
