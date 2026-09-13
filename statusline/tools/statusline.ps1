# talaka statusline — pipeline-aware status bar for Claude Code (Windows).
# Line 1 (always): agent | feature [STAGE] | context bar | cost | lines
# Line 2 (alerts): only rendered when something needs attention
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$stream = [Console]::OpenStandardInput()
$reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 8192)
$raw = $reader.ReadToEnd()
$reader.Dispose()
if (-not $raw) { exit }
$data = $raw | ConvertFrom-Json

# --- JSON fields ---
$model = if ($data.model.display_name) { $data.model.display_name } else { "?" }
$projectDir = if ($data.workspace.project_dir) { $data.workspace.project_dir } else { $data.workspace.current_dir }
$pct = if ($null -ne $data.context_window.used_percentage) { [math]::Floor([double]$data.context_window.used_percentage) } else { 0 }
$cost = if ($null -ne $data.cost.total_cost_usd) { [double]$data.cost.total_cost_usd } else { 0.0 }
$linesAdded = if ($null -ne $data.cost.total_lines_added) { [int]$data.cost.total_lines_added } else { 0 }
$linesRemoved = if ($null -ne $data.cost.total_lines_removed) { [int]$data.cost.total_lines_removed } else { 0 }

# Usage limits. Claude Code supplies these; -1 means "not present in the
# payload" so a genuine 0% still renders.
function Get-Pct($v) { if ($null -ne $v) { [math]::Floor([double]$v) } else { -1 } }
$lim5h    = Get-Pct $data.rate_limits.five_hour.used_percentage
$lim7d    = Get-Pct $data.rate_limits.seven_day.used_percentage
$limSpend = Get-Pct $data.rate_limits.spend_limit.used_percentage
$reset5h  = if ($null -ne $data.rate_limits.five_hour.resets_at) { [long]$data.rate_limits.five_hour.resets_at } else { 0 }
$reset7d  = if ($null -ne $data.rate_limits.seven_day.resets_at) { [long]$data.rate_limits.seven_day.resets_at } else { 0 }

function Format-Until([long]$at) {
    if ($at -le 0) { return "" }
    $delta = $at - [long][double]::Parse((Get-Date -UFormat %s))
    if ($delta -le 0) { return "" }
    if     ($delta -ge 86400) { return "$([math]::Floor($delta / 86400))d" }
    elseif ($delta -ge 3600)  { return "$([math]::Floor($delta / 3600))h" }
    else                      { return "$([math]::Floor($delta / 60))m" }
}

# --- Colors ---
$e = [char]27
$cyan    = "$e[36m"; $magenta = "$e[35m"; $green = "$e[32m"
$yellow  = "$e[33m"; $red     = "$e[31m"; $dim   = "$e[2m"
$bold    = "$e[1m";  $reset   = "$e[0m"

# --- Pipeline state ---
$tlkDir = Join-Path $projectDir ".tlk"
$activeAgent = $null
$slug = ""; $stage = ""; $featCount = 0; $featPath = ""

if (Test-Path $tlkDir) {
    $sessionState = Join-Path $tlkDir "SESSION-STATE.md"
    $activeFeature = ""

    if (Test-Path $sessionState) {
        $content = Get-Content $sessionState -Raw
        if ($content -match '(?m)^## Active agent\s*\r?\n(.+)') {
            $sa = $Matches[1].Trim()
            if ($sa -and $sa -notmatch '^\(none') {
                if (-not $activeAgent) { $activeAgent = $sa }
            }
        }
        if ($content -match '(?m)^## Active feature\s*\r?\n(.+)') {
            $af = $Matches[1].Trim()
            if ($af -and $af -notmatch '^\(none') { $activeFeature = $af }
        }
    }

    # Find active feature folder
    if ($activeFeature -and (Test-Path $activeFeature)) {
        $featPath = $activeFeature
    } else {
        $featuresDir = Join-Path $tlkDir "features"
        if (Test-Path $featuresDir) {
            $latest = Get-ChildItem $featuresDir -Directory |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($latest) { $featPath = $latest.FullName }
        }
    }

    # Count active features
    $featuresDir = Join-Path $tlkDir "features"
    if (Test-Path $featuresDir) {
        $featCount = @(Get-ChildItem $featuresDir -Directory).Count
    }

    # Determine pipeline stage
    if ($featPath -and (Test-Path $featPath)) {
        $slug = (Split-Path $featPath -Leaf) -replace '^\d{4}-\d{2}-\d{2}-',''
        $hasSpec = Test-Path (Join-Path $featPath "spec.md")
        $hasUx   = Test-Path (Join-Path $featPath "ux-design.md")
        $hasTech = Test-Path (Join-Path $featPath "tech-plan.md")

        if     (-not $hasSpec) { $stage = "SPEC" }
        elseif (-not $hasUx)   { $stage = "UX" }
        elseif (-not $hasTech) { $stage = "ARCH" }
        else                   { $stage = "BUILD/QA" }
    }
}

# === LINE 1: Compact always-visible bar ===
$l1 = ""

# Agent
if ($activeAgent) { $l1 = "${cyan}@${activeAgent}${reset}" }
else              { $l1 = "${dim}[${model}]${reset}" }

# Feature + stage
if ($slug) {
    $l1 += " ${dim}|${reset} ${magenta}${slug}${reset} ${dim}[${stage}]${reset}"
}

# Context bar (8-wide)
$barWidth = 8
$filled = [math]::Floor($pct * $barWidth / 100)
$empty = $barWidth - $filled
if     ($pct -lt 50) { $barColor = $green }
elseif ($pct -lt 80) { $barColor = $yellow }
else                  { $barColor = $red }
$filledStr = "$([char]0x2593)" * $filled
$emptyStr  = "$([char]0x2591)" * $empty
$bar = "${barColor}${filledStr}${dim}${emptyStr}${reset}"

# Cost + lines
$costFmt = '$' + $cost.ToString("F2")
$linesFmt = "${green}+${linesAdded}${reset}/${red}-${linesRemoved}${reset}"

$l1 += " ${dim}|${reset} ${bar} ${pct}% ${dim}|${reset} ${costFmt} ${dim}|${reset} ${linesFmt}"

# Usage limits — the tightest window, so one segment answers "how close am I to
# being cut off". Coloured by headroom, not by which window it came from.
$limWorst = -1; $limLabel = ""; $limReset = ""
if ($lim5h    -ge 0 -and $lim5h    -gt $limWorst) { $limWorst = $lim5h;    $limLabel = "5h";    $limReset = Format-Until $reset5h }
if ($lim7d    -ge 0 -and $lim7d    -gt $limWorst) { $limWorst = $lim7d;    $limLabel = "7d";    $limReset = Format-Until $reset7d }
if ($limSpend -ge 0 -and $limSpend -gt $limWorst) { $limWorst = $limSpend; $limLabel = "spend"; $limReset = "" }
if ($limWorst -ge 0) {
    if     ($limWorst -lt 50) { $limColor = $green }
    elseif ($limWorst -lt 80) { $limColor = $yellow }
    else                      { $limColor = $red }
    $limSeg = "${limColor}${limLabel} ${limWorst}%${reset}"
    if ($limReset) { $limSeg += "${dim}$([char]0x2192)${limReset}${reset}" }
    $l1 += " ${dim}|${reset} ${limSeg}"
}

Write-Host $l1

# === LINE 2: Conditional alerts ===
$alerts = @()

# --- Alert: usage limit running out ---
# Before the .tlk check below: running out of quota matters whether or not this
# project has the kit installed.
foreach ($lim in @(@("5h", $lim5h, $reset5h), @("7d", $lim7d, $reset7d), @("spend", $limSpend, 0))) {
    $lbl = $lim[0]; $p = [int]$lim[1]; $at = [long]$lim[2]
    if ($p -lt 80) { continue }
    $until = Format-Until $at
    $msg = "$lbl limit $p%"
    if ($until) { $msg += " (resets $until)" }
    if ($p -ge 95) { $alerts += "${red}${msg}${reset}" } else { $alerts += "${yellow}${msg}${reset}" }
}

function Write-Alerts($alerts) {
    if ($alerts.Count -eq 0) { return }
    $line2 = ""
    for ($i = 0; $i -lt $alerts.Count; $i++) {
        if ($i -gt 0) { $line2 += " ${dim}|${reset} " }
        $line2 += $alerts[$i]
    }
    Write-Host "${yellow}$([char]0x26A0)${reset} $line2"
}

# Everything below reads the kit's own state.
if (-not (Test-Path $tlkDir)) { Write-Alerts $alerts; exit }

# --- Alert: Memory stale (SESSION-STATE.md > 24h) ---
$ssPath = Join-Path $tlkDir "SESSION-STATE.md"
if (Test-Path $ssPath) {
    $mtime = (Get-Item $ssPath).LastWriteTime
    $ageHours = [math]::Floor(((Get-Date) - $mtime).TotalHours)
    if ($ageHours -ge 24) {
        $ageDays = [math]::Floor($ageHours / 24)
        $alerts += "${yellow}mem:stale ${ageDays}d${reset}"
    }
}

# --- Alert: Feature stuck (handoff-log.md > 48h) ---
if ($featPath -and (Test-Path $featPath)) {
    $handoff = Join-Path $featPath "handoff-log.md"
    if (Test-Path $handoff) {
        $hoMtime = (Get-Item $handoff).LastWriteTime
        $hoAgeH = [math]::Floor(((Get-Date) - $hoMtime).TotalHours)
        if ($hoAgeH -ge 48) {
            $hoAgeD = [math]::Floor($hoAgeH / 24)
            $alerts += "${red}${slug} STUCK ${hoAgeD}d${reset}"
        }
    }
}

# --- Alert: Yaga investigation active ---
$debugDir = Join-Path $tlkDir "debug"
if (Test-Path $debugDir) {
    $activeInv = Get-ChildItem $debugDir -Directory |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($activeInv) {
        $hypo     = Join-Path $activeInv.FullName "hypothesis.md"
        $instLog  = Join-Path $activeInv.FullName "instrumentation-log.md"
        $findings = Join-Path $activeInv.FullName "findings.md"

        $yagaPhase = "hypothesize"
        if ((Test-Path $hypo) -and (Get-Content $hypo | Measure-Object -Line).Lines -gt 5) {
            $yagaPhase = "instrument"
            if ((Test-Path $instLog) -and (Get-Content $instLog | Measure-Object -Line).Lines -gt 3) {
                $yagaPhase = "observe"
            }
            if ((Test-Path $findings) -and (Get-Content $findings | Measure-Object -Line).Lines -gt 3) {
                $yagaPhase = "strip"
            }
        }
        $alerts += "${cyan}yaga:${yagaPhase}${reset}"
    }
}

# --- Alert: Autoresearch ratchet status ---
$ratchetLog = Join-Path $tlkDir "autoresearch/runs/ratchet.jsonl"
$rejectedLog = Join-Path $tlkDir "autoresearch/runs/rejected.jsonl"
if (Test-Path $ratchetLog) {
    $accepted = (Get-Content $ratchetLog | Measure-Object -Line).Lines
    $rejected = 0
    if (Test-Path $rejectedLog) {
        $rejected = (Get-Content $rejectedLog | Measure-Object -Line).Lines
    }
    $gen = $accepted + $rejected
    $lastLine = Get-Content $ratchetLog | Select-Object -Last 1
    if ($lastLine) {
        try {
            $entry = $lastLine | ConvertFrom-Json
            $score = $entry.proposal_composite
            if ($null -ne $score) {
                $scoreFmt = ([double]$score).ToString("F2")
                $alerts += "${green}ratchet:gen${gen} `u{2191}${scoreFmt}${reset}"
            }
        } catch {}
    }
}

# --- Alert: Multiple active features ---
if ($featCount -gt 1) {
    $alerts += "${dim}${featCount} feats${reset}"
}

# Output line 2 only if alerts exist
Write-Alerts $alerts
