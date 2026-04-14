#!/usr/bin/env python3
"""
SVN Repository Inventory Script
---------------------------------
Collects the following statistics for a given SVN repository:

  1. Total repository size (working-copy bytes of all files)
  2. Total number of branches
  3. Total number of tags
  4. Total number of merge commits
  5. Total number of files larger than 100 MiB

Requirements:
  - SVN command-line client ('svn') installed and available on PATH.
  - Network / credential access to the target repository.

Usage:
  python svn_inventory.py <repo_url> [options]

Examples:
  python svn_inventory.py https://svn.example.com/repos/myproject
  python svn_inventory.py https://svn.example.com/repos/myproject \\
      --username alice --password s3cr3t
  python svn_inventory.py https://svn.example.com/repos/myproject \\
      --branches-path branches --tags-path tags --log-limit 5000
  python svn_inventory.py https://svn.example.com/repos/myproject \\
      --skip-size
"""

from __future__ import annotations

import argparse
import csv
import logging
import re
import subprocess
import sys
import textwrap
import xml.etree.ElementTree as ET

LARGE_FILE_THRESHOLD = 100 * 1024 * 1024  # 100 MiB in bytes

logger = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────
# Low-level helpers
# ─────────────────────────────────────────────────────────────────

def run_svn(cmd: list, timeout: int = 600) -> str | None:
    """
    Execute an SVN command and return its stdout as a string.
    Returns None and prints a warning if the command fails or times out.
    Exits with an error message if the 'svn' binary is not found.
    """
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            encoding="utf-8",
            errors="replace",
        )
        if result.returncode != 0:
            logger.warning(result.stderr.strip())
            return None
        return result.stdout
    except subprocess.TimeoutExpired:
        logger.error(
            "Command timed out after %ds: %s", timeout, " ".join(cmd)
        )
        return None
    except FileNotFoundError:
        logger.critical(
            "'svn' command not found. "
            "Install the SVN command-line client and ensure it is on PATH."
        )
        sys.exit(1)


def build_auth_flags(username: str | None, password: str | None) -> list:
    """Return SVN authentication / non-interactive flags."""
    flags = []
    if username:
        flags += ["--username", username]
    if password:
        flags += ["--password", password]
    if username or password:
        flags += ["--no-auth-cache", "--non-interactive"]
    return flags


def format_size(size_bytes: int) -> str:
    """Convert a byte count to a human-readable string (e.g. '1.23 GB')."""
    value = float(size_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024.0:
            return f"{value:,.2f} {unit}"
        value /= 1024.0
    return f"{value:,.2f} PB"


# ─────────────────────────────────────────────────────────────────
# Inventory functions
# ─────────────────────────────────────────────────────────────────

def get_repo_info(repo_url: str, auth: list) -> dict | None:
    """
    Retrieve basic repository metadata using 'svn info --xml'.
    Returns a dict with keys: revision, root, uuid.
    """
    output = run_svn(["svn", "info", "--xml", repo_url] + auth)
    if not output:
        return None
    try:
        root = ET.fromstring(output)
        entry = root.find("entry")
        if entry is None:
            return None
        return {
            "revision": entry.get("revision", "?"),
            "root":     entry.findtext("repository/root", "?"),
            "uuid":     entry.findtext("repository/uuid", "?"),
        }
    except ET.ParseError as exc:
        logger.warning("Could not parse 'svn info' output: %s", exc)
        return None


def count_direct_children(url: str, auth: list) -> tuple[int, list]:
    """
    List immediate children at *url* and return (count, sorted_names).
    Used for branches and tags directories.
    """
    output = run_svn(["svn", "list", "--xml", url] + auth)
    if not output:
        return 0, []
    try:
        root = ET.fromstring(output)
        names = [e.findtext("name", "") for e in root.findall(".//entry")]
        names = sorted(n for n in names if n)
        return len(names), names
    except ET.ParseError as exc:
        logger.warning("Could not parse 'svn list' output: %s", exc)
        return 0, []


def get_size_and_large_files(
    repo_url: str, auth: list
) -> tuple[int, list[tuple[str, int]]]:
    """
    Recursively walk the repository and compute:
      - total_size  : sum of all file sizes in bytes
      - large_files : [(path, size)] for every file >= LARGE_FILE_THRESHOLD

    Uses 'svn list --depth infinity --xml'.
    NOTE: This can be slow for very large repositories.
          Use --skip-size to bypass this step.
    """
    cmd = ["svn", "list", "--depth", "infinity", "--xml", repo_url] + auth
    output = run_svn(cmd, timeout=1800)
    if not output:
        return 0, []

    total_size = 0
    large_files: list[tuple[str, int]] = []

    try:
        root = ET.fromstring(output)
        for entry in root.findall(".//entry"):
            if entry.get("kind") != "file":
                continue
            size_text = entry.findtext("size")
            name      = entry.findtext("name", "<unknown>")
            if size_text is None:
                continue
            try:
                size = int(size_text)
            except ValueError:
                continue
            total_size += size
            if size >= LARGE_FILE_THRESHOLD:
                large_files.append((name, size))
    except ET.ParseError as exc:
        logger.warning("Could not parse recursive file list: %s", exc)

    large_files.sort(key=lambda x: x[1], reverse=True)
    return total_size, large_files


def count_merge_commits(
    repo_url: str, auth: list, limit: int | None
) -> tuple[int, int]:
    """
    Scan the SVN commit log to count merge commits.

    A commit is classified as a merge when ANY of the following is true:
      1. The commit message matches the pattern r'\\bmerge[d]?\\b'
         (case-insensitive) – covers most standard merge workflows.
      2. At least one changed path carries prop-mods="true", which
         indicates an svn:mergeinfo property change recorded by
         'svn merge' operations.

    Returns (total_commits, merge_commits).

    NOTE: Heuristic #2 may produce a small number of false positives
          if unrelated property edits occurred.  Pass --log-limit to
          cap the number of revisions scanned.
    """
    cmd = ["svn", "log", "--xml", "-v", repo_url] + auth
    if limit:
        cmd += ["-l", str(limit)]

    output = run_svn(cmd, timeout=1800)
    if not output:
        return 0, 0

    merge_re = re.compile(r"\bmerge[d]?\b", re.IGNORECASE)
    total   = 0
    merges  = 0

    try:
        root = ET.fromstring(output)
        for entry in root.findall("logentry"):
            total += 1
            msg = entry.findtext("msg", "")

            # Heuristic 1: commit message mentions "merge" or "merged"
            msg_is_merge = bool(merge_re.search(msg))

            # Heuristic 2: at least one path records a property change
            #               (svn:mergeinfo updated by 'svn merge')
            prop_change = any(
                p.get("prop-mods") == "true"
                for p in entry.findall(".//path")
            )

            if msg_is_merge or prop_change:
                merges += 1
    except ET.ParseError as exc:
        logger.warning("Could not parse 'svn log' output: %s", exc)

    return total, merges


# ─────────────────────────────────────────────────────────────────
# Reporting helpers
# ─────────────────────────────────────────────────────────────────

def _print_name_list(names: list, shown: int = 10) -> None:
    """Print up to *shown* names as a bullet list, with a continuation line."""
    for n in names[:shown]:
        print(f"    • {n}")
    if len(names) > shown:
        print(f"    … and {len(names) - shown} more")


def write_csv_report(
    output_path: str,
    info: dict | None,
    branch_count: int,
    tag_count: int,
    total_commits: int,
    merge_count: int,
    total_size: int | None,
    large_files: list[tuple[str, int]],
) -> None:
    """Write the inventory results to *output_path* as a CSV file."""
    with open(output_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)

        # ── Summary section ───────────────────────────────────────
        writer.writerow(["Metric", "Value"])
        if info:
            writer.writerow(["Latest Revision", f"r{info['revision']}"])
            writer.writerow(["Repository Root", info["root"]])
            writer.writerow(["Repository UUID", info["uuid"]])
        writer.writerow(["Total Branches", branch_count])
        writer.writerow(["Total Tags", tag_count])
        writer.writerow(["Total Commits", total_commits])
        writer.writerow(["Merge Commits", merge_count])
        if total_size is not None:
            writer.writerow(["Total Repository Size (bytes)", total_size])
            writer.writerow(["Total Repository Size", format_size(total_size)])
            writer.writerow(["Files > 100 MiB", len(large_files)])

        # ── Large files section ───────────────────────────────────
        if large_files:
            writer.writerow([])
            writer.writerow(["Large Files (> 100 MiB)"])
            writer.writerow(["Path", "Size (bytes)", "Size (human-readable)"])
            for path, sz in large_files:
                writer.writerow([path, sz, format_size(sz)])

    logger.info("CSV report written → %s", output_path)


# ─────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Collect inventory statistics for an SVN repository.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Examples:
              python svn_inventory.py https://svn.example.com/repos/myproject
              python svn_inventory.py https://svn.example.com/repos/myproject \\
                  --username alice --password s3cr3t
              python svn_inventory.py https://svn.example.com/repos/myproject \\
                  --branches-path branches --tags-path tags --log-limit 5000
        """),
    )
    parser.add_argument(
        "repo_url",
        help="Root URL of the SVN repository to inspect.",
    )
    parser.add_argument("-u", "--username", default=None, help="SVN username.")
    parser.add_argument("-p", "--password", default=None, help="SVN password.")
    parser.add_argument(
        "--branches-path",
        default="branches",
        metavar="PATH",
        help="Relative sub-path for branches (default: 'branches').",
    )
    parser.add_argument(
        "--tags-path",
        default="tags",
        metavar="PATH",
        help="Relative sub-path for tags (default: 'tags').",
    )
    parser.add_argument(
        "--log-limit",
        type=int,
        default=None,
        metavar="N",
        help="Limit merge scan to the last N revisions (default: all).",
    )
    parser.add_argument(
        "--skip-size",
        action="store_true",
        help="Skip the file-size scan (fast mode for very large repositories).",
    )
    parser.add_argument(
        "--output",
        default=None,
        metavar="FILE",
        help="Write inventory results to this CSV file.",
    )
    parser.add_argument(
        "--log-file",
        default=None,
        metavar="FILE",
        help="Write log messages to this file in addition to stderr.",
    )

    args   = parser.parse_args()
    url    = args.repo_url.rstrip("/")
    auth   = build_auth_flags(args.username, args.password)
    SEP    = "=" * 64

    # ── Logging setup ─────────────────────────────────────────────
    _handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    if args.log_file:
        _handlers.append(logging.FileHandler(args.log_file, encoding="utf-8"))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s  %(levelname)-8s  %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=_handlers,
    )

    # ── Header ────────────────────────────────────────────────────
    print(SEP)
    print("  SVN Repository Inventory Report")
    print(SEP)
    print(f"  Repository : {url}")
    print()
    logger.info("Inventory started for: %s", url)
    # ── Step 1 · Repository metadata ──────────────────────────────
    print("Step 1/5  Fetching repository metadata …")
    logger.info("Step 1/5 – fetching repository metadata")
    info = get_repo_info(url, auth)
    if info:
        print(f"  Latest revision : r{info['revision']}")
        print(f"  Repository root : {info['root']}")
        print(f"  Repository UUID : {info['uuid']}")
        logger.info(
            "Metadata retrieved – revision: %s, root: %s, uuid: %s",
            info["revision"], info["root"], info["uuid"],
        )
    else:
        print("  (unable to retrieve repository metadata)")
        logger.warning("Unable to retrieve repository metadata.")
    print()

    # ── Step 2 · Branches ─────────────────────────────────────────
    branches_url = f"{url}/{args.branches_path}"
    print(f"Step 2/5  Counting branches  →  {branches_url}")
    logger.info("Step 2/5 – counting branches at: %s", branches_url)
    branch_count, branch_names = count_direct_children(branches_url, auth)
    print(f"  Total branches  : {branch_count}")
    logger.info("Branch count: %d", branch_count)
    _print_name_list(branch_names)
    print()

    # ── Step 3 · Tags ─────────────────────────────────────────────
    tags_url = f"{url}/{args.tags_path}"
    print(f"Step 3/5  Counting tags  →  {tags_url}")
    logger.info("Step 3/5 – counting tags at: %s", tags_url)
    tag_count, tag_names = count_direct_children(tags_url, auth)
    print(f"  Total tags      : {tag_count}")
    logger.info("Tag count: %d", tag_count)
    _print_name_list(tag_names)
    print()

    # ── Step 4 · Merges ───────────────────────────────────────────
    limit_note = (
        f" (last {args.log_limit} revisions)" if args.log_limit else " (all revisions)"
    )
    print(f"Step 4/5  Scanning commit log for merges{limit_note} …")
    logger.info("Step 4/5 – scanning commit log for merges%s", limit_note)
    total_commits, merge_count = count_merge_commits(url, auth, args.log_limit)
    print(f"  Total commits   : {total_commits:,}")
    print(f"  Merge commits   : {merge_count:,}")
    logger.info("Commits: %d total, %d merges", total_commits, merge_count)
    print()

    # ── Step 5 · File sizes ───────────────────────────────────────
    total_size: int | None = None
    large_files: list[tuple[str, int]] = []

    if args.skip_size:
        print("Step 5/5  File-size scan skipped (--skip-size).")
        logger.info("Step 5/5 – file-size scan skipped.")
    else:
        print("Step 5/5  Scanning all files for sizes (this may take a while) …")
        logger.info("Step 5/5 – scanning all files for sizes at: %s", url)
        total_size, large_files = get_size_and_large_files(url, auth)
        print(f"  Total repo size  : {format_size(total_size)}  ({total_size:,} bytes)")
        print(f"  Files > 100 MiB  : {len(large_files)}")
        logger.info(
            "Size scan complete – total: %s (%d bytes), large files: %d",
            format_size(total_size), total_size, len(large_files),
        )
        if large_files:
            print()
            print("  Large files (descending size):")
            for path, sz in large_files:
                print(f"    {format_size(sz):>14}   {path}")
    print()

    # ── Summary ───────────────────────────────────────────────────
    print(SEP)
    print("  SUMMARY")
    print(SEP)
    if info:
        print(f"  {'Latest revision':<30} r{info['revision']}")
    print(f"  {'Total branches':<30} {branch_count:,}")
    print(f"  {'Total tags':<30} {tag_count:,}")
    print(f"  {'Total commits':<30} {total_commits:,}")
    print(f"  {'Merge commits':<30} {merge_count:,}")
    if total_size is not None:
        print(f"  {'Total repository size':<30} {format_size(total_size)}")
        print(f"  {'Files > 100 MiB':<30} {len(large_files):,}")
    print(SEP)

    # ── CSV output ─────────────────────────────────────────────
    if args.output:
        write_csv_report(
            args.output, info, branch_count, tag_count,
            total_commits, merge_count, total_size, large_files,
        )
        print(f"\n  CSV report written → {args.output}")

    logger.info("Inventory complete for: %s", url)


if __name__ == "__main__":
    main()
