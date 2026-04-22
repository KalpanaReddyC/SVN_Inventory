#!/usr/bin/env bash
# =====================================================================
# SVN Repository Inventory Script (Shell port of svn_inventory.py)
# ---------------------------------------------------------------------
# Collects the following statistics for a given SVN repository:
#   1. Total repository size (bytes of all files)
#   2. Total number of branches
#   3. Total number of tags
#   4. Total number of merge commits
#   5. Total number of files larger than 100 MiB
#
# Requirements (all standard, no internet downloads needed):
#   - bash (>= 4)
#   - svn command-line client on PATH
#   - Standard POSIX tools: awk, sed, grep, sort, tr, mktemp, date
#
# Usage:
#   ./svn_inventory.sh <repo_url> [options]
#
# Options:
#   -u, --username USER       SVN username
#   -p, --password PASS       SVN password
#       --branches-path PATH  Relative sub-path for branches (default: branches)
#       --tags-path PATH      Relative sub-path for tags     (default: tags)
#       --log-limit N         Limit merge scan to last N revisions
#       --skip-size           Skip file-size scan (fast mode)
#       --output FILE         Write CSV report to FILE
#       --log-file FILE       Write log messages to FILE (in addition to stderr)
#   -h, --help                Show this help and exit
# =====================================================================

set -u
set -o pipefail

LARGE_FILE_THRESHOLD=$((100 * 1024 * 1024))   # 100 MiB in bytes
SEP="================================================================"

# ---- default args --------------------------------------------------
REPO_URL=""
USERNAME=""
PASSWORD=""
BRANCHES_PATH="branches"
TAGS_PATH="tags"
LOG_LIMIT=""
SKIP_SIZE=0
OUTPUT_CSV=""
LOG_FILE=""

# ---- logging -------------------------------------------------------
log() {
    # $1=level  $2...=message
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="$ts  ${level}  $*"
    echo "$line" >&2
    if [[ -n "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE"
    fi
}
log_info()  { log "INFO    " "$@"; }
log_warn()  { log "WARNING " "$@"; }
log_error() { log "ERROR   " "$@"; }
log_crit()  { log "CRITICAL" "$@"; }

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---- argument parsing ----------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            usage 0 ;;
        -u|--username)        USERNAME="${2:-}"; shift 2 ;;
        -p|--password)        PASSWORD="${2:-}"; shift 2 ;;
        --branches-path)      BRANCHES_PATH="${2:-}"; shift 2 ;;
        --tags-path)          TAGS_PATH="${2:-}"; shift 2 ;;
        --log-limit)          LOG_LIMIT="${2:-}"; shift 2 ;;
        --skip-size)          SKIP_SIZE=1; shift ;;
        --output)             OUTPUT_CSV="${2:-}"; shift 2 ;;
        --log-file)           LOG_FILE="${2:-}"; shift 2 ;;
        --)                   shift; break ;;
        -*)                   echo "Unknown option: $1" >&2; usage 1 ;;
        *)
            if [[ -z "$REPO_URL" ]]; then
                REPO_URL="$1"
            else
                echo "Unexpected extra argument: $1" >&2; usage 1
            fi
            shift ;;
    esac
done

if [[ -z "$REPO_URL" ]]; then
    echo "Error: repository URL is required." >&2
    usage 1
fi

# Strip trailing slash
REPO_URL="${REPO_URL%/}"

# Ensure svn exists
if ! command -v svn >/dev/null 2>&1; then
    log_crit "'svn' command not found. Install the SVN command-line client and ensure it is on PATH."
    exit 1
fi

# ---- build auth flags ----------------------------------------------
AUTH_FLAGS=()
if [[ -n "$USERNAME" ]]; then
    AUTH_FLAGS+=(--username "$USERNAME")
fi
if [[ -n "$PASSWORD" ]]; then
    AUTH_FLAGS+=(--password "$PASSWORD")
fi
if [[ -n "$USERNAME" || -n "$PASSWORD" ]]; then
    AUTH_FLAGS+=(--no-auth-cache --non-interactive)
fi

# ---- helpers -------------------------------------------------------

# Run an svn command; prints stdout on success, returns non-zero on failure.
run_svn() {
    local out err rc
    err=$(mktemp)
    # Use stdout capture; stderr to temp file
    if ! out=$(svn "$@" 2>"$err"); then
        rc=$?
        log_warn "$(tr -d '\r' < "$err" | sed -e 's/[[:space:]]*$//' | head -c 2000)"
        rm -f "$err"
        return "$rc"
    fi
    rm -f "$err"
    printf '%s' "$out"
    return 0
}

# Human-readable size, e.g. 1234567 -> "1.18 MB"
format_size() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", u, " ");
        v = b + 0.0; i = 1;
        while (v >= 1024 && i < 6) { v /= 1024.0; i++ }
        printf "%.2f %s", v, u[i];
    }'
}

# Comma-grouped integer, e.g. 1234567 -> "1,234,567"
format_int() {
    awk -v n="$1" 'BEGIN {
        s = sprintf("%d", n); neg = ""
        if (substr(s,1,1) == "-") { neg = "-"; s = substr(s,2) }
        out = ""; len = length(s)
        for (i = len; i > 0; i--) {
            out = substr(s, i, 1) out
            p = len - i + 1
            if (p % 3 == 0 && i > 1) out = "," out
        }
        print neg out
    }'
}

# CSV-quote a single field for safe inclusion in the CSV report.
csv_quote() {
    local s="$1"
    # Double up any existing double-quotes and wrap in quotes.
    s=${s//\"/\"\"}
    printf '"%s"' "$s"
}

# ---- SVN-specific helpers ------------------------------------------

# Fetch repo info -> prints: "<revision>|<root>|<uuid>" or empty on failure.
get_repo_info() {
    local xml
    xml=$(run_svn info --xml "$REPO_URL" "${AUTH_FLAGS[@]}") || return 1
    [[ -z "$xml" ]] && return 1

    # revision is an attribute of <entry ...>
    local revision root uuid
    revision=$(printf '%s' "$xml" \
        | tr '\n' ' ' \
        | sed -n 's/.*<entry[^>]*revision="\([^"]*\)".*/\1/p' \
        | head -n1)
    root=$(printf '%s' "$xml" \
        | tr '\n' ' ' \
        | sed -n 's|.*<root>\([^<]*\)</root>.*|\1|p' \
        | head -n1)
    uuid=$(printf '%s' "$xml" \
        | tr '\n' ' ' \
        | sed -n 's|.*<uuid>\([^<]*\)</uuid>.*|\1|p' \
        | head -n1)

    [[ -z "$revision" ]] && revision="?"
    [[ -z "$root"     ]] && root="?"
    [[ -z "$uuid"     ]] && uuid="?"

    printf '%s|%s|%s\n' "$revision" "$root" "$uuid"
}

# List direct children at a URL. Writes names (one per line) to given file,
# echoes count to stdout.
count_direct_children() {
    local url="$1"
    local outfile="$2"
    : > "$outfile"

    local xml
    xml=$(run_svn list --xml "$url" "${AUTH_FLAGS[@]}") || { echo 0; return 0; }
    [[ -z "$xml" ]] && { echo 0; return 0; }

    # Extract every <name>...</name>. svn list --xml prints one per line,
    # but we normalise newlines first and then extract.
    printf '%s' "$xml" \
        | tr -d '\r' \
        | awk '
            BEGIN { RS="<name>"; ORS="" }
            NR > 1 {
                end = index($0, "</name>")
                if (end > 0) print substr($0, 1, end-1) "\n"
            }
        ' \
        | sort -u > "$outfile"

    wc -l < "$outfile" | tr -d ' '
}

# Walk the whole repository and compute total size + large files.
# Writes large files "<size> <path>" (size in bytes, sorted desc) to $2.
# Echoes "<total_size>|<large_count>".
get_size_and_large_files() {
    local large_out="$1"
    local xml_file
    xml_file=$(mktemp)

    if ! svn list --depth infinity --xml "$REPO_URL" "${AUTH_FLAGS[@]}" \
            >"$xml_file" 2>"${xml_file}.err"; then
        log_warn "$(tr -d '\r' < "${xml_file}.err" | sed -e 's/[[:space:]]*$//' | head -c 2000)"
        rm -f "$xml_file" "${xml_file}.err"
        : > "$large_out"; echo "0|0"; return 0
    fi
    rm -f "${xml_file}.err"

    : > "$large_out"

    # The XML from `svn list --xml` may be pretty-printed OR all on one line
    # (observed on some Windows builds). Rather than depend on whitespace,
    # split the stream on "</entry>" boundaries so each record is one awk
    # record, regardless of embedded newlines.
    local meta
    meta=$(
        tr -d '\r' < "$xml_file" \
        | awk -v thr="$LARGE_FILE_THRESHOLD" -v large="$large_out" '
            BEGIN {
                RS = "</entry>"
                total = 0
                large_n = 0
            }
            {
                # Skip anything before the first <entry ...>
                if (!match($0, /<entry[^>]*>/)) next

                # Extract the opening <entry ...> tag to inspect kind="..."
                open_tag = substr($0, RSTART, RLENGTH)
                if (open_tag !~ /kind="file"/) next

                # Body after the opening tag is where <name>, <size>, etc. live.
                body = substr($0, RSTART + RLENGTH)

                name = ""
                if (match(body, /<name>[^<]*<\/name>/)) {
                    name = substr(body, RSTART + 6, RLENGTH - 13)
                }

                size = -1
                if (match(body, /<size>[0-9]+<\/size>/)) {
                    size = substr(body, RSTART + 6, RLENGTH - 13) + 0
                }

                if (size >= 0) {
                    total += size
                    if (size + 0 >= thr + 0) {
                        printf "%d %s\n", size, name >> large
                        large_n++
                    }
                }
            }
            END { printf "%.0f|%d\n", total, large_n }
        '
    )

    rm -f "$xml_file"

    if [[ -s "$large_out" ]]; then
        sort -k1,1nr -o "$large_out" "$large_out"
    fi

    echo "$meta"
}

# Scan svn log for merge commits.
# Echoes "<total_commits>|<merge_commits>".
count_merge_commits() {
    local limit="$1"
    local xml_file
    xml_file=$(mktemp)

    local args=(log --xml -v "$REPO_URL" "${AUTH_FLAGS[@]}")
    if [[ -n "$limit" ]]; then
        args+=(-l "$limit")
    fi

    if ! svn "${args[@]}" >"$xml_file" 2>"${xml_file}.err"; then
        log_warn "$(tr -d '\r' < "${xml_file}.err" | sed -e 's/[[:space:]]*$//' | head -c 2000)"
        rm -f "$xml_file" "${xml_file}.err"
        echo "0|0"; return 0
    fi
    rm -f "${xml_file}.err"

    # Split on </logentry> so each record is exactly one commit (regardless
    # of whether svn emits pretty-printed XML or a single line).
    # Heuristics match the Python version:
    #   1. Commit message contains \bmerge[d]?\b (case-insensitive)
    #   2. Any <path ... prop-mods="true" ...> inside the entry
    local result
    result=$(
        tr -d '\r' < "$xml_file" \
        | awk '
            BEGIN {
                RS = "</logentry>"
                total = 0
                merges = 0
            }
            {
                if (!match($0, /<logentry[[:space:]>]/)) next
                total++

                # Heuristic 2: any <path ... prop-mods="true" ...> ?
                is_merge = 0
                if (match($0, /<path[[:space:]][^>]*prop-mods="true"/)) {
                    is_merge = 1
                }

                # Heuristic 1: commit message contains \bmerge[d]?\b
                if (!is_merge) {
                    msg = ""
                    # <msg> may be empty (<msg/>) or have content.
                    if (match($0, /<msg>[^<]*<\/msg>/)) {
                        msg = substr($0, RSTART + 5, RLENGTH - 11)
                    }
                    low = tolower(msg)
                    if (match(low, /(^|[^a-z0-9_])merge(d)?([^a-z0-9_]|$)/)) {
                        is_merge = 1
                    }
                }

                if (is_merge) merges++
            }
            END { printf "%d|%d\n", total, merges }
        '
    )

    rm -f "$xml_file"
    echo "$result"
}

# Print up to 10 names as bullets from a file.
print_name_list() {
    local file="$1"
    local shown=10
    local total
    total=$(wc -l < "$file" | tr -d ' ')
    [[ "$total" -eq 0 ]] && return 0
    awk -v n="$shown" 'NR <= n { printf "    • %s\n", $0 }' "$file"
    if (( total > shown )); then
        printf "    … and %d more\n" "$(( total - shown ))"
    fi
}

# ---- CSV report ----------------------------------------------------
write_csv_report() {
    local out="$1"
    local revision="$2" root="$3" uuid="$4"
    local branch_count="$5" tag_count="$6"
    local total_commits="$7" merge_count="$8"
    local total_size="$9" large_count="${10}"
    local large_file="${11}"
    local have_size="${12}"   # 0/1
    local have_info="${13}"   # 0/1

    {
        printf '%s,%s\n' "$(csv_quote 'Metric')" "$(csv_quote 'Value')"
        if [[ "$have_info" == "1" ]]; then
            printf '%s,%s\n' "$(csv_quote 'Latest Revision')" "$(csv_quote "r$revision")"
            printf '%s,%s\n' "$(csv_quote 'Repository Root')" "$(csv_quote "$root")"
            printf '%s,%s\n' "$(csv_quote 'Repository UUID')" "$(csv_quote "$uuid")"
        fi
        printf '%s,%s\n' "$(csv_quote 'Total Branches')" "$(csv_quote "$branch_count")"
        printf '%s,%s\n' "$(csv_quote 'Total Tags')"     "$(csv_quote "$tag_count")"
        printf '%s,%s\n' "$(csv_quote 'Total Commits')"  "$(csv_quote "$total_commits")"
        printf '%s,%s\n' "$(csv_quote 'Merge Commits')"  "$(csv_quote "$merge_count")"
        if [[ "$have_size" == "1" ]]; then
            printf '%s,%s\n' "$(csv_quote 'Total Repository Size (bytes)')" "$(csv_quote "$total_size")"
            printf '%s,%s\n' "$(csv_quote 'Total Repository Size')" "$(csv_quote "$(format_size "$total_size")")"
            printf '%s,%s\n' "$(csv_quote 'Files > 100 MiB')" "$(csv_quote "$large_count")"
        fi

        if [[ -s "$large_file" ]]; then
            echo ""
            printf '%s\n' "$(csv_quote 'Large Files (> 100 MiB)')"
            printf '%s,%s,%s\n' \
                "$(csv_quote 'Path')" \
                "$(csv_quote 'Size (bytes)')" \
                "$(csv_quote 'Size (human-readable)')"
            while IFS=' ' read -r sz path; do
                [[ -z "$sz" ]] && continue
                printf '%s,%s,%s\n' \
                    "$(csv_quote "$path")" \
                    "$(csv_quote "$sz")" \
                    "$(csv_quote "$(format_size "$sz")")"
            done < "$large_file"
        fi
    } > "$out"

    log_info "CSV report written -> $out"
}

# ---- header --------------------------------------------------------
# Truncate log file if provided (so it starts fresh for this run)
if [[ -n "$LOG_FILE" ]]; then
    : > "$LOG_FILE"
fi

echo "$SEP"
echo "  SVN Repository Inventory Report"
echo "$SEP"
echo "  Repository : $REPO_URL"
echo
log_info "Inventory started for: $REPO_URL"

# ---- Step 1: Repository metadata -----------------------------------
echo "Step 1/5  Fetching repository metadata ..."
log_info "Step 1/5 - fetching repository metadata"

HAVE_INFO=0
REVISION="?"; ROOT="?"; UUID="?"
if info_line=$(get_repo_info); then
    IFS='|' read -r REVISION ROOT UUID <<< "$info_line"
    HAVE_INFO=1
    echo "  Latest revision : r$REVISION"
    echo "  Repository root : $ROOT"
    echo "  Repository UUID : $UUID"
    log_info "Metadata retrieved - revision: $REVISION, root: $ROOT, uuid: $UUID"
else
    echo "  (unable to retrieve repository metadata)"
    log_warn "Unable to retrieve repository metadata."
fi
echo

# ---- Step 2: Branches ----------------------------------------------
BRANCHES_URL="$REPO_URL/$BRANCHES_PATH"
echo "Step 2/5  Counting branches  ->  $BRANCHES_URL"
log_info "Step 2/5 - counting branches at: $BRANCHES_URL"

BRANCHES_FILE=$(mktemp)
BRANCH_COUNT=$(count_direct_children "$BRANCHES_URL" "$BRANCHES_FILE")
echo "  Total branches  : $BRANCH_COUNT"
log_info "Branch count: $BRANCH_COUNT"
print_name_list "$BRANCHES_FILE"
echo

# ---- Step 3: Tags --------------------------------------------------
TAGS_URL="$REPO_URL/$TAGS_PATH"
echo "Step 3/5  Counting tags  ->  $TAGS_URL"
log_info "Step 3/5 - counting tags at: $TAGS_URL"

TAGS_FILE=$(mktemp)
TAG_COUNT=$(count_direct_children "$TAGS_URL" "$TAGS_FILE")
echo "  Total tags      : $TAG_COUNT"
log_info "Tag count: $TAG_COUNT"
print_name_list "$TAGS_FILE"
echo

# ---- Step 4: Merges ------------------------------------------------
if [[ -n "$LOG_LIMIT" ]]; then
    LIMIT_NOTE=" (last $LOG_LIMIT revisions)"
else
    LIMIT_NOTE=" (all revisions)"
fi
echo "Step 4/5  Scanning commit log for merges${LIMIT_NOTE} ..."
log_info "Step 4/5 - scanning commit log for merges${LIMIT_NOTE}"

merges_line=$(count_merge_commits "$LOG_LIMIT")
IFS='|' read -r TOTAL_COMMITS MERGE_COUNT <<< "$merges_line"
: "${TOTAL_COMMITS:=0}"
: "${MERGE_COUNT:=0}"
echo "  Total commits   : $(format_int "$TOTAL_COMMITS")"
echo "  Merge commits   : $(format_int "$MERGE_COUNT")"
log_info "Commits: $TOTAL_COMMITS total, $MERGE_COUNT merges"
echo

# ---- Step 5: File sizes --------------------------------------------
HAVE_SIZE=0
TOTAL_SIZE=0
LARGE_COUNT=0
LARGE_FILE=$(mktemp)

if [[ "$SKIP_SIZE" == "1" ]]; then
    echo "Step 5/5  File-size scan skipped (--skip-size)."
    log_info "Step 5/5 - file-size scan skipped."
else
    echo "Step 5/5  Scanning all files for sizes (this may take a while) ..."
    log_info "Step 5/5 - scanning all files for sizes at: $REPO_URL"
    size_line=$(get_size_and_large_files "$LARGE_FILE")
    IFS='|' read -r TOTAL_SIZE LARGE_COUNT <<< "$size_line"
    : "${TOTAL_SIZE:=0}"
    : "${LARGE_COUNT:=0}"
    HAVE_SIZE=1
    echo "  Total repo size  : $(format_size "$TOTAL_SIZE")  ($(format_int "$TOTAL_SIZE") bytes)"
    echo "  Files > 100 MiB  : $LARGE_COUNT"
    log_info "Size scan complete - total: $(format_size "$TOTAL_SIZE") ($TOTAL_SIZE bytes), large files: $LARGE_COUNT"
    if [[ -s "$LARGE_FILE" ]]; then
        echo
        echo "  Large files (descending size):"
        while IFS=' ' read -r sz path; do
            [[ -z "$sz" ]] && continue
            printf "    %14s   %s\n" "$(format_size "$sz")" "$path"
        done < "$LARGE_FILE"
    fi
fi
echo

# ---- Summary -------------------------------------------------------
echo "$SEP"
echo "  SUMMARY"
echo "$SEP"
if [[ "$HAVE_INFO" == "1" ]]; then
    printf "  %-30s r%s\n" "Latest revision" "$REVISION"
fi
printf "  %-30s %s\n" "Total branches"  "$(format_int "$BRANCH_COUNT")"
printf "  %-30s %s\n" "Total tags"      "$(format_int "$TAG_COUNT")"
printf "  %-30s %s\n" "Total commits"   "$(format_int "$TOTAL_COMMITS")"
printf "  %-30s %s\n" "Merge commits"   "$(format_int "$MERGE_COUNT")"
if [[ "$HAVE_SIZE" == "1" ]]; then
    printf "  %-30s %s\n" "Total repository size" "$(format_size "$TOTAL_SIZE")"
    printf "  %-30s %s\n" "Files > 100 MiB"       "$(format_int "$LARGE_COUNT")"
fi
echo "$SEP"

# ---- CSV output ----------------------------------------------------
if [[ -n "$OUTPUT_CSV" ]]; then
    write_csv_report \
        "$OUTPUT_CSV" \
        "$REVISION" "$ROOT" "$UUID" \
        "$BRANCH_COUNT" "$TAG_COUNT" \
        "$TOTAL_COMMITS" "$MERGE_COUNT" \
        "$TOTAL_SIZE" "$LARGE_COUNT" \
        "$LARGE_FILE" \
        "$HAVE_SIZE" "$HAVE_INFO"
    echo
    echo "  CSV report written -> $OUTPUT_CSV"
fi

log_info "Inventory complete for: $REPO_URL"

# ---- cleanup -------------------------------------------------------
rm -f "$BRANCHES_FILE" "$TAGS_FILE" "$LARGE_FILE"

exit 0
