# lib_conf.sh — shared by start_server / stop_server: conf reading, the run
# name, the port overrides, exporting settings, fetching the source.

ini_get() {  # ini_get <section> <key> <file>
    awk -v want_s="$1" -v want_k="$2" '
        /^[[:space:]]*[;#]/ { next }
        /^[[:space:]]*\[/ {
            s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\][[:space:]]*$/, "", s); next
        }
        s == want_s && index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1)
            v = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (k == want_k) { print v; exit }
        }
    ' "$3"
}

ini_keys() {  # ini_keys <section> <file>  -> "key=value" lines
    awk -v want_s="$1" '
        /^[[:space:]]*[;#]/ { next }
        /^[[:space:]]*\[/ {
            s = $0; sub(/^[[:space:]]*\[/, "", s); sub(/\][[:space:]]*$/, "", s); next
        }
        s == want_s && index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1)
            v = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print k "=" v
        }
    ' "$2"
}

# conf_parse_args <conf> [port=N] [db_port=N] [--source DIR]
# Sets CONF (absolute), NAME, PORT, DB_PORT, RUN_DIR, SOURCE, SOURCE_KIND (git|dir).
conf_parse_args() {
    [ $# -ge 1 ] || { echo "usage: $(basename "$0") <conf> [port=N] [db_port=N] [--source DIR]" >&2; exit 1; }
    CONF="$1"; shift
    [ -f "$CONF" ] || { echo "ERROR: conf not found: $CONF" >&2; exit 1; }
    SOURCE=""; local port_override="" db_override=""
    while [ $# -gt 0 ]; do
        case "$1" in
            port=*)     port_override="${1#port=}" ;;
            db_port=*)  db_override="${1#db_port=}" ;;
            --source)   shift; SOURCE="$1" ;;
            --source=*) SOURCE="${1#--source=}" ;;
            *) echo "ERROR: unknown argument '$1' (only port=, db_port= and --source may be given)" >&2; exit 1 ;;
        esac
        shift
    done
    PORT="${port_override:-$(ini_get server port "$CONF")}"
    DB_PORT="${db_override:-$(ini_get server db_port "$CONF")}"
    [ -n "$PORT" ] && [ -n "$DB_PORT" ] || { echo "ERROR: $CONF must set [server] port and db_port" >&2; exit 1; }
    CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"   # absolute
    NAME="$(conf_run_name "$CONF" "$port_override" "$db_override")"
    RUN_DIR="$HERE/deployed/$NAME"
    # Where club_server comes from: --source, else [product] source. A git
    # URL (git@…, ssh://, https://, http://, or ending in .git) is cloned at
    # [product] ref into the run directory; anything else is a checkout used
    # in place. A relative directory is relative to the conf file, never to
    # the caller's directory, so a conf kept in a consumer repo can say
    # `source = ../../server/club_server`.
    [ -n "$SOURCE" ] || SOURCE="$(ini_get product source "$CONF")"
    [ -n "$SOURCE" ] || { echo "ERROR: $CONF must set [product] source (a checkout or a git URL), or pass --source" >&2; exit 1; }
    if source_is_git "$SOURCE"; then
        SOURCE_KIND=git
    else
        SOURCE_KIND=dir
        case "$SOURCE" in /*) ;; *) SOURCE="$(dirname "$CONF")/$SOURCE" ;; esac
        [ -d "$SOURCE" ] || { echo "ERROR: source checkout not found: $SOURCE" >&2; exit 1; }
        SOURCE="$(cd "$SOURCE" && pwd)"
    fi
}

source_is_git() {
    case "$1" in git@*|ssh://*|https://*|http://*|*.git) return 0 ;; *) return 1 ;; esac
}

# conf_run_name <abs conf> <port override> <db override>
# The absolute conf path with / replaced by __ and the extension dropped
# (tmux refuses dots in a session name), plus _<port>_<db_port> when the
# ports are overridden. Two confs of the same name in different repos, or
# the same conf run twice on different ports, therefore never collide.
conf_run_name() {
    local n="${1%.conf}"; n="${n#/}"; n="${n//\//__}"; n="${n//./_}"
    if [ -n "$2" ] || [ -n "$3" ]; then n="${n}_${PORT}_${DB_PORT}"; fi
    printf '%s' "$n"
}

conf_export_settings() {
    local data="$RUN_DIR/data"
    export SERVER_PORT="$PORT" DB_PORT DATA_DIR="$data"
    export BOOTSTRAP_PASSWORD="$(ini_get server bootstrap_password "$CONF")"
    export SECRET_KEY="$(ini_get server secret_key "$CONF")"
    export DEBUG="$(ini_get server debug "$CONF")"; DEBUG="${DEBUG:-false}"
    local db_user db_pass db_name
    db_user="$(ini_get server db_user "$CONF")";     db_user="${db_user:-myclub}"
    db_pass="$(ini_get server db_password "$CONF")"; db_pass="${db_pass:-devpass}"
    db_name="$(ini_get server db_name "$CONF")";     db_name="${db_name:-myclub}"
    export POSTGRES_USER="$db_user" POSTGRES_PASSWORD="$db_pass" POSTGRES_DB="$db_name"
    export DATABASE_URL="postgresql+asyncpg://${db_user}:${db_pass}@localhost:${DB_PORT}/${db_name}"
    export UPLOAD_DIR="$data/uploads" STATIC_DIR="$data/static"
    # Every [settings] key, upper-cased. <port> in a value is the server port.
    local line k v
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        k="${line%%=*}"; v="${line#*=}"; v="${v//<port>/$PORT}"
        export "$(echo "$k" | tr '[:lower:]' '[:upper:]')=$v"
    done < <(ini_keys settings "$CONF")
}

conf_fetch_source() {  # clone $SOURCE at [product] ref into $1, or update it
    local dir="$1" ref
    ref="$(ini_get product ref "$CONF")"; ref="${ref:-main}"
    if [ ! -d "$dir/.git" ]; then
        echo "==> cloning $SOURCE"; git clone --quiet "$SOURCE" "$dir"
    else
        git -C "$dir" fetch --quiet origin
    fi
    git -C "$dir" checkout --quiet "$ref"
    git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -qv HEAD && git -C "$dir" pull --quiet --ff-only || true
    echo "    source at $(git -C "$dir" rev-parse --short HEAD) ($ref)"
}
