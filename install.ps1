#Requires -Version 5.1
<#
    install.ps1 -- 把 boot-crash-report 注册为开机自启。

    做法是在「启动」文件夹里放一个指向 run.cmd 的快捷方式。
    不需要管理员权限，也不需要写注册表或计划任务。

        .\install.ps1              安装
        .\install.ps1 -Uninstall   卸载
#>

param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
if (-not $here) { $here = (Get-Location).Path }

$target = Join-Path $here 'run.cmd'
$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup 'BootCrashReport.lnk'

if ($Uninstall) {
    if ([System.IO.File]::Exists($link)) {
        [System.IO.File]::Delete($link)
        Write-Host "已卸载：删除了 $link"
    }
    else {
        Write-Host "未安装（找不到 $link）"
    }
    return
}

if (-not (Test-Path $target)) {
    throw "找不到 run.cmd：$target"
}

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($link)
$sc.TargetPath       = $target
$sc.WorkingDirectory = $here
$sc.WindowStyle      = 1
$sc.Description      = 'Boot crash report'
$sc.Save()

Write-Host "已安装。下次登录时会自动运行。"
Write-Host "  快捷方式：$link"
Write-Host "  目标：    $target"
Write-Host ""
Write-Host "现在想先看一眼，直接双击 run.cmd，或运行："
Write-Host "  & '$target'"
