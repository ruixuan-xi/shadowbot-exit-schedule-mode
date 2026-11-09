<#
  影刀退出调度工具 —— 一键创建带快捷键的桌面快捷方式
  ============================================================
  运行方式（在文件所在目录打开 PowerShell，或右键「使用 PowerShell 运行」）：
      powershell -NoProfile -ExecutionPolicy Bypass -File .\create-shortcut.ps1
      powershell -NoProfile -ExecutionPolicy Bypass -File .\create-shortcut.ps1 -Hotkey "Ctrl+Alt+S"

  注意：脚本文本需保存为 UTF-8 with BOM，否则 Windows PowerShell 5.1 会把中文按 GBK 解析导致乱码。
#>

param(
    [string]$Hotkey = 'Ctrl+Alt+D'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bat  = Join-Path $here 'exit-schedule-mode.bat'

if (-not (Test-Path $bat)) {
    Write-Host "[失败] 同目录下找不到 exit-schedule-mode.bat" -ForegroundColor Red
    exit 1
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop '退出影刀调度模式.lnk'

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnkPath)
$sc.TargetPath       = $bat
$sc.Arguments        = '/quiet'
$sc.WorkingDirectory = $here
$sc.WindowStyle      = 7                        # 7 = 最小化，避免黑窗弹脸
$sc.Description      = '影刀：先停止运行中的任务，再退出调度模式'
$sc.IconLocation     = "$env:SystemRoot\System32\shell32.dll,27"
$sc.Hotkey           = $Hotkey
$sc.Save()

Write-Host ""
Write-Host "[成功] 桌面快捷方式已创建" -ForegroundColor Green
Write-Host "  位置: $lnkPath"
Write-Host "  快捷键: $Hotkey"
Write-Host ""
Write-Host "如果快捷键没生效，通常是这三个原因：" -ForegroundColor Yellow
Write-Host "  1) 该组合键已被别的软件占用 —— 换一个，例如 Ctrl+Alt+S / Ctrl+Alt+J"
Write-Host "  2) 桌面上的快捷方式被删或移走 —— 快捷键依附于快捷方式本身"
Write-Host "  3) 需要刷新资源管理器 —— 注销重登或重启一次即可"
Write-Host ""
Write-Host "想换快捷键，重跑本脚本并加参数，例如：" -ForegroundColor Gray
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File .\create-shortcut.ps1 -Hotkey `"Ctrl+Alt+S`"" -ForegroundColor Gray
Write-Host ""
