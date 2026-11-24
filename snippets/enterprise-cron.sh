#!/bin/sh
# Provision this directory for the service account.
# All launchers use the same stable path on the same host.
exec 9>>/var/lib/example-import/import.lock || exit 1
flock -n -E 75 9
status=$?
case "$status" in
    0) ;;
    75) echo "import already active"; exit 75 ;;
    *) exit "$status" ;;
esac
# Do not daemonize, close fd 9 or unlink the lock file.
exec perl /opt/example-import/bin/import.pl
