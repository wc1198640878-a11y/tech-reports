<#
.SYNOPSIS
    一次性设置：把本仓库接到你的 GitHub 远端。

.DESCRIPTION
    做三件事：
      ① 把远端地址写进 tools\config.json 并注册为 origin
      ② 自检 SSH 认证是否通了
      ③ 试推一次

    跑之前请先确认：已经把公钥加到 GitHub（见 首次设置.md 第 2 步）。

.EXAMPLE
    .\tools\setup.ps1 -RepoUrl git@github.com:你的用户名/仓库名.git
    .\tools\setup.ps1 -RepoUrl git@github.com:Itsuka/reports.git -SkipPush
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl,
    [switch]$SkipPush
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$CfgPath  = Join-Path $RepoRoot 'tools\config.json'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

$cfg     = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$gitExe  = $cfg.gitExe
$sshExe  = Join-Path (Split-Path -Parent (Split-Path -Parent $gitExe)) 'usr\bin\ssh.exe'
$known   = "$env:USERPROFILE\.ssh\known_hosts".Replace('\', '/')

if (-not (Test-Path $gitExe)) { throw "找不到 git：$gitExe" }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try   { return @(& $gitExe @GitArgs 2>&1 | ForEach-Object { "$_" }) }
    finally { $ErrorActionPreference = $prev }
}

Set-Location $RepoRoot

# ---------------------------------------------------------------- ① 写入配置 + remote
Say "`n[1/3] 配置远端" 'Yellow'

$raw = [System.IO.File]::ReadAllText($CfgPath, (New-Object System.Text.UTF8Encoding($false)))
$raw = [regex]::Replace($raw, '("remote"\s*:\s*")[^"]*(")', { param($m) $m.Groups[1].Value + $RepoUrl + $m.Groups[2].Value })
[System.IO.File]::WriteAllText($CfgPath, $raw, (New-Object System.Text.UTF8Encoding($false)))
Say "  已写入 tools\config.json 的 remote = $RepoUrl"

if (-not (Test-Path (Join-Path $RepoRoot '.git'))) {
    Invoke-Git init -b $cfg.branch | Out-Null
    Invoke-Git config core.autocrlf false | Out-Null
    Invoke-Git config core.quotepath false | Out-Null
    # 关键：不要设 core.sshCommand！git 会把它当 shell 命令执行，
    # Windows 路径里的反斜杠会被 sh 吃掉 → 找不到 ssh → 推送失败。
    # MinGit 自带 usr\bin\ssh.exe，git 会自动找到它。
    Invoke-Git config --unset core.sshCommand 2>&1 | Out-Null
    Say "  已初始化仓库"
}

$existing = Invoke-Git remote
if ($existing -contains 'origin') {
    Invoke-Git remote set-url origin $RepoUrl | Out-Null
    Say "  已更新 origin"
} else {
    Invoke-Git remote add origin $RepoUrl | Out-Null
    Say "  已添加 origin"
}

# ---------------------------------------------------------------- ② 测 SSH
Say "`n[2/3] 自检 SSH 认证" 'Yellow'
if ($RepoUrl -notmatch '^git@') {
    Say "  远端不是 SSH 地址（$RepoUrl），跳过 SSH 自检。" 'DarkYellow'
    Say "  若是 HTTPS 地址，推送时会要求输入用户名和 token。" 'DarkYellow'
} elseif (-not (Test-Path $sshExe)) {
    Say "  找不到 ssh.exe，跳过自检" 'DarkYellow'
} else {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    # BatchMode=yes + ConnectTimeout：任何需要交互的情况都直接失败，不会卡住
    $out = & $sshExe -o BatchMode=yes -o ConnectTimeout=10 `
                     -o UserKnownHostsFile="$known" -o StrictHostKeyChecking=accept-new `
                     -T git@github.com 2>&1
    $ErrorActionPreference = $prev
    $text = ($out | ForEach-Object { "$_" }) -join "`n"
    if ($text -match 'successfully authenticated') {
        Say "  ✓ SSH 认证通过" 'Green'
        Say ("    " + ($text -split "`n")[0])
    } elseif ($text -match 'Permission denied \(publickey\)') {
        Say "  ✗ 认证失败：GitHub 还不认识这把密钥" 'Red'
        Say "    请把下面这行公钥加到 GitHub（见 首次设置.md 第 2 步）：" 'Yellow'
        $pub = "$env:USERPROFILE\.ssh\id_ed25519.pub"
        if (Test-Path $pub) { Get-Content $pub -Encoding UTF8 | ForEach-Object { Say "      $_" 'Cyan' } }
        return
    } else {
        Say "  ? 无法判断，ssh 输出：" 'DarkYellow'
        $out | ForEach-Object { Say "    $_" }
    }
}

# ---------------------------------------------------------------- ③ 试推
if ($SkipPush) { Say "`n[3/3] 已跳过推送（-SkipPush）" 'DarkYellow'; return }

Say "`n[3/3] 试推一次" 'Yellow'
Say "  （如果远端仓库是新建的空仓库，这一步会直接成功；" 'DarkYellow'
Say "    如果远端已有内容，可能需要先 git pull --rebase）" 'DarkYellow'
Invoke-Git add -A | Out-Null
$staged = Invoke-Git diff --cached --name-only
if ($staged.Count -gt 0) {
    Invoke-Git commit -m "初始化报告仓库" | ForEach-Object { Say "    $_" }
}
$branch = (Invoke-Git rev-parse --abbrev-ref HEAD) -join ''
$pushOut = Invoke-Git push -u origin $branch
$pushOut | ForEach-Object { Say "    $_" }

if (($pushOut -join "`n") -match 'fatal|denied|rejected|error') {
    Say "`n  ✗ 推送失败，请看上面的 git 输出。" 'Red'
    Say "    常见原因：公钥没加、仓库不存在、或远端已有提交需要先合并。" 'Yellow'
} else {
    Say "`n  ✓ 完成！以后只要跑 tools\sync.ps1 就能一键同步。" 'Green'
}
