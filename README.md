# SVN Repository Inventory Tool

A Python command-line utility that collects comprehensive inventory statistics for a given SVN (Subversion) repository. It produces a human-readable console report and an optional CSV export.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [Usage](#usage)
5. [Command-Line Options](#command-line-options)
6. [How It Works — Step by Step](#how-it-works--step-by-step)
   - [Step 1 — Repository Metadata](#step-1--repository-metadata)
   - [Step 2 — Branch Count](#step-2--branch-count)
   - [Step 3 — Tag Count](#step-3--tag-count)
   - [Step 4 — Merge Commit Detection](#step-4--merge-commit-detection)
   - [Step 5 — File Size Scan](#step-5--file-size-scan)
7. [Output](#output)
8. [Execution Examples](#execution-examples)
9. [Internal Architecture](#internal-architecture)
10. [Troubleshooting](#troubleshooting)

---

## Overview

The script gathers five key metrics from any accessible SVN repository:

| #   | Metric                 | Description                                                                                                                    |
| --- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 1   | **Repository Size**    | Sum of the working-copy byte sizes of every file in the repository.                                                            |
| 2   | **Branch Count**       | Number of immediate child directories under the branches path.                                                                 |
| 3   | **Tag Count**          | Number of immediate child directories under the tags path.                                                                     |
| 4   | **Merge Commit Count** | Commits whose log message contains "merge"/"merged" **or** whose changed paths include property modifications (svn:mergeinfo). |
| 5   | **Large File Count**   | Files whose size is ≥ 100 MiB (104,857,600 bytes).                                                                             |

---

## Prerequisites

| Requirement        | Details                                                                              |
| ------------------ | ------------------------------------------------------------------------------------ |
| **Python**         | Version 3.10 or later (uses `X \| Y` union type syntax).                             |
| **SVN CLI**        | The `svn` command-line client must be installed and available on your system `PATH`. |
| **Network Access** | The machine must be able to reach the SVN server over the network.                   |
| **Credentials**    | Valid SVN credentials (if the repository requires authentication).                   |

### Verify SVN is installed

```bash
svn --version --quiet
# Expected output: e.g., 1.14.3
```

### Verify Python version

```bash
python --version
# Expected output: Python 3.10.x or higher
```

---

## Installation

1. **Clone the repository:**

   ```bash
   git clone https://github.com/KalpanaReddyC/SVN_Inventory.git
   cd SVN_Inventory
   ```

2. **No additional Python packages are required.** The script uses only the Python standard library (`argparse`, `csv`, `logging`, `re`, `subprocess`, `xml.etree.ElementTree`).

---

## Usage

```
python svn_inventory.py <repo_url> [options]
```

### Minimal invocation

```bash
python svn_inventory.py https://svn.example.com/repos/myproject
```

### Full invocation with all options

```bash
python svn_inventory.py https://svn.example.com/repos/myproject \
    --username alice \
    --password s3cr3t \
    --branches-path branches \
    --tags-path tags \
    --log-limit 5000 \
    --output inventory_report.csv \
    --log-file inventory.log
```

---

## Command-Line Options

| Option            | Short          | Default      | Description                                                                                |
| ----------------- | -------------- | ------------ | ------------------------------------------------------------------------------------------ |
| `repo_url`        | _(positional)_ | **required** | Root URL of the SVN repository to inspect.                                                 |
| `--username`      | `-u`           | `None`       | SVN username for authentication.                                                           |
| `--password`      | `-p`           | `None`       | SVN password for authentication.                                                           |
| `--branches-path` |                | `branches`   | Relative sub-path under the repo URL where branches are stored.                            |
| `--tags-path`     |                | `tags`       | Relative sub-path under the repo URL where tags are stored.                                |
| `--log-limit`     |                | `None` (all) | Limit merge-commit scan to the last **N** revisions. Useful for very large repositories.   |
| `--skip-size`     |                | `False`      | Skip the file-size scan entirely (Steps 5). Dramatically speeds up the run for huge repos. |
| `--output`        |                | `None`       | Write inventory results to the specified CSV file.                                         |
| `--log-file`      |                | `None`       | Additionally write log messages to this file (always logs to stderr).                      |

---

## How It Works — Step by Step

Below is a detailed walkthrough of every step the script executes, from startup to final output.

### Startup & Initialization

1. **Argument parsing** — `argparse` reads and validates CLI arguments.
2. **Auth flag construction** — `build_auth_flags()` assembles `--username`, `--password`, `--no-auth-cache`, and `--non-interactive` flags for every subsequent `svn` call.
3. **Logging setup** — A `logging` handler is configured for stderr (always) and optionally for a log file (`--log-file`).
4. **Header printed** — A report banner is emitted showing the target repository URL.

---

### Step 1 — Repository Metadata

| Detail          | Value                                         |
| --------------- | --------------------------------------------- |
| **SVN command** | `svn info --xml <repo_url>`                   |
| **Timeout**     | 600 seconds (default)                         |
| **Purpose**     | Retrieve basic metadata about the repository. |

**Process:**

1. Executes `svn info --xml` against the repository URL.
2. Parses the XML response using `xml.etree.ElementTree`.
3. Extracts three fields from the `<entry>` element:
   - **revision** — The latest (HEAD) revision number.
   - **root** — The canonical repository root URL.
   - **uuid** — The repository's universally unique identifier.
4. Prints the metadata to the console.

**Example console output:**

```
Step 1/5  Fetching repository metadata …
  Latest revision : r4521
  Repository root : https://svn.example.com/repos/myproject
  Repository UUID : 13f79535-47bb-0310-9956-ffa450edef68
```

---

### Step 2 — Branch Count

| Detail          | Value                                |
| --------------- | ------------------------------------ |
| **SVN command** | `svn list --xml <repo_url>/branches` |
| **Timeout**     | 600 seconds                          |
| **Purpose**     | Count the number of branches.        |

**Process:**

1. Constructs the branches URL by appending `--branches-path` (default: `branches`) to the repo URL.
2. Executes `svn list --xml` on that URL.
3. Parses the XML and counts all `<entry>` elements (each represents a branch directory).
4. Collects and alphabetically sorts the branch names.
5. Prints the count and up to 10 branch names (with a "… and N more" continuation if applicable).

**Example console output:**

```
Step 2/5  Counting branches  →  https://svn.example.com/repos/myproject/branches
  Total branches  : 23
    • feature-auth-module
    • feature-payments
    • hotfix-login-fix
    … and 20 more
```

---

### Step 3 — Tag Count

| Detail          | Value                            |
| --------------- | -------------------------------- |
| **SVN command** | `svn list --xml <repo_url>/tags` |
| **Timeout**     | 600 seconds                      |
| **Purpose**     | Count the number of tags.        |

**Process:**

1. Constructs the tags URL by appending `--tags-path` (default: `tags`) to the repo URL.
2. Executes `svn list --xml` on that URL.
3. Parses the XML and counts all `<entry>` elements.
4. Collects and alphabetically sorts the tag names.
5. Prints the count and up to 10 tag names.

**Example console output:**

```
Step 3/5  Counting tags  →  https://svn.example.com/repos/myproject/tags
  Total tags      : 8
    • v1.0.0
    • v1.1.0
    • v2.0.0
    … and 5 more
```

---

### Step 4 — Merge Commit Detection

| Detail          | Value                                                       |
| --------------- | ----------------------------------------------------------- |
| **SVN command** | `svn log --xml -v <repo_url> [-l N]`                        |
| **Timeout**     | 1800 seconds (30 minutes)                                   |
| **Purpose**     | Count the total commits and identify which ones are merges. |

**Process:**

1. Executes `svn log --xml -v` to retrieve the full commit log with verbose path information.
   - If `--log-limit N` is set, appends `-l N` to scan only the most recent N revisions.
2. Parses the XML and iterates over each `<logentry>`.
3. Applies **two heuristics** to classify a commit as a merge:

   | Heuristic                 | How it works                                                                                                                                       |
   | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
   | **Message match**         | A case-insensitive regex `\bmerge[d]?\b` is tested against the commit message.                                                                     |
   | **Property modification** | If any `<path>` element within the log entry has `prop-mods="true"`, the commit likely updated `svn:mergeinfo` (set automatically by `svn merge`). |

4. A commit is counted as a merge if **either** heuristic matches.
5. Prints the total commit count and the merge commit count.

> **Note:** Heuristic #2 can produce a small number of false positives if unrelated property edits occurred. Use `--log-limit` to narrow the scan window.

**Example console output:**

```
Step 4/5  Scanning commit log for merges (all revisions) …
  Total commits   : 4,521
  Merge commits   : 312
```

---

### Step 5 — File Size Scan

| Detail          | Value                                               |
| --------------- | --------------------------------------------------- |
| **SVN command** | `svn list --depth infinity --xml <repo_url>`        |
| **Timeout**     | 1800 seconds (30 minutes)                           |
| **Purpose**     | Calculate total repo size and find files ≥ 100 MiB. |
| **Skippable**   | Yes — pass `--skip-size` to bypass this step.       |

**Process:**

1. If `--skip-size` is specified, this step is skipped entirely and a notice is printed.
2. Otherwise, executes `svn list --depth infinity --xml` to recursively list every file in the repository.
3. Parses the XML and iterates over each `<entry kind="file">`.
4. Sums all `<size>` values to compute **total repository size** in bytes.
5. Collects every file whose size ≥ **100 MiB** (104,857,600 bytes) into a "large files" list.
6. Sorts large files by size in descending order.
7. Prints total size (human-readable + raw bytes), large file count, and a per-file breakdown.

**Example console output:**

```
Step 5/5  Scanning all files for sizes (this may take a while) …
  Total repo size  : 2.34 GB  (2,513,412,096 bytes)
  Files > 100 MiB  : 3

  Large files (descending size):
        512.00 MB   vendor/legacy-database-dump.sql
        210.50 MB   assets/training-data.bin
        104.20 MB   lib/prebuilt-model.dat
```

> **Performance note:** This step can be very slow for repositories with hundreds of thousands of files. Use `--skip-size` to skip it.

---

## Output

### Console Report

After all five steps, a **SUMMARY** block is printed:

```
================================================================
  SUMMARY
================================================================
  Latest revision                r4521
  Total branches                 23
  Total tags                     8
  Total commits                  4,521
  Merge commits                  312
  Total repository size          2.34 GB
  Files > 100 MiB                3
================================================================
```

### CSV Report (optional)

When `--output report.csv` is specified, a CSV file is written containing:

**Section 1 — Summary metrics:**

| Metric                        | Value                                   |
| ----------------------------- | --------------------------------------- |
| Latest Revision               | r4521                                   |
| Repository Root               | https://svn.example.com/repos/myproject |
| Repository UUID               | 13f79535-...                            |
| Total Branches                | 23                                      |
| Total Tags                    | 8                                       |
| Total Commits                 | 4521                                    |
| Merge Commits                 | 312                                     |
| Total Repository Size (bytes) | 2513412096                              |
| Total Repository Size         | 2.34 GB                                 |
| Files > 100 MiB               | 3                                       |

**Section 2 — Large files detail (if any):**

| Path                            | Size (bytes) | Size (human-readable) |
| ------------------------------- | ------------ | --------------------- |
| vendor/legacy-database-dump.sql | 536870912    | 512.00 MB             |
| assets/training-data.bin        | 220737536    | 210.50 MB             |

---

## Execution Examples

### 1. Basic inventory (anonymous access)

```bash
python svn_inventory.py https://svn.example.com/repos/myproject
```

Runs all 5 steps using default paths (`branches/`, `tags/`), no authentication, and no CSV export.

### 2. Authenticated access with CSV output

```bash
python svn_inventory.py https://svn.example.com/repos/myproject \
    --username alice --password s3cr3t \
    --output inventory.csv
```

### 3. Custom branch/tag paths

Some repositories use non-standard layouts (e.g., `branch/` instead of `branches/`):

```bash
python svn_inventory.py https://svn.example.com/repos/myproject \
    --branches-path branch --tags-path tag
```

### 4. Fast mode — skip the size scan

```bash
python svn_inventory.py https://svn.example.com/repos/myproject \
    --skip-size
```

Steps 1–4 run normally; Step 5 is skipped. Size-related metrics are omitted from the report.

### 5. Limit merge scan to recent history

```bash
python svn_inventory.py https://svn.example.com/repos/myproject \
    --log-limit 5000
```

Only the last 5,000 revisions are scanned for merge commits (Step 4).

### 6. Full invocation with logging

```bash
python svn_inventory.py https://svn.example.com/repos/myproject \
    --username alice --password s3cr3t \
    --branches-path branches \
    --tags-path tags \
    --log-limit 10000 \
    --output report.csv \
    --log-file run.log
```

---

## Internal Architecture

### Module layout

```
svn_inventory.py          # Single-file script — all logic is self-contained
```

### Key functions

| Function                                     | Purpose                                                                                                                             |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `run_svn(cmd, timeout)`                      | Executes any SVN CLI command, captures stdout, handles errors and timeouts. Returns `None` on failure. Exits if `svn` is not found. |
| `build_auth_flags(username, password)`       | Constructs authentication and `--non-interactive` flags for SVN commands.                                                           |
| `format_size(size_bytes)`                    | Converts a byte count to a human-readable string (e.g., `1.23 GB`). Supports B, KB, MB, GB, TB, PB.                                 |
| `get_repo_info(repo_url, auth)`              | Calls `svn info --xml` and parses revision, root, and UUID.                                                                         |
| `count_direct_children(url, auth)`           | Calls `svn list --xml` to count and list immediate children at a URL. Used for both branches and tags.                              |
| `get_size_and_large_files(repo_url, auth)`   | Calls `svn list --depth infinity --xml` to compute total size and find files ≥ 100 MiB.                                             |
| `count_merge_commits(repo_url, auth, limit)` | Calls `svn log --xml -v` and applies two heuristics to count merge commits.                                                         |
| `write_csv_report(...)`                      | Writes the collected metrics and large-file details to a CSV file.                                                                  |
| `main()`                                     | Entry point — orchestrates argument parsing, logging setup, step execution, and output.                                             |

### Execution flow

```
main()
 ├─ Parse CLI arguments
 ├─ Build authentication flags
 ├─ Configure logging (stderr + optional file)
 ├─ Print report header
 │
 ├─ Step 1: get_repo_info()          →  svn info --xml
 ├─ Step 2: count_direct_children()  →  svn list --xml  (branches)
 ├─ Step 3: count_direct_children()  →  svn list --xml  (tags)
 ├─ Step 4: count_merge_commits()    →  svn log --xml -v
 ├─ Step 5: get_size_and_large_files()  →  svn list --depth infinity --xml
 │           (skipped if --skip-size)
 │
 ├─ Print SUMMARY block
 └─ write_csv_report()  (if --output specified)
```

### Error handling

| Scenario                          | Behaviour                                                              |
| --------------------------------- | ---------------------------------------------------------------------- |
| `svn` not found on PATH           | Script exits immediately with an error message.                        |
| SVN command fails (non-zero exit) | Warning logged; the step returns `None`/zero and the script continues. |
| Command times out                 | Error logged; the step returns `None`/zero and the script continues.   |
| XML parse error                   | Warning logged; partial results may be returned.                       |
| Unreachable URL / auth failure    | SVN returns non-zero; handled as a command failure (see above).        |

---

## Troubleshooting

| Problem                         | Solution                                                                                                                                                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `'svn' command not found`       | Install the SVN CLI client. On Windows, install [TortoiseSVN](https://tortoisesvn.net/) (with CLI tools) or [SlikSVN](https://sliksvn.com/). On Linux: `sudo apt install subversion`. On macOS: `brew install svn`. |
| `E170001: Authorization failed` | Provide `--username` and `--password`, or ensure your SVN credentials are cached.                                                                                                                                   |
| Script hangs on Step 5          | The file-size scan can be very slow for large repos. Use `--skip-size` or wait for the 30-minute timeout.                                                                                                           |
| `Command timed out`             | The default timeout is 600s (Steps 1–3) or 1800s (Steps 4–5). Consider using `--log-limit` or `--skip-size`.                                                                                                        |
| Merge count seems high          | Heuristic #2 (property-mod detection) may count non-merge property edits. Use `--log-limit` to narrow the window and manually verify.                                                                               |
| CSV file not generated          | Ensure you pass `--output <filename>.csv`.                                                                                                                                                                          |

---

## License

This project is provided as-is for internal inventory and migration planning purposes.
