#!/usr/bin/env pwsh
# =====================================================================
# SVN Repository Inventory Script (PowerShell, offline friendly)
# ---------------------------------------------------------------------
# Collects statistics for a given SVN repository:
#   1. Total repository size (bytes of all files)
#   2. Total number of branches
#   3. Total number of tags
#   4. Total number of merge commits (heuristic)
#   5. Total number of files larger than 100 MiB
#
# Requirements (no internet downloads needed):
#   - PowerShell 5.1+ or PowerShell 7+
#   - svn command-line client on PATH
#
# Usage:
#   ./svn_inventory.ps1 -RepoUrl <repo_url> [options]
#
# Options:
#   -Username USER           SVN username
#   -Password PASS           SVN password
#   -BranchesPath PATH       Relative sub-path for branches (default: branches)
#   -TagsPath PATH           Relative sub-path for tags     (default: tags)
#   -LogLimit N              Limit merge scan to last N revisions
#   -SkipSize                Skip file-size scan (fast mode)
#   -OutputCsv FILE          Write CSV report to FILE
#   -LogFile FILE            Write log messages to FILE (in addition to stderr)
#   -Help                    Show help and exit
# =====================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RepoUrl,

    [Parameter(Mandatory = $false)]
    [string]$Username = "",

    [Parameter(Mandatory = $false)]
    [string]$Password = "",

    [Parameter(Mandatory = $false)]
    [string]$BranchesPath = "branches",

    [Parameter(Mandatory = $false)]
    [string]$TagsPath = "tags",

    [Parameter(Mandatory = $false)]
    [Nullable[int]]$LogLimit,

    [Parameter(Mandatory = $false)]
    [switch]$SkipSize,

    [Parameter(Mandatory = $false)]
    [string]$OutputCsv = "",

    [Parameter(Mandatory = $false)]
    [string]$LogFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LargeFileThreshold = 100MB
$Separator = "================================================================"

function Show-Usage {
    @"
SVN Repository Inventory Script (PowerShell)

Usage:
  ./svn_inventory.ps1 -RepoUrl <repo_url> [options]

Options:
  -Username USER           SVN username
  -Password PASS           SVN password
  -BranchesPath PATH       Relative sub-path for branches (default: branches)
  -TagsPath PATH           Relative sub-path for tags     (default: tags)
  -LogLimit N              Limit merge scan to last N revisions
  -SkipSize                Skip file-size scan (fast mode)
  -OutputCsv FILE          Write CSV report to FILE
  -LogFile FILE            Write log messages to FILE (in addition to stderr)
  -Help                    Show help and exit
"@
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "{0}  {1,-8} {2}" -f $ts, $Level, $Message
    [Console]::Error.WriteLine($line)

    if (-not [string]::IsNullOrWhiteSpace($script:LogFile)) {
        Add-Content -LiteralPath $script:LogFile -Value $line
    }
}

function Write-Info { param([string]$Message) Write-Log -Level "INFO" -Message $Message }
function Write-Warn { param([string]$Message) Write-Log -Level "WARNING" -Message $Message }
function Write-Crit { param([string]$Message) Write-Log -Level "CRITICAL" -Message $Message }

function Format-Size {
    param([Parameter(Mandatory = $true)][double]$Bytes)

    $units = @("B", "KB", "MB", "GB", "TB", "PB")
    $value = [double]$Bytes
    $index = 0

    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value /= 1024
        $index += 1
    }

    return "{0:N2} {1}" -f $value, $units[$index]
}

function Format-Int {
    param([Parameter(Mandatory = $true)][long]$Value)
    return "{0:N0}" -f $Value
}

function Quote-Csv {
    param([Parameter(Mandatory = $true)][string]$Value)
    $escaped = $Value -replace '"', '""'
    return '"' + $escaped + '"'
}

function Get-AuthFlags {
    $flags = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($script:Username)) {
        $flags.Add("--username")
        $flags.Add($script:Username)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:Password)) {
        $flags.Add("--password")
        $flags.Add($script:Password)
    }

    if ((-not [string]::IsNullOrWhiteSpace($script:Username)) -or (-not [string]::IsNullOrWhiteSpace($script:Password))) {
        $flags.Add("--no-auth-cache")
        $flags.Add("--non-interactive")
    }

    return ,$flags.ToArray()
}

function Invoke-Svn {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $allArgs = @($Arguments + $script:AuthFlags)

    # Native commands that write to stderr would otherwise be turned into
    # terminating errors by the script-wide $ErrorActionPreference='Stop'.
    # We rely on $LASTEXITCODE to detect real failures, so locally relax
    # the policy and merge stderr into stdout for capture. Use
    # SilentlyContinue so the merged stderr records are not also re-emitted
    # to the host as red NativeCommandError messages.
    $previousEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $output = (& svn @allArgs 2>&1) | Out-String
    }
    finally {
        $ErrorActionPreference = $previousEAP
    }

    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $trimmed = ($output -replace "\r", "").Trim()
        if ($trimmed.Length -gt 2000) {
            $trimmed = $trimmed.Substring(0, 2000)
        }
        if ($trimmed.Length -eq 0) {
            $trimmed = "svn command failed with exit code $exitCode"
        }
        Write-Warn $trimmed

        if ($AllowFailure) {
            return $null
        }

        throw "svn command failed: svn $($Arguments -join ' ')"
    }

    return ($output -replace "\r", "").Trim()
}

function Get-RepoInfo {
    $xmlText = Invoke-Svn -Arguments @("info", "--xml", $script:RepoUrl) -AllowFailure
    if ([string]::IsNullOrWhiteSpace($xmlText)) {
        return $null
    }

    try {
        [xml]$xml = $xmlText
    }
    catch {
        Write-Warn "Unable to parse svn info XML output."
        return $null
    }

    $entry = $xml.info.entry
    if ($null -eq $entry) {
        return $null
    }

    $revision = [string]$entry.revision
    if ([string]::IsNullOrWhiteSpace($revision)) { $revision = "?" }

    $root = [string]$entry.repository.root
    if ([string]::IsNullOrWhiteSpace($root)) { $root = "?" }

    $uuid = [string]$entry.repository.uuid
    if ([string]::IsNullOrWhiteSpace($uuid)) { $uuid = "?" }

    return [pscustomobject]@{
        Revision = $revision
        Root = $root
        Uuid = $uuid
    }
}

function Get-DirectChildren {
    param([Parameter(Mandatory = $true)][string]$Url)

    $xmlText = Invoke-Svn -Arguments @("list", "--xml", $Url) -AllowFailure
    if ([string]::IsNullOrWhiteSpace($xmlText)) {
        return [pscustomobject]@{ Count = 0; Names = @() }
    }

    try {
        [xml]$xml = $xmlText
    }
    catch {
        Write-Warn "Unable to parse svn list XML output for: $Url"
        return [pscustomobject]@{ Count = 0; Names = @() }
    }

    $names = New-Object System.Collections.Generic.List[string]
    $entries = $xml.SelectNodes("//entry")
    if ($null -ne $entries) {
        foreach ($entry in $entries) {
            $name = [string]$entry.name
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $names.Add($name)
            }
        }
    }

    $uniqueArr = @($names | Sort-Object -Unique)
    return [pscustomobject]@{
        Count = $uniqueArr.Count
        Names = $uniqueArr
    }
}

function Get-SizeAndLargeFiles {
    $xmlText = Invoke-Svn -Arguments @("list", "--depth", "infinity", "--xml", $script:RepoUrl) -AllowFailure
    if ([string]::IsNullOrWhiteSpace($xmlText)) {
        return [pscustomobject]@{
            TotalSize = [int64]0
            LargeFiles = @()
            LargeCount = 0
        }
    }

    try {
        [xml]$xml = $xmlText
    }
    catch {
        Write-Warn "Unable to parse svn list --depth infinity XML output."
        return [pscustomobject]@{
            TotalSize = [int64]0
            LargeFiles = @()
            LargeCount = 0
        }
    }

    [int64]$totalSize = 0
    $largeFiles = New-Object System.Collections.Generic.List[object]
    $entries = $xml.SelectNodes("//entry[@kind='file']")

    if ($null -ne $entries) {
        foreach ($entry in $entries) {
            $sizeText = [string]$entry.size
            if ([string]::IsNullOrWhiteSpace($sizeText)) {
                continue
            }

            [int64]$size = 0
            if (-not [int64]::TryParse($sizeText, [ref]$size)) {
                continue
            }

            $totalSize += $size
            if ($size -ge $script:LargeFileThreshold) {
                $path = [string]$entry.name
                $largeFiles.Add([pscustomobject]@{
                    Size = $size
                    Path = $path
                })
            }
        }
    }

    $sortedLarge = @($largeFiles | Sort-Object -Property Size -Descending)

    return [pscustomobject]@{
        TotalSize = $totalSize
        LargeFiles = $sortedLarge
        LargeCount = $sortedLarge.Count
    }
}

function Test-MergeByKeyword {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message = ""
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return [regex]::IsMatch($Message.ToLowerInvariant(), '(^|[^a-z0-9_])merge(d)?([^a-z0-9_]|$)')
}

function Get-MergeStats {
    $svnArgs = New-Object System.Collections.Generic.List[string]
    $svnArgs.Add("log")
    $svnArgs.Add("--xml")
    $svnArgs.Add("-v")
    $svnArgs.Add($script:RepoUrl)

    if ($null -ne $script:LogLimit -and $script:LogLimit -gt 0) {
        $svnArgs.Add("-l")
        $svnArgs.Add([string]$script:LogLimit)
    }

    $xmlText = Invoke-Svn -Arguments $svnArgs.ToArray() -AllowFailure
    if ([string]::IsNullOrWhiteSpace($xmlText)) {
        return [pscustomobject]@{ TotalCommits = 0; MergeCommits = 0 }
    }

    try {
        [xml]$xml = $xmlText
    }
    catch {
        Write-Warn "Unable to parse svn log XML output."
        return [pscustomobject]@{ TotalCommits = 0; MergeCommits = 0 }
    }

    $entries = $xml.SelectNodes("//logentry")
    if ($null -eq $entries) {
        return [pscustomobject]@{ TotalCommits = 0; MergeCommits = 0 }
    }

    $total = 0
    $merges = 0

    foreach ($entry in $entries) {
        $total += 1
        $isMerge = $false

        $paths = $null
        try { $paths = $entry.SelectNodes("paths/path") } catch { $paths = $null }
        if ($null -ne $paths) {
            foreach ($pathNode in $paths) {
                $propMods = ""
                $attr = $pathNode.Attributes["prop-mods"]
                if ($null -ne $attr) {
                    $propMods = [string]$attr.Value
                }
                if ($propMods -eq "true") {
                    $isMerge = $true
                    break
                }
            }
        }

        if (-not $isMerge) {
            $msg = ""
            try { $msg = [string]$entry.msg } catch { $msg = "" }
            if (-not [string]::IsNullOrEmpty($msg)) {
                if (Test-MergeByKeyword -Message $msg) {
                    $isMerge = $true
                }
            }
        }

        if ($isMerge) {
            $merges += 1
        }
    }

    return [pscustomobject]@{
        TotalCommits = $total
        MergeCommits = $merges
    }
}

function Show-TopNames {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Names = @(),
        [int]$Limit = 10
    )

    $total = @($Names).Count
    if ($total -eq 0) {
        return
    }

    $shown = [Math]::Min($Limit, $total)
    for ($i = 0; $i -lt $shown; $i++) {
        Write-Host ("    - {0}" -f $Names[$i])
    }

    if ($total -gt $shown) {
        Write-Host ("    ... and {0} more" -f ($total - $shown))
    }
}

function Write-CsvReport {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$HaveInfo,
        [Parameter(Mandatory = $true)][object]$Info,
        [Parameter(Mandatory = $true)][int]$BranchCount,
        [Parameter(Mandatory = $true)][int]$TagCount,
        [Parameter(Mandatory = $true)][int]$TotalCommits,
        [Parameter(Mandatory = $true)][int]$MergeCommits,
        [Parameter(Mandatory = $true)][bool]$HaveSize,
        [Parameter(Mandatory = $true)][int64]$TotalSize,
        [Parameter(Mandatory = $true)][int]$LargeCount,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$LargeFiles
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(("{0},{1}" -f (Quote-Csv "Metric"), (Quote-Csv "Value")))

    if ($HaveInfo) {
        $lines.Add(("{0},{1}" -f (Quote-Csv "Latest Revision"), (Quote-Csv ("r{0}" -f $Info.Revision))))
        $lines.Add(("{0},{1}" -f (Quote-Csv "Repository Root"), (Quote-Csv ([string]$Info.Root))))
        $lines.Add(("{0},{1}" -f (Quote-Csv "Repository UUID"), (Quote-Csv ([string]$Info.Uuid))))
    }

    $lines.Add(("{0},{1}" -f (Quote-Csv "Total Branches"), (Quote-Csv ([string]$BranchCount))))
    $lines.Add(("{0},{1}" -f (Quote-Csv "Total Tags"), (Quote-Csv ([string]$TagCount))))
    $lines.Add(("{0},{1}" -f (Quote-Csv "Total Commits"), (Quote-Csv ([string]$TotalCommits))))
    $lines.Add(("{0},{1}" -f (Quote-Csv "Merge Commits"), (Quote-Csv ([string]$MergeCommits))))

    if ($HaveSize) {
        $lines.Add(("{0},{1}" -f (Quote-Csv "Total Repository Size (bytes)"), (Quote-Csv ([string]$TotalSize))))
        $lines.Add(("{0},{1}" -f (Quote-Csv "Total Repository Size"), (Quote-Csv (Format-Size -Bytes $TotalSize))))
        $lines.Add(("{0},{1}" -f (Quote-Csv "Files > 100 MiB"), (Quote-Csv ([string]$LargeCount))))
    }

    if (@($LargeFiles).Count -gt 0) {
        $lines.Add("")
        $lines.Add((Quote-Csv "Large Files (> 100 MiB)"))
        $lines.Add(("{0},{1},{2}" -f (Quote-Csv "Path"), (Quote-Csv "Size (bytes)"), (Quote-Csv "Size (human-readable)")))

        foreach ($file in $LargeFiles) {
            $lines.Add(("{0},{1},{2}" -f (Quote-Csv ([string]$file.Path)), (Quote-Csv ([string]$file.Size)), (Quote-Csv (Format-Size -Bytes ([double]$file.Size)))))
        }
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
    Write-Info "CSV report written -> $Path"
}

if ($Help) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    [Console]::Error.WriteLine("Error: -RepoUrl is required.")
    Show-Usage
    exit 1
}

$RepoUrl = $RepoUrl.TrimEnd('/')

if (-not (Get-Command svn -ErrorAction SilentlyContinue)) {
    Write-Crit "'svn' command not found. Install the SVN command-line client and ensure it is on PATH."
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
    Set-Content -LiteralPath $LogFile -Value "" -Encoding UTF8
}

$script:RepoUrl = $RepoUrl
$script:Username = $Username
$script:Password = $Password
$script:BranchesPath = $BranchesPath
$script:TagsPath = $TagsPath
$script:LogLimit = $LogLimit
$script:OutputCsv = $OutputCsv
$script:LogFile = $LogFile
$script:LargeFileThreshold = $LargeFileThreshold
$script:AuthFlags = Get-AuthFlags

Write-Host $Separator
Write-Host "  SVN Repository Inventory Report"
Write-Host $Separator
Write-Host ("  Repository : {0}" -f $RepoUrl)
Write-Host ""
Write-Info "Inventory started for: $RepoUrl"

Write-Host "Step 1/5  Fetching repository metadata ..."
Write-Info "Step 1/5 - fetching repository metadata"

$haveInfo = $false
$repoInfo = Get-RepoInfo
if ($null -ne $repoInfo) {
    $haveInfo = $true
    Write-Host ("  Latest revision : r{0}" -f $repoInfo.Revision)
    Write-Host ("  Repository root : {0}" -f $repoInfo.Root)
    Write-Host ("  Repository UUID : {0}" -f $repoInfo.Uuid)
    Write-Info ("Metadata retrieved - revision: {0}, root: {1}, uuid: {2}" -f $repoInfo.Revision, $repoInfo.Root, $repoInfo.Uuid)
}
else {
    Write-Host "  (unable to retrieve repository metadata)"
    Write-Warn "Unable to retrieve repository metadata."
}
Write-Host ""

$branchesUrl = "{0}/{1}" -f $RepoUrl, $BranchesPath
Write-Host ("Step 2/5  Counting branches  ->  {0}" -f $branchesUrl)
Write-Info ("Step 2/5 - counting branches at: {0}" -f $branchesUrl)

$branches = Get-DirectChildren -Url $branchesUrl
$branchCount = [int]$branches.Count
Write-Host ("  Total branches  : {0}" -f $branchCount)
Write-Info ("Branch count: {0}" -f $branchCount)
Show-TopNames -Names $branches.Names
Write-Host ""

$tagsUrl = "{0}/{1}" -f $RepoUrl, $TagsPath
Write-Host ("Step 3/5  Counting tags  ->  {0}" -f $tagsUrl)
Write-Info ("Step 3/5 - counting tags at: {0}" -f $tagsUrl)

$tags = Get-DirectChildren -Url $tagsUrl
$tagCount = [int]$tags.Count
Write-Host ("  Total tags      : {0}" -f $tagCount)
Write-Info ("Tag count: {0}" -f $tagCount)
Show-TopNames -Names $tags.Names
Write-Host ""

$limitNote = " (all revisions)"
if ($null -ne $LogLimit -and $LogLimit -gt 0) {
    $limitNote = " (last {0} revisions)" -f $LogLimit
}
Write-Host ("Step 4/5  Scanning commit log for merges{0} ..." -f $limitNote)
Write-Info ("Step 4/5 - scanning commit log for merges{0}" -f $limitNote)

$mergeStats = Get-MergeStats
$totalCommits = [int]$mergeStats.TotalCommits
$mergeCount = [int]$mergeStats.MergeCommits
Write-Host ("  Total commits   : {0}" -f (Format-Int -Value $totalCommits))
Write-Host ("  Merge commits   : {0}" -f (Format-Int -Value $mergeCount))
Write-Info ("Commits: {0} total, {1} merges" -f $totalCommits, $mergeCount)
Write-Host ""

$haveSize = $false
[int64]$totalSize = 0
$largeCount = 0
$largeFiles = @()

if ($SkipSize) {
    Write-Host "Step 5/5  File-size scan skipped (-SkipSize)."
    Write-Info "Step 5/5 - file-size scan skipped."
}
else {
    Write-Host "Step 5/5  Scanning all files for sizes (this may take a while) ..."
    Write-Info ("Step 5/5 - scanning all files for sizes at: {0}" -f $RepoUrl)

    $sizeStats = Get-SizeAndLargeFiles
    $totalSize = [int64]$sizeStats.TotalSize
    $largeFiles = @($sizeStats.LargeFiles)
    $largeCount = [int]$sizeStats.LargeCount
    $haveSize = $true

    Write-Host ("  Total repo size  : {0}  ({1} bytes)" -f (Format-Size -Bytes $totalSize), (Format-Int -Value $totalSize))
    Write-Host ("  Files > 100 MiB  : {0}" -f $largeCount)
    Write-Info ("Size scan complete - total: {0} ({1} bytes), large files: {2}" -f (Format-Size -Bytes $totalSize), $totalSize, $largeCount)

    if ($largeFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "  Large files (descending size):"
        foreach ($file in $largeFiles) {
            $sizeLabel = (Format-Size -Bytes ([double]$file.Size)).PadLeft(14)
            Write-Host ("    {0}   {1}" -f $sizeLabel, $file.Path)
        }
    }
}

Write-Host ""
Write-Host $Separator
Write-Host "  SUMMARY"
Write-Host $Separator
if ($haveInfo) {
    Write-Host ("  {0,-30} r{1}" -f "Latest revision", $repoInfo.Revision)
}
Write-Host ("  {0,-30} {1}" -f "Total branches", (Format-Int -Value $branchCount))
Write-Host ("  {0,-30} {1}" -f "Total tags", (Format-Int -Value $tagCount))
Write-Host ("  {0,-30} {1}" -f "Total commits", (Format-Int -Value $totalCommits))
Write-Host ("  {0,-30} {1}" -f "Merge commits", (Format-Int -Value $mergeCount))
if ($haveSize) {
    Write-Host ("  {0,-30} {1}" -f "Total repository size", (Format-Size -Bytes $totalSize))
    Write-Host ("  {0,-30} {1}" -f "Files > 100 MiB", (Format-Int -Value $largeCount))
}
Write-Host $Separator

if (-not [string]::IsNullOrWhiteSpace($OutputCsv)) {
    Write-CsvReport -Path $OutputCsv `
        -HaveInfo $haveInfo `
        -Info $repoInfo `
        -BranchCount $branchCount `
        -TagCount $tagCount `
        -TotalCommits $totalCommits `
        -MergeCommits $mergeCount `
        -HaveSize $haveSize `
        -TotalSize $totalSize `
        -LargeCount $largeCount `
        -LargeFiles $largeFiles

    Write-Host ""
    Write-Host ("  CSV report written -> {0}" -f $OutputCsv)
}

Write-Info ("Inventory complete for: {0}" -f $RepoUrl)
exit 0
