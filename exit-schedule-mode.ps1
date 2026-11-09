<#
  影刀 —— 一键退出调度模式
  ============================================================
  作用：有任务在跑先停掉，然后切回 console（普通客户端）模式。
  适用：客户希望按一个快捷键就退出调度模式，不用手点控制台。

  流程：
    1) 读同目录 config.txt（云端停止接口用的密钥，可选）
    2) 自动定位 shadowbot.shell-cli.exe
    3) 查 system state：已经在 console 模式 → 直接结束
    4) 有任务在跑 → 用 jobUuid 调云端 job/stop → 轮询等它结束
    5) 执行 ui --exec switch-to-console
    6) 轮询 currentMode 直到变成 console（服务在重启，不能固定睡眠）

  参数：
    -Quiet  静默模式（快捷键 / 桌面快捷方式用）。失败时弹窗提示。

  退出码：
    0 = 成功退出调度模式
    1 = 切换失败（任务已停但模式没切过来）
    2 = 任务停不掉，无法切换（需要人工去控制台结束）
    3 = 环境问题（找不到 CLI / 查不到状态）
#>

param([switch]$Quiet)

$ErrorActionPreference = 'Continue'

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 强制 TLS 1.2：老系统的 PowerShell 默认可能用 TLS 1.0/1.1，
# 调 api.yingdao.com 会直接握手失败（换到别的电脑上最常踩的坑之一）。
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $scriptDir 'config.txt'

# ============================ 配置 ============================
$AccessKeyId       = ''
$AccessKeySecret   = ''
$MaxWaitSeconds    = 45      # 停止指令发出后，最多等任务结束多少秒
$PollIntervalSec   = 3       # 轮询间隔
$SwitchTimeoutSec  = 20      # 切模式后最多等多久让状态真正变过来（轮询探测，不做固定睡眠）
$SwitchPollMs      = 800     # 轮询间隔
$ApiBase           = 'https://api.yingdao.com'

if (Test-Path $configFile) {
    Get-Content -Path $configFile -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
        $line = $_.Trim()
        if ($line -ne '' -and -not $line.StartsWith('#') -and $line.Contains('=')) {
            $idx = $line.IndexOf('=')
            $k = $line.Substring(0, $idx).Trim()
            $v = $line.Substring($idx + 1).Trim()
            switch ($k) {
                'accessKeyId'     { $AccessKeyId = $v }
                'accessKeySecret' { $AccessKeySecret = $v }
                'maxWaitSeconds'  { $n = 0; if ([int]::TryParse($v, [ref]$n)) { $MaxWaitSeconds = $n } }
                'switchTimeoutSeconds' { $n = 0; if ([int]::TryParse($v, [ref]$n)) { $SwitchTimeoutSec = $n } }
            }
        }
    }
}

# ============================ 输出 ============================

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Gray }
function Write-Ok($msg)   { Write-Host "[成功] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "[提示] $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "[失败] $msg" -ForegroundColor Red }

# 把内部模式名翻译成客户能看懂的说法（不要向外暴露 console / assistant）
function Get-ModeLabel($m) {
    if ($m -eq 'console')   { return '普通客户端（未在调度）' }
    if ($m -eq 'assistant') { return '调度模式' }
    if ($m) { return "未知状态" }
    return '未知'
}

# 静默模式（快捷键触发）下，失败必须弹窗，否则客户根本不知道没退成功
function Show-Fail($msg) {
    if (-not $Quiet) { return }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $ws.Popup($msg, 25, '影刀：退出调度未成功', 48) | Out-Null
    } catch { }
}

# ============================ 工具函数 ============================

function Find-ShadowBotCli {
    # 1) 已经在 PATH 里
    $cmd = Get-Command 'shadowbot.shell-cli.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2) 从正在运行的 ShadowBot.Shell.exe 反推安装目录（最准）
    $proc = Get-Process -Name 'ShadowBot.Shell' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc -and $proc.Path) {
        $exeDir = Split-Path -Parent $proc.Path
        foreach ($d in @($exeDir, (Split-Path -Parent $exeDir))) {
            $p = Join-Path $d 'shadowbot.shell-cli.exe'
            if (Test-Path $p) { return $p }
        }
        # 往子目录（shadowbot-x.x.x）再找一层
        $sub = Get-ChildItem -Path $exeDir -Filter 'shadowbot.shell-cli.exe' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sub) { return $sub.FullName }
    }

    # 3) 扫常见安装根目录
    $roots = @(
        (Join-Path $env:ProgramFiles 'ShadowBot'),
        (Join-Path ${env:ProgramFiles(x86)} 'ShadowBot'),
        (Join-Path $env:LOCALAPPDATA 'ShadowBot'),
        (Join-Path $env:APPDATA 'ShadowBot'),
        'D:\installed_apps\ShadowBot',
        'C:\ShadowBot',
        'D:\Program Files\ShadowBot',
        'D:\Program Files (x86)\ShadowBot'
    )
    foreach ($r in $roots) {
        if ($r -and (Test-Path $r)) {
            $hit = Get-ChildItem -Path $r -Filter 'shadowbot.shell-cli.exe' -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Get-YdState($cli) {
    $raw = & $cli system state 2>$null
    if (-not $raw) { return $null }
    try { return (($raw -join "`n") | ConvertFrom-Json) } catch { return $null }
}

function Get-YdToken($ak, $sk) {
    $url = "$ApiBase/oapi/token/v2/token/create?accessKeyId=$([uri]::EscapeDataString($ak))&accessKeySecret=$([uri]::EscapeDataString($sk))"
    try {
        $r = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
        if ($r -and $r.code -eq 200 -and $r.data -and $r.data.accessToken) { return $r.data.accessToken }
        if ($r -and $r.code) { Write-Step "获取 token 失败，返回 code=$($r.code) msg=$($r.msg)" }
    } catch {
        Write-Step "获取 token 异常：$($_.Exception.Message)"
    }
    return $null
}

function Invoke-YdStopApi($path, $fieldName, $fieldValue, $token) {
    $headers = @{
        'Authorization' = "Bearer $token"
        'Content-Type'  = 'application/json'
    }
    $json  = "{`"$fieldName`":`"$fieldValue`"}"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    try {
        $r = Invoke-RestMethod -Uri "$ApiBase$path" -Method Post -Headers $headers -Body $bytes -TimeoutSec 20
        if ($r.success -eq $true) {
            Write-Step "云端已接受停止指令"
        } else {
            Write-Step "云端返回: code=$($r.code) $($r.msg)"        }
        return ($r.success -eq $true)
    } catch {
        Write-Step "停止请求异常：$($_.Exception.Message)"
        return $false
    }
}

# ============================ 主流程 ============================

Write-Host ""
Write-Host "===== 影刀：退出调度模式 =====" -ForegroundColor Cyan
Write-Host ""

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Warn2 "PowerShell 版本较低（$($PSVersionTable.PSVersion)），建议升级到 5.1 以上。"
}

$cli = Find-ShadowBotCli
if (-not $cli) {
    Write-Err2 "没找到 shadowbot.shell-cli.exe。"
    Write-Step "请确认影刀客户端已安装；或把 CLI 所在目录加入 PATH。"
    Show-Fail "找不到影刀命令行工具 shadowbot.shell-cli.exe。`n请确认影刀客户端已正确安装。"
    exit 3
}
Write-Step "影刀程序: $cli"

$state = Get-YdState $cli
if (-not $state -or -not $state.data) {
    Write-Err2 "无法读取影刀状态（system state 返回空）。"
    Write-Step "可能是客户端没启动，或 CLI 与客户端版本不匹配。"
    Show-Fail "读取不到影刀状态。`n请确认影刀客户端已经启动。"
    exit 3
}

$mode = $state.data.currentMode
Write-Step "当前模式: $(Get-ModeLabel $mode)"

if ($mode -eq 'console') {
    Write-Ok "当前不在调度模式，无需退出。"
    exit 0
}

# ---- 有任务在跑：先尝试停 ----
if ($state.data.hasRunningTask -eq $true) {
    $rt = $state.data.runningTask
    $taskId = $null
    $jobId  = $null
    if ($rt) {
        foreach ($f in @('taskId', 'taskUuid', 'id')) {
            if (-not $taskId -and $rt.$f) { $taskId = [string]$rt.$f; break }
        }
        foreach ($f in @('jobId', 'jobUuid')) {
            if (-not $jobId -and $rt.$f) { $jobId = [string]$rt.$f; break }
        }
        if ($rt.appName) { Write-Step "正在运行: $($rt.appName)" }
    }
    Write-Warn2 "检测到有任务正在运行，先尝试停止它（不停止无法退出调度）。"
    Write-Step "任务编号: $taskId"

    if ($AccessKeyId -and $AccessKeySecret) {
        $token = Get-YdToken $AccessKeyId $AccessKeySecret
        if ($token) {
            # 关键：runningTask.taskId 实际是平台侧的 jobUuid（不是 taskUuid）。
            # 依据：client/query 返回的 jobUuid 与 runningTask.taskId 完全相同；
            # 用 job/stop 传它，参数校验通过；用 task/stop 传它，报 "taskUuid参数错误"。
            $attempts = @()
            if ($jobId)  { $attempts += @{ path = '/oapi/dispatch/v2/job/stop';  field = 'jobUuid';  value = $jobId } }
            if ($taskId) { $attempts += @{ path = '/oapi/dispatch/v2/job/stop';  field = 'jobUuid';  value = $taskId } }
            if ($taskId) { $attempts += @{ path = '/oapi/dispatch/v2/task/stop'; field = 'taskUuid'; value = $taskId } }

            $stopped = $false
            foreach ($a in $attempts) {
                if (-not $a.value) { continue }
                $stopped = Invoke-YdStopApi $a.path $a.field $a.value $token
                if ($stopped) { break }
            }
            if (-not $stopped) {
                Write-Warn2 "自动停止没成功。这个任务可能是在本机手动启动的。"
            }
        } else {
            Write-Warn2 "密钥校验失败，跳过自动停止。请检查 config.txt。"
        }
    } else {
        Write-Warn2 "未配置密钥（见 config.txt），无法自动停止任务。"
        Write-Step "将只等待任务自然结束。"
    }

    # ---- 轮询等任务结束 ----
    Write-Step "等待任务结束 ..."
    $waited = 0
    while ($waited -lt $MaxWaitSeconds) {
        Start-Sleep -Seconds $PollIntervalSec
        $waited += $PollIntervalSec
        $s2 = Get-YdState $cli
        if (-not $s2 -or -not $s2.data) { continue }
        if ($s2.data.hasRunningTask -ne $true) { break }
        # 前 9 秒不提示进度：绝大多数任务几秒内就停了，不必刷屏
        if ($waited -ge 9) {
            Write-Step "  已等待 $waited 秒，任务仍在运行..."
        }
    }

    $s2 = Get-YdState $cli
    if ($s2 -and $s2.data -and $s2.data.hasRunningTask -eq $true) {
        Write-Err2 "任务仍在运行，暂时无法退出调度模式。"
        Write-Host ""
        Write-Host "  请用下面任一方式处理后再按一次快捷键：" -ForegroundColor Yellow
        Write-Host "   · 控制台 → 任务管理 → 执行记录 → 找到该任务 → 结束执行" -ForegroundColor Yellow
        Write-Host "   · 或等它自己跑完" -ForegroundColor Yellow
        Write-Host "   · 或在 config.txt 里配置 accessKeyId/accessKeySecret，让脚本自动停" -ForegroundColor Yellow
        Show-Fail "任务仍在运行，无法退出调度模式。`n`n请到控制台「任务管理 → 执行记录」结束该任务后，再按一次快捷键。`n`n（如需自动停止，请在 config.txt 里配置 API 密钥）"
        exit 2
    }
    Write-Ok "任务已结束。"
}

# ---- 切换模式 ----
Write-Step "正在退出调度模式 ..."
$switchRaw = & $cli ui --exec switch-to-console 2>$null
if ($switchRaw) {
    $joined = $switchRaw -join ' '
    if ($joined -match '4091' -or $joined -match 'task_running_switch_blocked') {
        Write-Err2 "还有任务在运行，无法退出调度模式。"
        Show-Fail "还有任务在运行，无法退出调度模式。`n请先结束任务再试一次。"
        exit 2
    }
}

# ---- 等待模式真正切换过来 ----
# 切换时客户端会停掉 assistant-restapi、再起 console-restapi，
# 这段时间查询会失败或读到旧值，所以必须轮询探测，不能靠固定睡眠。
$switchStart = Get-Date
$deadline    = $switchStart.AddSeconds($SwitchTimeoutSec)
$lastKnown   = $null
$readFails   = 0

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds $SwitchPollMs
    $snap = Get-YdState $cli
    if (-not $snap -or -not $snap.data) {
        $readFails++
        continue
    }
    $lastKnown = $snap.data.currentMode
    if ($lastKnown -eq 'console') { break }
}

$elapsed = [math]::Round(((Get-Date) - $switchStart).TotalSeconds, 1)

if ($lastKnown -eq 'console') {
    Write-Ok "已退出调度模式（用时 $elapsed 秒）。"
    exit 0
}

if ($lastKnown -eq $null) {
    Write-Err2 "切换后一直读不到状态（共 $readFails 次读取失败，耗时 $elapsed 秒）。"
    Write-Step "服务可能仍在重启。稍等几秒重跑一次，或手动在托盘菜单确认。"
    Show-Fail "切换后读不到客户端状态，耗时 $elapsed 秒仍未就绪。`n请稍等几秒重跑一次，或手动在托盘菜单确认是否已退出调度。"
    exit 1
}

Write-Err2 "切换未生效，等待 $elapsed 秒后仍处于调度模式。"
Write-Step "可再执行一次，或检查客户端是否被策略锁定。"
Show-Fail "切换未生效，等待 $elapsed 秒后仍处于调度模式。`n请稍后重试，或手动在客户端托盘菜单退出调度。"
exit 1
