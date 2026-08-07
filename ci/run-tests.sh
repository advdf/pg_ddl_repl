# CI entry point: run the TAP suite; on failure, dump the per-test logs
# (prove only prints a summary, the actual errors live in tmp_check/).
set -u

make installcheck
status=$?

if [ "$status" -ne 0 ]; then
    echo ''
    echo '=== tmp_check logs ==='
    find tmp_check -type f -name '*.log' -exec sh -c 'echo "--- $1"; cat "$1"' _ {} \; 2>/dev/null
fi

exit "$status"
