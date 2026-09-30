<#
.SYNOPSIS
    把工作区里的报告收集到本仓库，重建索引，然后提交并推送。

.DESCRIPTION
    四步：
      ① 按 tools\config.json 的映射，把源文件复制/更新到 docs/ 下
      ② 重新生成 README.md 索引（扫描 docs/ 自动生成，别手改）
      ③ git add -A，有变更才提交
      ④ git push（加 -NoPush 可跳过）

.EXAMPLE
    .\tools\sync.ps1                     # 收集 + 索引 + 提交 + 推送
    .\tools\sync.ps1 -NoPush             # 只到提交为止
    .\tools\sync.ps1 -Message "补充说明"   # 自定义提交信息
#>
[CmdletBinding()]
param(
    [switch]$NoPush,
    [string]$Message
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CfgPath  = Join-Path $RepoRoot 'tools\config.json'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

if (-not (Test-Path $CfgPath)) { throw "找不到配置：$CfgPath" }
$cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

$script:GitExe = $cfg.gitExe
if (-not (Test-Path $script:GitExe)) { throw "找不到 git：$($cfg.gitExe)`n（改 tools\config.json 里的 gitExe）" }

# git 会往 stderr 写进度和警告，而 PowerShell 在 ErrorActionPreference=Stop 下
# 会把原生命令的 stderr 当成异常抛出。这个包装把它降级成普通文本。
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $script:GitExe @GitArgs 2>&1
        return @($out | ForEach-Object { "$_" })
    } finally {
        $ErrorActionPreference = $prev
    }
}

$enc = New-Object System.Text.UTF8Encoding($false)

# ============================================================ ① 收集
Say "`n[1/4] 收集报告" 'Yellow'
$missing = @()
$copied  = 0
foreach ($m in $cfg.mappings) {
    $src = Join-Path $cfg.sourceRoot $m.source
    $dst = Join-Path $RepoRoot      $m.target

    if (-not (Test-Path $src)) { $missing += $m.source; continue }

    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }

    # 内容有变化才写（避免无意义的 git 变更）
    $newText = [System.IO.File]::ReadAllText($src, $enc)
    $oldText = if (Test-Path $dst) { [System.IO.File]::ReadAllText($dst, $enc) } else { $null }
    if ($newText -ne $oldText) {
        [System.IO.File]::WriteAllText($dst, $newText, $enc)
        Say ("  + " + $m.source + "  ->  " + $m.target)
        $copied++
    }
}
Say ("  更新 $copied 个文件" + $(if ($missing.Count -gt 0) { "，$($missing.Count) 个源文件不存在" } else { "" }))
foreach ($x in $missing) { Say ("  ! 缺失: " + $x) 'DarkYellow' }

# ============================================================ ② 索引
Say "`n[2/4] 生成 README 索引" 'Yellow'

function Get-Title([string]$path) {
    foreach ($line in [System.IO.File]::ReadAllLines($path, $enc)) {
        if ($line -match '^#\s+(.+)$') { return $Matches[1].Trim() }
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($path)
}

function Get-Summary([string]$path) {
    $lines = [System.IO.File]::ReadAllLines($path, $enc)
    $buf = @()
    $inCode = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -like '```*') { $inCode = -not $inCode; continue }
        if ($inCode) { continue }
        if ($t -eq '') { if ($buf.Count -gt 0) { break } else { continue } }
        if ($t -like '#*' -or $t -like '>*' -or $t -like '|*' -or $t -like '---*') {
            if ($buf.Count -gt 0) { break } else { continue }
        }
        $buf += $t
    }
    $s = ($buf -join ' ')
    $s = $s -replace '\*\*', '' -replace '`', ''
    if ($s.Length -gt 90) { $s = $s.Substring(0, 90) + '…' }
    return $s
}

$docsDir = Join-Path $RepoRoot 'docs'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# 技术报告集')
[void]$sb.AppendLine()
[void]$sb.AppendLine('> 本仓库由 `tools/sync.ps1` 自动同步生成，请勿直接手改文件。')
[void]$sb.AppendLine('> 最后同步：' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
[void]$sb.AppendLine()

$totalFiles = 0
if (Test-Path $docsDir) {
    foreach ($g in (Get-ChildItem $docsDir -Directory | Sort-Object Name)) {
        $groupName = $g.Name
        if ($cfg.titles -and ($cfg.titles.PSObject.Properties.Name -contains $groupName)) {
            $groupName = $cfg.titles.$groupName
        }
        [void]$sb.AppendLine("## $groupName")
        [void]$sb.AppendLine()
        foreach ($f in (Get-ChildItem $g.FullName -File -Filter '*.md' | Sort-Object Name)) {
            $rel   = 'docs/' + $g.Name + '/' + $f.Name
            $title = Get-Title $f.FullName
            $sum   = Get-Summary $f.FullName
            $line  = "- [$title]($rel)"
            if ($sum) { $line += " — $sum" }
            [void]$sb.AppendLine($line)
            $totalFiles++
        }
        [void]$sb.AppendLine()
    }
    $loose = Get-ChildItem $docsDir -File -Filter '*.md'
    if ($loose) {
        [void]$sb.AppendLine('## 其他')
        [void]$sb.AppendLine()
        foreach ($f in $loose) {
            [void]$sb.AppendLine("- [$(Get-Title $f.FullName)](docs/$($f.Name))")
            $totalFiles++
        }
        [void]$sb.AppendLine()
    }
}
[void]$sb.AppendLine('---')
[void]$sb.AppendLine()
[void]$sb.AppendLine("共 $totalFiles 篇。")

[System.IO.File]::WriteAllText((Join-Path $RepoRoot 'README.md'), $sb.ToString(), $enc)
Say "  索引已重建（$totalFiles 篇）"

# ============================================================ ③ 提交
Say "`n[3/4] 提交" 'Yellow'
Set-Location $RepoRoot

if (-not (Test-Path (Join-Path $RepoRoot '.git'))) {
    Say "  还不是 git 仓库，正在初始化..."
    Invoke-Git init -b $cfg.branch | ForEach-Object { "    $_" }
    Invoke-Git config core.autocrlf false | Out-Null
    Invoke-Git config core.safecrlf false  | Out-Null
    Invoke-Git config core.quotepath false | Out-Null
    Say "  已初始化（branch=$($cfg.branch)，已关闭换行符转换与路径转义）"
}

Invoke-Git add -A | Out-Null
$staged = Invoke-Git diff --cached --name-only
if (-not $staged -or $staged.Count -eq 0) {
    Say "  没有变更，跳过提交" 'DarkYellow'
} else {
    Say ("  变更 " + $staged.Count + " 个文件")
    $msg = if ($Message) { $Message } else { "同步报告 " + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    Invoke-Git commit -m $msg | ForEach-Object { "    $_" }
}

# ============================================================ ④ 推送
if ($NoPush) { Say "`n[4/4] 已跳过推送（-NoPush）" 'DarkYellow'; return }

Say "`n[4/4] 推送" 'Yellow'
$remotes = Invoke-Git remote
if (-not $remotes -or $remotes.Count -eq 0) {
    Say "  远端仓库还没配置。" 'Red'
    Say "  两种做法（任选）：" 'Yellow'
    Say "    A. 编辑 tools\config.json，把 remote 填成你的仓库地址，再跑一次本脚本"
    Say "    B. 先手动加一次："
    Say "       & `"$($cfg.gitExe)`" remote add origin <你的仓库地址>"
    return
}

$branch = (Invoke-Git rev-parse --abbrev-ref HEAD) -join ''
Say "  远端: $($remotes -join ', ')   分支: $branch"
$pushOut = Invoke-Git push -u origin $branch
$pushOut | ForEach-Object { "    $_" }
if (($pushOut -join "`n") -match 'fatal|error|denied|rejected') {
    Say "  ✗ 推送失败（多半是没配认证，见 tools\认证说明.md）" 'Red'
} else {
    Say "  ✓ 推送完成" 'Green'
}
