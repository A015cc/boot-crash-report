#Requires -Version 5.1
<#
    开机崩溃报告  boot-crash-report.ps1
    ------------------------------------------------
    开机时读取 Windows 崩溃记录，判断"上次崩溃的原因"。

    数据来源（全部无需管理员权限）：
      1. 事件日志 System / Microsoft-Windows-WER-SystemErrorReporting  1001  -> 蓝屏停止码 + 参数 + 转储路径
      2. 事件日志 System / Kernel-Power                                 41    -> 非正常关机（含无蓝屏的硬挂死）
      3. 事件日志 System / EventLog                                    6008   -> 上一次"意外关机"的准确时刻
      4. WER ReportArchive  Kernel_117 / Kernel_141 等                        -> 显卡 / 内核超时报告

    关键区别：有 1001 的 = 蓝屏（有停止码）；只有 41 的 = 硬挂死（没来得及写转储）。
#>

param(
    [switch]$NoWait
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try { $Host.UI.RawUI.WindowTitle = '开机崩溃报告' } catch { }

# 数据文件写在脚本自己所在的目录，克隆下来即用（该目录需可写）。
$BaseDir     = $PSScriptRoot
if (-not $BaseDir) { $BaseDir = Join-Path $env:LOCALAPPDATA 'boot-crash-report' }
$StateFile   = Join-Path $BaseDir 'state.txt'
$ReportFile  = Join-Path $BaseDir 'last-report.txt'
$WaitSeconds = 120

if ($env:CRASH_REPORT_NOWAIT -eq '1') { $NoWait = $true }

[void][System.IO.Directory]::CreateDirectory($BaseDir)

# ---------------------------------------------------------------- 输出helper

$script:ReportLines = New-Object System.Collections.Generic.List[string]
$script:ChangeCache = $null

function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    [void]$script:ReportLines.Add($Text)
}

function Rule {
    Say ('-' * 62) 'DarkGray'
}

# 事件时间戳带毫秒，而状态文件只存到秒；比较前必须把两边都抹到秒，
# 否则同一次崩溃会因为 .123 > .000 被反复算成"新增"。
function Get-SecondFloor {
    param([datetime]$T)
    return $T.AddTicks(-($T.Ticks % [System.TimeSpan]::TicksPerSecond))
}

# ---------------------------------------------------------------- 停止码词典

$StopCodeInfo = @{
    '0x3'   = 'APC_INDEX_MISMATCH|驱动在 APC 层级调用中不匹配，多为第三方驱动'
    '0xa'   = 'IRQL_NOT_LESS_OR_EQUAL|内核在过高的 IRQL 上访问了非法内存地址。绝大多数由驱动引起；内存不稳时会高频出现'
    '0x18'  = 'REFERENCE_BY_POINTER|对象引用计数错误，通常由驱动引起'
    '0x19'  = 'BAD_POOL_HEADER|内存池头损坏，常见于驱动越界写或内存故障'
    '0x1a'  = 'MEMORY_MANAGEMENT|内存管理检测到异常。内存条、XMP/EXPO 超频、或内存相关驱动'
    '0x1e'  = 'KMODE_EXCEPTION_NOT_HANDLED|内核模式代码抛出未处理的异常，几乎总是某个驱动'
    '0x24'  = 'NTFS_FILE_SYSTEM|NTFS 文件系统错误，可能是磁盘/线材/驱动'
    '0x2e'  = 'DATA_BUS_ERROR|数据总线错误，指向硬件：内存或主板'
    '0x3b'  = 'SYSTEM_SERVICE_EXCEPTION|系统服务例程出错，通常是驱动或安全软件'
    '0x4e'  = 'PFN_LIST_CORRUPT|页帧数据库损坏，指向内存条或驱动'
    '0x50'  = 'PAGE_FAULT_IN_NONPAGED_AREA|访问了不应被换出的内存，通常是驱动或内存故障'
    '0x7e'  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED|系统线程异常未处理，驱动问题'
    '0x9f'  = 'DRIVER_POWER_STATE_FAILURE|驱动电源状态切换失败，常见于休眠/唤醒'
    '0xa0'  = 'INTERNAL_POWER_ERROR|电源策略内部错误'
    '0xbe'  = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY|试图写只读内存，通常是驱动'
    '0xc1'  = 'SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION|专用内存池被写坏，驱动越界或内存故障'
    '0xc2'  = 'BAD_POOL_CALLER|驱动以错误方式操作内存池'
    '0xc4'  = 'DRIVER_VERIFIER_DETECTED_VIOLATION|驱动验证器发现驱动违规'
    '0xc5'  = 'DRIVER_CORRUPTED_EXPOOL|驱动破坏了系统内存池'
    '0xc7'  = 'TIMER_OR_DPC_INVALID|定时器或延迟过程调用非法，驱动问题'
    '0xce'  = 'DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS|驱动卸载时留下了未取消的挂起操作'
    '0xd1'  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL|驱动在过高的 IRQL 上访问了可分页内存。几乎总是第三方驱动的责任'
    '0xea'  = 'THREAD_STUCK_IN_DEVICE_DRIVER|线程卡死在设备驱动中，常见于显卡/磁盘驱动'
    '0xef'  = 'CRITICAL_PROCESS_DIED|关键系统进程死亡'
    '0xf4'  = 'CRITICAL_OBJECT_TERMINATION|关键系统对象被终止，常伴随磁盘/文件系统问题'
    '0x109' = 'CRITICAL_STRUCTURE_CORRUPTION|内核关键结构被破坏，驱动或硬件'
    '0x116' = 'VIDEO_TDR_FAILURE|显卡驱动超时且恢复失败 —— 显卡相关'
    '0x117' = 'VIDEO_TDR_TIMEOUT_DETECTED|显卡引擎无响应超时 —— 显卡相关'
    '0x119' = 'VIDEO_SCHEDULER_INTERNAL_ERROR|显卡调度器内部错误 —— 显卡相关'
    '0x124' = 'WHEA_UNCORRECTABLE_ERROR|硬件报告了不可纠正错误（CPU/内存/PCIe）。属于硬件层，不是软件'
    '0x133' = 'DPC_WATCHDOG_VIOLATION|DPC 看门狗超时，驱动长时间占用高 IRQL，常见于存储/显卡驱动'
    '0x139' = 'KERNEL_SECURITY_CHECK_FAILURE|内核安全检查失败，驱动破坏内核数据结构或内存故障'
    '0x141' = 'VIDEO_ENGINE_TIMEOUT_DETECTED|显卡引擎超时 —— 显卡相关'
}

function Get-StopCodeName {
    param([string]$Code)
    if (-not $Code) { return '未知停止码' }
    $key = $Code.ToLower()
    if ($StopCodeInfo.ContainsKey($key)) {
        return ($StopCodeInfo[$key] -split '\|')[0]
    }
    return '未知停止码'
}

function Get-StopCodeHint {
    param([string]$Code)
    if (-not $Code) { return '' }
    $key = $Code.ToLower()
    if ($StopCodeInfo.ContainsKey($key)) {
        return ($StopCodeInfo[$key] -split '\|')[1]
    }
    return ''
}

# ---------------------------------------------------------------- 采集信号

function Get-SignalEvents {
    $list = New-Object System.Collections.Generic.List[object]

    foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41 } -MaxEvents 60 -ErrorAction SilentlyContinue)) {
        [void]$list.Add([pscustomobject]@{ Boot = $e.TimeCreated; Kind = 'KP41'; Event = $e })
    }
    foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6008 } -MaxEvents 60 -ErrorAction SilentlyContinue)) {
        [void]$list.Add([pscustomobject]@{ Boot = $e.TimeCreated; Kind = 'E6008'; Event = $e })
    }
    foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001 } -MaxEvents 60 -ErrorAction SilentlyContinue)) {
        [void]$list.Add([pscustomobject]@{ Boot = $e.TimeCreated; Kind = 'BUGCHECK'; Event = $e })
    }

    return @($list | Sort-Object Boot)
}

function ConvertTo-IncidentList {
    param($Signals)

    $incidents = New-Object System.Collections.Generic.List[object]
    $bucket    = $null

    foreach ($s in $Signals) {
        if ($null -eq $bucket) {
            $bucket = New-Object System.Collections.Generic.List[object]
            [void]$bucket.Add($s)
        }
        elseif (($s.Boot - $bucket[0].Boot).TotalSeconds -le 180) {
            [void]$bucket.Add($s)
        }
        else {
            [void]$incidents.Add((ConvertTo-Incident -Group $bucket))
            $bucket = New-Object System.Collections.Generic.List[object]
            [void]$bucket.Add($s)
        }
    }
    if ($null -ne $bucket) { [void]$incidents.Add((ConvertTo-Incident -Group $bucket)) }

    # 注意：PowerShell 5.1 下 @($genericList) 会抛 "Argument types do not match"，
    # 必须用 ToArray() 物化，不能直接 @() 包 List。
    return $incidents.ToArray()
}

function ConvertTo-Incident {
    param($Group)

    $bc   = @($Group | Where-Object { $_.Kind -eq 'BUGCHECK' } | Select-Object -First 1)
    $e6   = @($Group | Where-Object { $_.Kind -eq 'E6008' }    | Select-Object -First 1)
    $kp   = @($Group | Where-Object { $_.Kind -eq 'KP41' }     | Select-Object -First 1)
    $boot = ($Group | Sort-Object Boot | Select-Object -First 1).Boot

    $stopCode = $null; $params = $null; $dump = $null; $reportId = $null

    if ($bc.Count -gt 0) {
        $msg = $bc[0].Event.Message
        if ($msg) {
            $m = [regex]::Match($msg, '0x([0-9a-fA-F]{8})\s*\(([^)]*)\)')
            if ($m.Success) {
                $hex = $m.Groups[1].Value.TrimStart('0')
                if ($hex -eq '') { $hex = '0' }
                $stopCode = '0x' + $hex.ToUpper()
                $params   = ($m.Groups[2].Value -split ',') | ForEach-Object { $_.Trim() }
            }
            $d = [regex]::Match($msg, 'dump was saved in:\s*(\S+)', 'IgnoreCase')
            if ($d.Success) { $dump = $d.Groups[1].Value.TrimEnd('.') }
            $r = [regex]::Match($msg, 'Report Id:\s*([0-9a-fA-F\-]+)')
            if ($r.Success) { $reportId = $r.Groups[1].Value }
        }
    }

    # 6008 记录了"上一次意外关机"的准确时刻
    $crashTime = $null
    if ($e6.Count -gt 0) {
        $msg = $e6[0].Event.Message
        if ($msg) {
            $mm = [regex]::Match($msg, '(\d{1,2}:\d{2}:\d{2})[\s\S]*?(\d{4})\D+(\d{1,2})\D+(\d{1,2})')
            if ($mm.Success) {
                try {
                    $crashTime = [datetime]::ParseExact(
                        ('{0}-{1}-{2} {3}' -f $mm.Groups[2].Value, $mm.Groups[3].Value, $mm.Groups[4].Value, $mm.Groups[1].Value),
                        'yyyy-M-d H:mm:ss',
                        [Globalization.CultureInfo]::InvariantCulture)
                }
                catch { $crashTime = $null }
            }
        }
    }

    $kind = 'OTHER'
    if ($bc.Count -gt 0)     { $kind = 'BUGCHECK' }
    elseif ($kp.Count -gt 0) { $kind = 'HANG' }

    $dumpFileName = $null
    if ($dump) { $dumpFileName = Split-Path $dump -Leaf }

    return [pscustomobject]@{
        Boot       = $boot
        CrashTime  = $crashTime
        SortTime   = $(if ($crashTime) { $crashTime } else { $boot })
        Kind       = $kind
        StopCode   = $stopCode
        StopName   = (Get-StopCodeName $stopCode)
        StopHint   = (Get-StopCodeHint $stopCode)
        Params     = $params
        Dump       = $dumpFileName
        ReportId   = $reportId
        HasKP41    = ($kp.Count -gt 0)
        HasE6008   = ($e6.Count -gt 0)
    }
}

function Get-KernelWerReports {
    $out = New-Object System.Collections.Generic.List[object]
    $root = 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive'
    foreach ($d in @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -like 'Kernel_*' -or $d.Name -like 'BlueScreen_*') {
            $code = $null
            $cm = [regex]::Match($d.Name, '^(Kernel)_([0-9a-fA-F]+)_')
            if ($cm.Success) { $code = '0x' + $cm.Groups[2].Value }
            [void]$out.Add([pscustomobject]@{
                Time = $d.LastWriteTime
                Name = $d.Name
                Code = $code
                Name0 = (Get-StopCodeName $code)
            })
        }
    }
    return @($out | Sort-Object Time -Descending)
}

# ---------------------------------------------------------------- 系统变更时间线
#
# 排查崩溃最经典的一问是"崩溃之前系统里变了什么"。
# 两个免费且不需要提权的数据源：
#   - C:\Windows\INF\setupapi.dev.log  驱动/设备安装日志（带真实安装时刻）
#   - WindowsUpdateClient/Operational  系统更新成功/失败
#
# 关键难点是**噪音**：有些设备每次开机都会重装（例如应用商店组件、虚拟设备），
# 它们会淹没真正的变更。判据是"同一个目标是否跨 >=3 个不同日期出现过" ——
# 跨多天的属于例行重复，一次性安装才是变更。

$VendorNames = @{
    '10DE' = 'NVIDIA';  '8086' = 'Intel';  '1002' = 'AMD';   '1022' = 'AMD'
    '10EC' = 'Realtek'; '0BDA' = 'Realtek'; '14E4' = 'Broadcom'
    '1B21' = 'ASMedia'; '1B4B' = 'Marvell'
    '168C' = 'Qualcomm Atheros'; '0CF3' = 'Qualcomm Atheros'
    '046D' = 'Logitech'; '1532' = 'Razer'
}

function Get-ChangeLabel {
    param($Kind, $Target)
    $t = $Target

    # 只为了把一行放得下：MSIX 包只留包名，设备实例路径丢掉 &SUBSYS/&REV 和实例
    # 后缀，长路径只留尾部两段。不影响判据 —— 例行判据用的是 Key，不是这个。
    if ($t -match '^[A-Za-z]:\\') {
        $msix = [regex]::Match($t, 'WindowsApps\\([^_\\]+)')
        if ($msix.Success) {
            $t = $msix.Groups[1].Value + '（MSIX 包）'
        }
        elseif ($t.Length -gt 58) {
            $parts = @($t -split '\\')
            if ($parts.Count -ge 2) { $t = '...\' + $parts[$parts.Count - 2] + '\' + $parts[$parts.Count - 1] }
        }
    }
    elseif ($t -match '^([A-Za-z]+)\\([^\\]+)') {
        $t = $Matches[1] + '\' + $Matches[2]
    }

    $ven = [regex]::Match($t, 'VEN_([0-9A-Fa-f]{4})')
    if ($ven.Success) {
        $v = $ven.Groups[1].Value.ToUpper()
        if ($VendorNames.ContainsKey($v)) { $t = $t + '（' + $VendorNames[$v] + '）' }
    }
    if ($t -like 'root\*') { $t = $t + '（虚拟设备）' }
    if ($Kind -eq 'device')     { return '[设备安装]   ' + $t }
    if ($Kind -eq 'driver')     { return '[驱动安装]   ' + $t }
    if ($Kind -eq 'inf-remove') { return '[驱动包卸载] ' + $t }
    if ($Kind -eq 'wu-ok')      { return '[系统更新]   ' + $t }
    if ($Kind -eq 'wu-fail')    { return '[更新失败]   ' + $t }
    return $t
}

function Get-SystemChanges {
    if ($null -ne $script:ChangeCache) { return $script:ChangeCache }

    $raw       = New-Object System.Collections.Generic.List[object]
    $logStart  = $null
    $available = $false
    $logPath   = 'C:\Windows\INF\setupapi.dev.log'

    if (Test-Path $logPath) {
        $available = $true
        $section   = ''
        $seenDays  = @{}

        foreach ($line in [System.IO.File]::ReadLines($logPath)) {
            if ($line -match '^>>>\s+\[(.+)\]') { $section = $Matches[1]; continue }
            if ($line -notmatch 'Section start\s+(\d{4})/(\d{2})/(\d{2})\s+(\d{2}):(\d{2}):(\d{2})') { continue }
            if (-not $section) { continue }
            try {
                $t = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3],
                                     [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
            }
            catch { continue }

            $kind = $null
            if     ($section -like 'Device Install*')       { $kind = 'device' }
            elseif ($section -like 'Driver Install*')       { $kind = 'driver' }
            elseif ($section -like 'SetupUninstallOEMInf*') { $kind = 'inf-remove' }
            if (-not $kind) { continue }

            if ($null -eq $logStart -or $t -lt $logStart) { $logStart = $t }

            $i = $section.IndexOf(' - ')
            if ($i -gt 0) { $target = $section.Substring($i + 3) } else { $target = $section }

            # 例行判据必须先剥掉版本号：应用商店组件这类每次开机重装的包，路径里
            # 带着版本号（例如 _1.2.3.4_），不剥的话每次更新都成了一个"新目标"，
            # 跨天判据就失效了。
            $key = $target -replace '\d+(?:\.\d+)+', ''
            if (-not $seenDays.ContainsKey($key)) { $seenDays[$key] = @{} }
            $seenDays[$key][$t.ToString('yyyy-MM-dd')] = $true

            [void]$raw.Add([pscustomobject]@{
                Time   = $t
                Kind   = $kind
                Target = $target
                Key    = $key
                Label  = (Get-ChangeLabel $kind $target)
            })
        }

        $routine = @{}
        foreach ($k in $seenDays.Keys) { if ($seenDays[$k].Count -ge 3) { $routine[$k] = $true } }
        foreach ($r in $raw) {
            $r | Add-Member -NotePropertyName Routine -NotePropertyValue ($routine.ContainsKey($r.Key)) -Force
        }
    }

    try {
        $wu = @(Get-WinEvent -FilterHashtable @{
                    LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'
                    Id      = 19, 20
                } -MaxEvents 250 -ErrorAction Stop)
    }
    catch { $wu = @() }

    foreach ($e in $wu) {
        $msg = $e.Message
        if (-not $msg) { continue }
        $m = [regex]::Match($msg, 'update:\s*(.+)')
        if (-not $m.Success) { continue }
        $title = $m.Groups[1].Value.Trim()
        # Defender 定义库天天更新，与崩溃无关
        if ($title -like '*Security Intelligence Update*') { continue }
        if ($title -like '*Definition Update*') { continue }
        $k = 'wu-ok'
        if ($e.Id -eq 20) { $k = 'wu-fail' }
        [void]$raw.Add([pscustomobject]@{
            Time    = $e.TimeCreated
            Kind    = $k
            Target  = $title
            Label   = (Get-ChangeLabel $k $title)
            Routine = $false
        })
    }

    $script:ChangeCache = [pscustomobject]@{
        Events    = @($raw | Sort-Object Time)
        LogStart  = $logStart
        Available = $available
    }
    return $script:ChangeCache
}

# ---------------------------------------------------------------- 通用异常扫描
#
# 上面那套是"我知道要查什么"。这一套是"我不知道要查什么"——不预设事件 ID，
# 把崩溃窗口内所有 System ERROR/CRITICAL 拉出来，用统计方法自动滤掉背景噪音。
# 新的失效模式（磁盘报错、内存错误、热告警……）不需要我提前想到就会冒出来。
#
# 判据的关键：**只在崩溃窗口之外、且跨 >=3 天重复出现的，才算"长期背景噪音"。**
# 不能直接沿用驱动时间线那个判据 —— 那样的话，一个正在恶化的硬件故障连报三天
# 就会被当成"例行"滤掉，越是持续性问题越容易被吞掉。

$RelatedEventIds = @(41, 6008, 1001, 1005, 1006, 6005, 6006, 6009, 6013, 1074, 109, 4101)

$ProviderNames = @{
    'Microsoft-Windows-WER-SystemErrorReporting'  = 'WER'
    'Microsoft-Windows-DistributedCOM'            = 'DCOM'
    'Microsoft-Windows-WindowsUpdateClient'       = 'Windows Update'
    'Microsoft-Windows-DriverFrameworks-UserMode' = 'UMDF 驱动框架'
    'Microsoft-Windows-DNS-Client'                = 'DNS'
    'Microsoft-Windows-Kernel-Power'              = '内核电源'
    'Microsoft-Windows-DeviceAssociationService'  = '设备关联服务'
    'Service Control Manager'                     = '服务控制管理器'
    'volmgr'                                      = '卷管理器'
    'disk'                                        = '磁盘'
    'Ntfs'                                        = 'NTFS'
    'Schannel'                                    = 'TLS / Schannel'
    'BTHUSB'                                      = '蓝牙'
}

function Get-ProviderLabel {
    param([string]$P)
    if ($ProviderNames.ContainsKey($P)) { return $ProviderNames[$P] }
    return $P
}

function Get-AnomalousEvents {
    param([datetime]$CrashTime, [int]$WindowDays = 4, [int]$MaxAgeDays = 14)

    $res = [pscustomobject]@{
        Available = $false
        Reason    = ''
        Items     = @()
        Chronic   = 0
    }

    $ageDays = [int]((Get-Date) - $CrashTime).TotalDays
    if ($ageDays -gt $MaxAgeDays) {
        $res.Reason = ('上次崩溃已过去 ' + $ageDays + ' 天，事件日志多半已轮转，跳过扫描。')
        return $res
    }

    $histFrom = (Get-Date).AddDays(-45)
    try {
        $all = @(Get-WinEvent -FilterHashtable @{
                    LogName   = 'System'
                    Level     = 1, 2
                    StartTime = $histFrom
                    EndTime   = $CrashTime
                } -MaxEvents 1200 -ErrorAction Stop)
    }
    catch { $all = @() }

    $all = @($all | Where-Object { $_.Id -notin $RelatedEventIds })
    if ($all.Count -eq 0) {
        $res.Reason = '这段时间内没有可用的错误日志。'
        return $res
    }

    $inFrom = $CrashTime.AddDays(-$WindowDays)
    $inside = @($all | Where-Object { $_.TimeCreated -ge $inFrom })
    $before = @($all | Where-Object { $_.TimeCreated -lt $inFrom })

    if ($inside.Count -eq 0) {
        $res.Reason = ('崩溃前 ' + $WindowDays + ' 天内没有任何错误日志。')
        return $res
    }

    $chronic = @{}
    foreach ($g in @($before | Group-Object { "$($_.ProviderName)|$($_.Id)" })) {
        $days = @($g.Group | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd') } | Sort-Object -Unique)
        if ($days.Count -ge 3) { $chronic[$g.Name] = $true }
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($g in @($inside | Group-Object { "$($_.ProviderName)|$($_.Id)" })) {
        if ($chronic.ContainsKey($g.Name)) { continue }
        $last = $g.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
        $msg  = $last.Message
        if (-not $msg) { $msg = '' }
        $msg = (($msg -replace "`r`n", ' ') -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 130) { $msg = $msg.Substring(0, 127) + '...' }
        [void]$items.Add([pscustomobject]@{
            Provider = (Get-ProviderLabel $last.ProviderName)
            Id       = $last.Id
            Count    = $g.Count
            Last     = $last.TimeCreated
            Message  = $msg
        })
    }

    $res.Available = $true
    $res.Items     = @($items | Sort-Object Count -Descending)
    $res.Chronic   = $chronic.Count
    return $res
}

# ---------------------------------------------------------------- 开始出报告

$now      = Get-Date
$os       = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$lastBoot = $null
if ($os) { $lastBoot = $os.LastBootUpTime }
if (-not $lastBoot) { $lastBoot = (Get-Date).AddSeconds(-[Environment]::TickCount / 1000) }

Say ''
Say ('=' * 62) 'DarkGray'
Say '  开机崩溃报告' 'White'
Say ('  生成时间   ' + $now.ToString('yyyy-MM-dd HH:mm:ss')) 'DarkGray'
Say ('  本次开机   ' + $lastBoot.ToString('yyyy-MM-dd HH:mm:ss')) 'DarkGray'
$up = $now - $lastBoot
Say ('  已运行     {0} 小时 {1} 分' -f [int]$up.TotalHours, $up.Minutes) 'DarkGray'
Say ('=' * 62) 'DarkGray'

# --- 状态对比：自上次开机以来有没有新增崩溃
$stateTime = $null
if (Test-Path $StateFile) {
    try {
        $raw = ([System.IO.File]::ReadAllText($StateFile)).Trim()
        if ($raw) { $stateTime = [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture) }
    }
    catch { $stateTime = $null }
}
$firstRun = ($null -eq $stateTime)

$signals   = Get-SignalEvents
$incidents = ConvertTo-IncidentList -Signals $signals
$incidents = @($incidents | Sort-Object SortTime -Descending)
$kernelWer = Get-KernelWerReports

$newCount = 0
if (-not $firstRun) {
    $newCount = @($incidents | Where-Object { (Get-SecondFloor $_.Boot) -gt $stateTime }).Count
}

Say ''
if ($firstRun) {
    Say '  [i] 首次运行，正在建立基线。' 'Cyan'
}
elseif ($newCount -gt 0) {
    Say ('  ** 自上次开机以来，新增了 ' + $newCount + ' 次崩溃 **') 'Red'
}
else {
    Say '  [OK] 自上次开机以来没有新的崩溃记录。' 'Green'
}

if ($incidents.Count -eq 0) {
    Say ''
    Say '  没有查询到任何崩溃记录，系统看起来是干净的。' 'Green'
}
else {
    $last = $incidents[0]

    Say ''
    Rule
    Say '  上次崩溃' 'White'
    Rule

    if ($last.CrashTime) {
        Say ('  时间       ' + $last.CrashTime.ToString('yyyy-MM-dd HH:mm:ss')) 'White'
        $ago = $now - $last.CrashTime
        if ($ago.TotalHours -lt 1)     { $agoTxt = ('{0} 分钟前' -f [int]$ago.TotalMinutes) }
        elseif ($ago.TotalHours -lt 48) { $agoTxt = ('{0} 小时前' -f [int]$ago.TotalHours) }
        else                            { $agoTxt = ('{0} 天前' -f [int]$ago.TotalDays) }
        Say ('  距今       ' + $agoTxt) 'DarkGray'
    }
    else {
        Say ('  时间       约 ' + $last.Boot.ToString('yyyy-MM-dd HH:mm') + '（重启时刻，确切关机时刻未知）') 'White'
    }

    if ($last.Kind -eq 'BUGCHECK') {
        Say '  类型       蓝屏 (BSOD)，已生成转储' 'Red'
        Say ('  停止码     ' + $last.StopCode + '   ' + $last.StopName) 'Yellow'
        if ($last.Params) {
            Say ('  参数       ' + ($last.Params -join ', ')) 'DarkGray'
        }
        if ($last.Dump) {
            Say ('  转储文件   C:\Windows\Minidump\' + $last.Dump) 'DarkGray'
        }
        else {
            Say '  转储文件   记录存在，但未找到路径' 'DarkGray'
        }
        if ($last.StopHint) {
            Say ''
            Say ('  这意味着：' + $last.StopHint) 'Yellow'
        }
    }
    elseif ($last.Kind -eq 'HANG') {
        Say '  类型       硬挂死（无蓝屏转储）' 'Red'
        Say '  停止码     -- （系统没来得及生成转储）' 'DarkGray'
        $evi = '  证据       Kernel-Power 41'
        if ($last.HasE6008) { $evi = $evi + ' + 事件日志 6008' }
        $evi = $evi + '；无 BugCheck 记录'
        Say $evi 'DarkGray'
        Say ''
        Say '  这意味着：系统在写出转储之前就失去了响应。典型表现是黑屏 /' 'Yellow'
        Say '  画面卡死 / 键鼠无反应 / 只能强制重启，而不是蓝屏。' 'Yellow'
        Say '  这类"无转储"的崩溃，常见于显卡驱动、供电不稳或超频（XMP）不稳。' 'Yellow'
    }
    else {
        Say '  类型       非正常关机（原因不明）' 'Yellow'
    }

    # --- 崩溃前的系统变更
    $chg     = Get-SystemChanges
    $winDays = 4
    if ($last.CrashTime) { $refTime = $last.CrashTime } else { $refTime = $last.Boot }
    $winFrom = $refTime.AddDays(-$winDays)

    Say ''
    Rule
    Say ('  崩溃前的系统变更   （' + $winFrom.ToString('MM-dd HH:mm') + ' → ' + $refTime.ToString('MM-dd HH:mm') + '，' + $winDays + ' 天内）') 'White'
    Rule

    if (-not $chg.Available) {
        Say '  驱动安装日志不可读，无法做变更关联。' 'DarkGray'
    }
    else {
        if ($chg.LogStart -and $refTime -lt $chg.LogStart) {
            Say ('  注意：驱动安装日志最早只到 ' + $chg.LogStart.ToString('yyyy-MM-dd') + '，覆盖不到这次崩溃。') 'Yellow'
            Say ''
        }
        $inWin    = @($chg.Events | Where-Object { $_.Time -ge $winFrom -and $_.Time -le $refTime })
        $notable  = @($inWin | Where-Object { -not $_.Routine })
        $routineN = $inWin.Count - $notable.Count

        if ($notable.Count -eq 0) {
            Say '  这段时间内没有任何一次性的驱动或系统更新变更。' 'DarkGray'
        }
        else {
            foreach ($c in @($notable | Sort-Object Time -Descending | Select-Object -First 15)) {
                $lbl = $c.Label
                if ($lbl.Length -gt 78) { $lbl = $lbl.Substring(0, 75) + '...' }
                Say ('  ' + $c.Time.ToString('MM-dd HH:mm') + '  ' + $lbl) 'Cyan'
            }
            if ($notable.Count -gt 15) {
                Say ('  …… 另有 ' + ($notable.Count - 15) + ' 条') 'DarkGray'
            }
        }
        if ($routineN -gt 0) {
            Say ('  （已过滤 ' + $routineN + ' 条跨天重复的例行项，例如每次开机都重装的虚拟设备）') 'DarkGray'
        }
    }

    # --- 其他非常规错误日志（不预设事件 ID 的通用扫描）
    $anom = Get-AnomalousEvents -CrashTime $refTime

    Say ''
    Rule
    Say '  其他非常规错误日志   （同一窗口，未预设事件 ID）' 'White'
    Rule

    if (-not $anom.Available) {
        Say ('  ' + $anom.Reason) 'DarkGray'
    }
    else {
        foreach ($a in @($anom.Items | Select-Object -First 8)) {
            Say ('  {0} id{1}   {2}x   最近 {3}' -f $a.Provider, $a.Id, $a.Count, $a.Last.ToString('MM-dd HH:mm')) 'Cyan'
            if ($a.Message) { Say ('      ' + $a.Message) 'DarkGray' }
        }
        if ($anom.Items.Count -gt 8) { Say ('  …… 另有 ' + ($anom.Items.Count - 8) + ' 类') 'DarkGray' }
        if ($anom.Chronic -gt 0) {
            Say ('  （已过滤 ' + $anom.Chronic + ' 类长期背景噪音 —— 在崩溃窗口之外就已跨多天重复出现的）') 'DarkGray'
        }
        Say '  注意："非常规"只表示它不常出现，不等于它就是原因。' 'DarkGray'
    }

    # --- 历史列表
    Say ''
    Rule
    $shown = @($incidents | Select-Object -First 12)
    Say ('  崩溃历史     共 ' + $incidents.Count + ' 次' + $(if ($incidents.Count -gt $shown.Count) { '（只列最近 ' + $shown.Count + ' 次）' } else { '' })) 'White'
    Rule
    foreach ($inc in $shown) {
        if ($inc.CrashTime) { $t = $inc.CrashTime.ToString('yyyy-MM-dd HH:mm') } else { $t = '~' + $inc.Boot.ToString('yyyy-MM-dd HH:mm') }
        if ($inc.Kind -eq 'BUGCHECK') {
            Say ('  {0}   蓝屏 {1}   {2}' -f $t, $inc.StopCode, $inc.StopName) 'Gray'
        }
        elseif ($inc.Kind -eq 'HANG') {
            Say ('  {0}   硬挂死（无转储）' -f $t) 'DarkGray'
        }
        else {
            Say ('  {0}   非正常关机' -f $t) 'DarkGray'
        }
    }

    # --- 线索分析
    $clues = New-Object System.Collections.Generic.List[string]

    $recent = @($incidents | Select-Object -First 8)
    $bugchecks = @($recent | Where-Object { $_.Kind -eq 'BUGCHECK' })
    if ($bugchecks.Count -ge 2) {
        $distinct = @($bugchecks | Select-Object -ExpandProperty StopCode | Sort-Object -Unique)
        if ($distinct.Count -ge 2) {
            [void]$clues.Add(('最近 ' + $bugchecks.Count + ' 次蓝屏出现了 ' + $distinct.Count + ' 种不同的停止码（' + ($distinct -join ', ') + '）。停止码各不相同是内存/供电不稳的典型指纹；单一驱动缺陷通常会反复给出同一个代码。'))
        }
        else {
            [void]$clues.Add(('最近 ' + $bugchecks.Count + ' 次蓝屏都是同一个停止码 ' + $distinct[0] + '，更像某个固定驱动的缺陷，而不是随机硬件故障。'))
        }
    }

    $hangCount = @($incidents | Where-Object { $_.Kind -eq 'HANG' }).Count
    if ($hangCount -gt 0 -and $bugchecks.Count -gt 0) {
        [void]$clues.Add(('有 ' + $hangCount + ' 次崩溃完全没留下转储（硬挂死），另有 ' + $bugchecks.Count + ' 次是带转储的蓝屏。两者并存说明系统存在不止一种失效方式。'))
    }

    $gpuCodes = @($bugchecks | Where-Object { $_.StopCode -in @('0x116', '0x117', '0x119', '0x141') })
    if ($gpuCodes.Count -gt 0) {
        [void]$clues.Add('蓝屏里出现过显卡引擎超时（VIDEO_TDR 系列），指向显卡驱动或显卡本体。')
    }
    if ($kernelWer.Count -gt 0) {
        $werTimes = ($kernelWer | Select-Object -First 3 | ForEach-Object { $_.Time.ToString('MM-dd HH:mm') }) -join ' / '
        $werCodes = @($kernelWer | Where-Object { $_.Code } | Select-Object -ExpandProperty Code | Sort-Object -Unique) -join ', '
        $werExtra = ''
        if ($werCodes) { $werExtra = '，代码 ' + $werCodes }
        [void]$clues.Add(('WER 归档里有 ' + $kernelWer.Count + ' 份显卡/内核超时报告（最近：' + $werTimes + $werExtra + '）。这类报告往往出现在"画面卡死但系统没蓝屏"的场景里，是硬挂死的重要旁证。'))
    }

    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger' } -MaxEvents 1 -ErrorAction SilentlyContinue)
    if ($whea.Count -eq 0) {
        [void]$clues.Add('全程没有任何 WHEA（硬件错误）记录 —— 所以问题更像内存/驱动层面，而不是 CPU 或 PCIe 报出机器检查异常。')
    }
    else {
        [void]$clues.Add('存在 WHEA 硬件错误记录，这属于硬件层报警。')
    }

    $noDumpTotal = @($incidents | Where-Object { $_.Kind -eq 'HANG' }).Count
    if ($noDumpTotal -gt 0) {
        [void]$clues.Add(('注意：无转储的崩溃无法自动分析，要查清原因需要开启"完整内存转储"或手动触发一次转储，否则只能靠 WER 报告和驱动版本比对。'))
    }

    if ($clues.Count -gt 0) {
        Say ''
        Rule
        Say '  崩溃原因线索' 'White'
        Rule
        foreach ($c in $clues) {
            Say ('  * ' + $c) 'Cyan'
            Say ''
        }
    }
}

# --- 尾部
Say ''
Rule
Say ('  完整报告已保存到  ' + $ReportFile) 'DarkGray'
Rule
Say ''

# 写报告文件
try {
    [System.IO.File]::WriteAllText($ReportFile, ($script:ReportLines -join "`r`n"), [System.Text.UTF8Encoding]::new($true))
}
catch { }

# 更新状态（记录本次见到的最新一次崩溃的重启时刻）
try {
    $newestBoot = $null
    if ($incidents.Count -gt 0) { $newestBoot = (Get-SecondFloor ($incidents | Sort-Object Boot -Descending | Select-Object -First 1).Boot) }
    if ($newestBoot) {
        [System.IO.File]::WriteAllText($StateFile, $newestBoot.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), [System.Text.UTF8Encoding]::new($false))
    }
    else {
        [System.IO.File]::WriteAllText($StateFile, (Get-SecondFloor $lastBoot).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture), [System.Text.UTF8Encoding]::new($false))
    }
}
catch { }

# 等待关闭
if (-not $NoWait) {
    Write-Host ('  窗口将在 ' + $WaitSeconds + ' 秒后自动关闭，按任意键立即关闭 ...') -ForegroundColor DarkGray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $WaitSeconds) {
        try {
            if ([Console]::KeyAvailable) {
                [void][Console]::ReadKey($true)
                break
            }
        }
        catch { }
        Start-Sleep -Milliseconds 200
    }
}
