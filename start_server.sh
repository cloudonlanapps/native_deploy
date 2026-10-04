#!/usr/bin/env bash
#
# start_server — layer 2: run club_server natively from a conf file.
#
#   ./start_server.sh sample.conf                       # ports from the conf
#   ./start_server.sh sample.conf port=8123 db_port=5511  # override the ports
#   ./start_server.sh sample_debug.conf --source ../club_server   # override the source, --reload
#   ./stop_server.sh  sample.conf [port=… db_port=…]    # stop its cluster
#   ./stop_server.sh  sample.conf [port=… db_port=…] --remove   # and delete deployed/<name>/
#
# [product] source is a checkout (relative to the conf file, used in place,
# never deleted) or a git URL (cloned at [product] ref into deployed/<name>/src);
# --source replaces it with either form. --remove only ever removes
# deployed/<name>/.
#
# The conf is read like deploy_servers' product.conf. Only the two ports may
# be overridden on the command line; every other value is what the conf says.
# The run's name is the conf name, plus _<port>_<db_port> when overridden, and
# everything the run owns lives in deployed/<name>/ next to this script:
# src/ (the clone, unless --source names a checkout to use in place), data/
# (cluster, uploads, static) and server.log.
#
# Every key under [settings] is exported as its upper-case name, so the conf
# can carry any server setting (the club identity, the module switches…)
# without this script knowing the list; club_server decides what is required.
# The values in these confs are for local testing only and are not secret.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib_conf.sh"

conf_parse_args "$@"          # sets CONF, NAME, PORT, DB_PORT, SOURCE, RUN_DIR
conf_export_settings          # exports everything run_server needs

if [ "$SOURCE_KIND" = dir ]; then
    SERVER_DIR="$SOURCE"
else
    SERVER_DIR="$RUN_DIR/src"
    conf_fetch_source "$SERVER_DIR"
fi
export SERVER_DIR

echo "==> start_server  $NAME"
echo "    conf:     $CONF"
echo "    run dir:  $RUN_DIR"
exec "$HERE/run_server.sh"
