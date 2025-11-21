<#
PC-HealthCheck.ps1
Inclusive, technician-friendly Windows health assessment and light optimization PowerShell script.

Highlights (all in one script):
- Fast snapshot (~6s) with multi-sample averages
- Health tiers: Good | Medium | Critical | Unknown (skipped metrics don’t penalize health)
- Identity includes Device Manufacturer, Model, System Vendor/Product, and friendly Product display string
- Hardware inventory (CPU, Board, BIOS, GPU, RAM, Disks)
- Network, Storage health (PhysicalDisk + Reliability counters + SMART fallback), CPU Temp (best-effort)
- Event log (72h), Boot performance (Event ID 100 averages)
- Performance snapshot: CPU, Memory, Disk (with LogicalDisk fallback), Top processes (CPU/IO deltas)
- Optional repairs (DISM/SFC), cleanups (Temp, TRIM, DNS/Winsock, Storage Sense, TCP)
- Power Mode: Balanced or High (restores original unless -KeepNewPowerPlan)
- Reversible toggles: HAGS on/off, Game Bar capture on/off
- Startup Optimization (safe + reversible), Deep Clean (prompt-gated)
- Compact and Full CSV/Log outputs
- Grouped console dashboard:
  System Hardware and Identity: Identity, CPU, Memory, Disk, GPU
  System Performance and Maintenance: Boot, Events, Repairs/Tweaks, Skipped/Unavailable, Overall

PowerShell 5.1 compatible (no PS7-only operators; no inline if() in argument lists).
#>

# Script version (semantic versioning)
$ScriptVersion = '1.0'

#Requires -Version 5.1

param(
    [switch]$AutoElevate,
    [switch]$QuietSkipAdmin,

    [ValidateSet("Balanced","High")]
    [string]$PowerMode = "Balanced",
    [switch]$KeepNewPowerPlan,

    [switch]$ApplyStartupOptimization,
    [switch]$ForceStartupOptimization,

    [switch]$DeepClean,
    [switch]$DeepCleanAutoYes,

    [switch]$EnableHAGS,
    [switch]$DisableHAGS,

    [switch]$DisableGameBarCapture,
    [switch]$EnableGameBarCapture
)

# ---------------------------
# CONFIG / THRESHOLDS
# ---------------------------
$PerfSamples               = 6
$PerfInterval              = 1
$CPU_Usage_Medium_Thresh   = 90
$CPU_Usage_Critical_Thresh = 95
$CPU_Backlog_Medium_Factor = 1.5
$CPU_Backlog_Crit_Factor   = 3
$RAM_Used_Medium_Thresh    = 90
$RAM_Used_Critical_Thresh  = 98
$RAM_Avail_Medium_Ratio    = 0.05
$RAM_Avail_Crit_Ratio      = 0.02
$RAM_HardFaults_Medium     = 200
$RAM_HardFaults_Critical   = 1000
$Disk_Busy_Medium_Thresh   = 90
$Disk_Busy_Critical_Thresh = 95
$Disk_Queue_Medium_Thresh  = 2
$Disk_Queue_Critical_Thresh= 5
$CPU_Temp_Critical         = 85
$PrefetchClearThresholdMB  = 300
$Boot_Good_Thresh          = 45
$Boot_Medium_Thresh        = 75
$TreatMissingBacklogAsGood = $true  # Set to $false to show Unknown when backlog counter is missing

# ---------------------------
# SETUP
# ---------------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ReportDir      = "C:\Scripts\PCHealthCheckScript"
if (-not (Test-Path $ReportDir)) { New-Item -Path $ReportDir -ItemType Directory | Out-Null }
$DateStamp      = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$PCName         = $env:COMPUTERNAME
$CSVPath        = Join-Path $ReportDir "PC-Health-Report-$PCName-$DateStamp.csv"
$CSVCompactPath = Join-Path $ReportDir "PC-Health-Report-Compact-$PCName-$DateStamp.csv"
$LogPath        = Join-Path $ReportDir "PC-Health-Full-$PCName-$DateStamp.txt"
$LogCompactPath = Join-Path $ReportDir "PC-Health-Compact-$PCName-$DateStamp.txt"
$AdminTodoPath  = Join-Path $ReportDir "Run-As-Admin-Todo-$PCName-$DateStamp.txt"

$SkippedItems     = [System.Collections.Generic.List[string]]::new()
$DeepCleanActions = [System.Collections.Generic.List[string]]::new()

function Status { param([string]$Symbol,[string]$Text,[string]$Color="White")
    $prefix = "[$Symbol] "
    Write-Host ($prefix + $Text) -ForegroundColor $Color
    Add-Content -Path $LogPath -Value ("$((Get-Date).ToString('s')) $prefix $Text")
}
function Section { param([string]$Title,[string]$Color="Cyan")
    Write-Host ("-- {0} --" -f $Title) -ForegroundColor $Color
    Add-Content -Path $LogPath -Value ("`n=== {0} ===" -f $Title)
}
function AdminSkip {
    param([string]$What,[string]$HowToRun)
    $SkippedItems.Add($What)
    $msg = if ($QuietSkipAdmin) { "$What skipped (no admin)." } else { "$What skipped: admin privileges required." }
    Status "-" $msg "Yellow"
    if ($HowToRun) {
        if (-not (Test-Path $AdminTodoPath)) {
            "Run these commands elevated (Administrator):" | Out-File -FilePath $AdminTodoPath -Encoding UTF8
            Add-Content -Path $AdminTodoPath -Value ""
        }
        Add-Content -Path $AdminTodoPath -Value ("[$What]")
        Add-Content -Path $AdminTodoPath -Value ($HowToRun.Trim())
        Add-Content -Path $AdminTodoPath -Value ""
    }
}
function Get-CtrAvg {
    param([Parameter(Mandatory)][string]$Path,[int]$Samples=6,[int]$IntervalSec=1)
    try {
        $vals = (Get-Counter -Counter $Path -SampleInterval $IntervalSec -MaxSamples $Samples -ErrorAction Stop).CounterSamples.CookedValue
        if (-not $vals) { return $null }
        [math]::Round((($vals | Measure-Object -Average).Average),2)
    } catch { $null }
}
function Merge-Health3 { param([string[]]$States)
    if ($States -contains "Critical") { "Critical" }
    elseif ($States -contains "Medium") { "Medium" }
    elseif ($States -contains "Good") { "Good" }
    else { "Unknown" }
}
function HealthColor { param([string]$State)
    switch ($State) { "Good"{"Green"} "Medium"{"Yellow"} "Critical"{"Red"} "Unknown"{"Gray"} default{"White"} }
}
function OverallHealth { param([string]$CPU,[string]$Memory,[string]$Disk,[string]$Events,[string]$DiskSmart,[string]$Boot)
    Merge-Health3 @($CPU,$Memory,$Disk,$Events,$DiskSmart,$Boot)
}
function Prompt-YesNo { param([string]$Message,[switch]$AutoYes)
    if ($AutoYes) { return $true }
    $resp = Read-Host "$Message (Y/N)"
    return ($resp -match '^[Yy]')
}
function SafeVal { param($v,$suffix=""); if ($v -eq $null -or $v -eq "") { "N/A" } else { if ($suffix) { "$v$suffix" } else { "$v" } } }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Elevation flow
if (-not $IsAdmin -and $AutoElevate) {
    try {
        if ($PSCommandPath) {
            $argList = @("-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"")
            foreach ($kv in $MyInvocation.BoundParameters.GetEnumerator()) {
                if ($kv.Key -eq 'AutoElevate') { continue }
                if ($kv.Value -is [bool]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
                else { $argList += "-$($kv.Key)"; $argList += "`"$($kv.Value)`"" }
            }
            Start-Process powershell.exe -ArgumentList $argList -Verb RunAs | Out-Null
            exit
        } else {
            Start-Process powershell.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass" -Verb RunAs | Out-Null
            Status "-" "Elevated PowerShell opened. Re-run the script there." "Yellow"
            exit
        }
    } catch { Status "!" "Elevation failed; continuing non-admin." "Yellow" }
}
if (-not $IsAdmin) { Write-Warning "Admin-only operations will be skipped and logged under 'Skipped / Unavailable'." }

# Conflict checks
if ($EnableHAGS -and $DisableHAGS) {
    Status "!" "Both -EnableHAGS and -DisableHAGS specified; ignoring both." "Red"
    $SkippedItems.Add("HAGS conflict flags")
    $EnableHAGS=$false; $DisableHAGS=$false
}
if ($DisableGameBarCapture -and $EnableGameBarCapture) {
    Status "!" "Both -DisableGameBarCapture and -EnableGameBarCapture specified; ignoring both." "Red"
    $SkippedItems.Add("GameBar conflict flags")
    $DisableGameBarCapture=$false; $EnableGameBarCapture=$false
}

Clear-Host
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " PC HEALTH CHECK - Starting Full Scan" -ForegroundColor Cyan
Write-Host (" PC: {0}    Time: {1}" -f $PCName,(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

"PC Health Check started for $PCName at $(Get-Date)" | Out-File -FilePath $LogPath -Encoding UTF8
Add-Content -Path $LogPath -Value ("Script Version: " + $ScriptVersion)

# ---------------------------
# SYSTEM / INVENTORY
# ---------------------------
function Get-UptimeSpan {
    try {
        $osLocal = $os
        if (-not $osLocal) { $osLocal = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
        $lbut = $osLocal.LastBootUpTime
        if ($lbut -is [datetime]) { return (Get-Date) - $lbut }
        if ($lbut -is [string] -and $lbut) {
            $dt = [Management.ManagementDateTimeConverter]::ToDateTime($lbut)
            return (Get-Date) - $dt
        }
    } catch {}
    try {
        $uptimeSec = (Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop).SystemUpTime
        if ($uptimeSec) { return [TimeSpan]::FromSeconds([double]$uptimeSec) }
    } catch {}
    [TimeSpan]::Zero
}

Section "SYSTEM"
Status "~" "Collecting system & hardware inventory..." "Yellow"
try {
    $comp        = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $os          = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cpu         = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
    $baseBoard   = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $bios        = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $videoCtrls  = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    $ramModules  = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $diskDrives  = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue
    $disks       = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    $uptime      = Get-UptimeSpan

    # Additional system identity details (Manufacturer/Model/Vendor/Product)
    $csProduct = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $DeviceManufacturer = try { $comp.Manufacturer } catch { $null }
    $DeviceModel        = try { $comp.Model }        catch { $null }
    $SystemVendor       = if ($csProduct -and $csProduct.Vendor) { $csProduct.Vendor } else { $DeviceManufacturer }
    $SystemProductName  = if ($csProduct -and $csProduct.Name)   { $csProduct.Name }   else { $DeviceModel }
    $isGeneric = ($SystemProductName -match '(?i)to be filled|system product|default string|not specified')
    $IdentityProductDisplay = if (-not [string]::IsNullOrWhiteSpace($SystemVendor) -and
                                  -not [string]::IsNullOrWhiteSpace($SystemProductName) -and
                                  -not $isGeneric) {
        "$SystemVendor $SystemProductName"
    } elseif (-not [string]::IsNullOrWhiteSpace($DeviceManufacturer) -or -not [string]::IsNullOrWhiteSpace($DeviceModel)) {
        ($DeviceManufacturer + " " + $DeviceModel).Trim()
    } else {
        $env:COMPUTERNAME
    }

    Add-Content -Path $LogPath -Value ("`n-- System Identity --`n" +
        ("Manufacturer: {0}`nModel: {1}`nVendor: {2}`nProduct: {3}`nDisplay: {4}`n" -f `
        $DeviceManufacturer,$DeviceModel,$SystemVendor,$SystemProductName,$IdentityProductDisplay))

    Status "+" "Inventory collected." "Green"
} catch {
    Status "!" "Inventory collection partial: $($_.Exception.Message)" "Red"
    if (-not $uptime) { $uptime = [TimeSpan]::Zero }
}

try {
    if ($ramModules) {
        $TotalRAMGB = [math]::Round((($ramModules | Measure-Object Capacity -Sum).Sum / 1GB),2)
    } else {
        $TotalRAMGB = if ($comp.TotalPhysicalMemory) { [math]::Round($comp.TotalPhysicalMemory/1GB,2) } else { "Unknown" }
    }
} catch { $TotalRAMGB = "Unknown" }
try {
    $TotalVisibleMemoryMB = if ($os) { [math]::Round($os.TotalVisibleMemorySize/1024,2) } else { $null }
    $FreePhysicalMB       = if ($os) { [math]::Round($os.FreePhysicalMemory/1024,2) } else { $null }
} catch {}

Add-Content -Path $LogPath -Value "`n-- Hardware Details --"
if ($cpu) { Add-Content -Path $LogPath -Value (($cpu | Select-Object Name,Manufacturer,MaxClockSpeed,NumberOfCores,NumberOfLogicalProcessors) | Format-List | Out-String) }
if ($baseBoard) { Add-Content -Path $LogPath -Value ($baseBoard | Select-Object Manufacturer,Product,SerialNumber | Format-List | Out-String) }
if ($bios) { Add-Content -Path $LogPath -Value ($bios | Select-Object Manufacturer,SMBIOSBIOSVersion,ReleaseDate | Format-List | Out-String) }
if ($videoCtrls) { Add-Content -Path $LogPath -Value (($videoCtrls | Select-Object Name,AdapterCompatibility,DriverVersion,DriverDate) | Format-Table | Out-String) }
if ($ramModules) { Add-Content -Path $LogPath -Value (($ramModules | Select-Object Manufacturer,Capacity,@{n='CapacityGB';e={[math]::Round($_.Capacity/1GB,2)}},Speed) | Format-Table | Out-String) }
if ($diskDrives) { Add-Content -Path $LogPath -Value (($diskDrives | Select-Object Model,Manufacturer,InterfaceType,@{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}},FirmwareRevision) | Format-Table | Out-String) }

# ---------------------------
# NETWORK
# ---------------------------
Section "NETWORK"
Status "~" "Gathering network information..." "Yellow"
try {
    $net = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
           Where-Object { $_.IPEnabled } | Select-Object -First 1
    if ($net) {
        $IP      = ($net.IPAddress -join ", ")
        $Gateway = ($net.DefaultIPGateway -join ", ")
        $DNS     = ($net.DNSServerSearchOrder -join ", ")
    } else { $IP="N/A"; $Gateway="N/A"; $DNS="N/A" }
    Status "+" "Network: IP=$IP Gateway=$Gateway DNS=$DNS" "Green"
} catch {
    Status "!" "Network info failed: $($_.Exception.Message)" "Red"
    $IP="N/A"; $Gateway="N/A"; $DNS="N/A"
}

# ---------------------------
# STORAGE HEALTH
# ---------------------------
Section "STORAGE HEALTH"
Status "~" "Assessing disk SMART / reliability..." "Yellow"
$DiskSmartHealth = "Unknown"
$DiskHealthDetails = @()

function MergeSmart { param($current,$incoming)
    if ($incoming -eq "Critical") { "Critical" }
    elseif ($incoming -eq "Medium" -and $current -ne "Critical") { "Medium" }
    elseif ($incoming -eq "Good" -and $current -notin @("Critical","Medium")) { "Good" }
    else { $current }
}

try {
    $pdList = Get-PhysicalDisk -ErrorAction SilentlyContinue
    if ($pdList) {
        foreach ($pd in $pdList) {
            $mapped = switch ($pd.HealthStatus) {
                "Healthy" {"Good"} "Warning" {"Medium"} "Unhealthy" {"Critical"} default {"Unknown"}
            }
            $DiskSmartHealth = MergeSmart $DiskSmartHealth $mapped
            $detail = "$($pd.FriendlyName) [$($pd.MediaType)] Health=$($pd.HealthStatus)"
            try {
                $rc = Get-StorageReliabilityCounter -PhysicalDisk $pd -ErrorAction SilentlyContinue
                if ($rc) {
                    $issues=@()
                    if ($rc.Wear -as [int] -and $rc.Wear -ge 90){$issues+="Wear=$($rc.Wear)%"}
                    if ($rc.Temperature -as [int] -and $rc.Temperature -ge 70){$issues+="Temp=$($rc.Temperature)C"}
                    if (($rc.ReadErrorsTotal -as [int]) -gt 0){$issues+="ReadErr=$($rc.ReadErrorsTotal)"}
                    if (($rc.WriteErrorsTotal -as [int]) -gt 0){$issues+="WriteErr=$($rc.WriteErrorsTotal)"}
                    if ($issues.Count -gt 0 -and $DiskSmartHealth -ne "Critical"){
                        $DiskSmartHealth="Medium"; $detail+=" Issues: "+($issues -join "; ")
                    }
                }
            } catch {}
            $DiskHealthDetails += $detail
        }
    }
    if ($DiskSmartHealth -eq "Unknown") {
        $smart = Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
        if ($smart) {
            if ($smart | Where-Object PredictFailure){$DiskSmartHealth="Critical";$DiskHealthDetails+="SMART predicts failure"}
            else {$DiskSmartHealth="Good";$DiskHealthDetails+="SMART OK"}
        }
    }
    if ($DiskSmartHealth -eq "Unknown") {
        if ($diskDrives) {
            $ok = $diskDrives | Where-Object { $_.Status -match "OK" }
            $DiskSmartHealth = if ($ok) { "Good" } else { "Unknown" }
            $DiskHealthDetails += "DiskDrive Statuses: "+(($diskDrives | Select-Object -ExpandProperty Status) -join ", ")
        }
    }
    switch ($DiskSmartHealth) {
        "Good"{Status "+" "SMART health: Good." "Green"}
        "Medium"{Status "!" "SMART health: Medium (warnings present)." "Yellow"}
        "Critical"{Status "!" "SMART health: Critical." "Red"}
        "Unknown"{Status "-" "SMART health unavailable." "Gray"}
    }
    if ($DiskHealthDetails.Count -gt 0){
        Add-Content -Path $LogPath -Value ("Disk health details:`n - "+($DiskHealthDetails -join "`n - "))
    }
} catch {
    Status "-" "SMART read error: $($_.Exception.Message)" "Gray"
    $SkippedItems.Add("Disk SMART health (error)")
}

# ---------------------------
# CPU TEMPERATURE
# ---------------------------
Section "CPU TEMPERATURE"
Status "~" "Reading CPU temperature..." "Yellow"
$CPUTempC="Unavailable"
try {
    $tempWmi=Get-WmiObject -Namespace root\wmi -Class MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
    if ($tempWmi -and $tempWmi.CurrentTemperature) {
        $CPUTempC=[math]::Round((($tempWmi.CurrentTemperature - 2732)/10),1)
        Status "+" "CPU Temp: $CPUTempC C" "Green"
    } else {
        Status "-" "CPU temperature sensor not exposed." "Gray"
        $SkippedItems.Add("CPU Temperature Sensor")
    }
} catch {
    Status "-" "CPU temp error: $($_.Exception.Message)" "Gray"
    $SkippedItems.Add("CPU Temperature (error)")
}

# ---------------------------
# EVENT LOG (72h)
# ---------------------------
Section "EVENT LOG (72h)"
Status "~" "Scanning System log (Critical/Error)..." "Yellow"
try {
    $startTime=(Get-Date).AddHours(-72)
    $events=Get-WinEvent -FilterHashtable @{LogName='System';Level=@(1,2);StartTime=$startTime} -ErrorAction SilentlyContinue
    $ErrCount= if ($events){($events|Measure-Object).Count}else{0}
    if (($ErrCount -is [int]) -and $ErrCount -gt 0){
        Status "!" "System has $ErrCount critical/error events (72h)." "Yellow"
        $EventsHealth="Medium"
    } else {
        Status "+" "No critical/error events last 72h." "Green"
        $EventsHealth="Good"
    }
    if ($ErrCount -gt 0){
        try {
            $recent=$events|Sort-Object TimeCreated -Descending|Select-Object -First 5 Id,LevelDisplayName,ProviderName,TimeCreated,Message
            Add-Content -Path $LogPath -Value "`n-- Recent System Errors (Top 5) --`n$($recent|Format-List|Out-String)"
        } catch {}
    }
} catch {
    Status "-" "Event log read failed." "Gray"
    $EventsHealth="Unknown"
    $ErrCount = 0
    $SkippedItems.Add("Event Log (permissions or unavailable)")
}

# ---------------------------
# PERFORMANCE SNAPSHOT (~6s)
# ---------------------------
Section "PERFORMANCE SNAPSHOT (~6s)"
Status "~" "Sampling performance counters..." "Yellow"

# CPU counters
$CPU_Busy_Pct   = Get-CtrAvg '\Processor(_Total)\% Processor Time' $PerfSamples $PerfInterval
$CPU_Backlog    = Get-CtrAvg '\System\Processor Queue Length'      $PerfSamples $PerfInterval
$CPU_Speed_Pct  = Get-CtrAvg '\Processor Information(_Total)\% Processor Performance' $PerfSamples $PerfInterval
$LogicalCores   = try { ($cpu | Select-Object -First 1).NumberOfLogicalProcessors } catch { [int]$env:NUMBER_OF_PROCESSORS }
$BaseMHz        = try { ($cpu | Select-Object -First 1).MaxClockSpeed } catch { $null }
$CurrMHzWMI     = try { ($cpu | Select-Object -First 1).CurrentClockSpeed } catch { $null }
$CPU_Speed_GHz  = if ($CPU_Speed_Pct -ne $null -and $BaseMHz -ne $null){[math]::Round((($BaseMHz*($CPU_Speed_Pct/100))/1000),2)}elseif($CurrMHzWMI){[math]::Round(($CurrMHzWMI/1000),2)}else{$null}
$CPU_Base_GHz   = if ($BaseMHz){[math]::Round(($BaseMHz/1000),2)}else{$null}
if ($CPU_Backlog -eq $null -and $TreatMissingBacklogAsGood) { $CPU_Backlog = 0 }

$CPUHealthUsage  = if ($CPU_Busy_Pct -eq $null){"Unknown"}elseif($CPU_Busy_Pct -ge $CPU_Usage_Critical_Thresh){"Critical"}elseif($CPU_Busy_Pct -ge $CPU_Usage_Medium_Thresh){"Medium"}else{"Good"}
$CPUHealthBacklog= if ($CPU_Backlog -eq $null){"Unknown"}elseif($CPU_Backlog -gt ($LogicalCores*$CPU_Backlog_Crit_Factor)){"Critical"}elseif($CPU_Backlog -gt ($LogicalCores*$CPU_Backlog_Medium_Factor)){"Medium"}else{"Good"}
$CPUHealth       = Merge-Health3 @($CPUHealthUsage,$CPUHealthBacklog)
$CpuModel        = if ($cpu){($cpu|Select-Object -First 1).Name}else{"Unknown CPU"}

# Memory counters
$RAM_Used_Pct     = Get-CtrAvg '\Memory\% Committed Bytes In Use' $PerfSamples $PerfInterval
$RAM_Avail_MB     = Get-CtrAvg '\Memory\Available MBytes'         $PerfSamples $PerfInterval
$RAM_HardFaultsPS = Get-CtrAvg '\Memory\Page Reads/sec'           $PerfSamples $PerfInterval
$MemUsedHealth    = if ($RAM_Used_Pct -eq $null){"Unknown"}elseif($RAM_Used_Pct -ge $RAM_Used_Critical_Thresh){"Critical"}elseif($RAM_Used_Pct -ge $RAM_Used_Medium_Thresh){"Medium"}else{"Good"}
$AvailRatio       = if ($RAM_Avail_MB -ne $null -and $TotalVisibleMemoryMB -gt 0){$RAM_Avail_MB/$TotalVisibleMemoryMB}else{$null}
$MemAvailHealth   = if ($AvailRatio -eq $null){"Unknown"}elseif($AvailRatio -lt $RAM_Avail_Crit_Ratio){"Critical"}elseif($AvailRatio -lt $RAM_Avail_Medium_Ratio){"Medium"}else{"Good"}
$MemFaultHealth   = if ($RAM_HardFaultsPS -eq $null){"Unknown"}elseif($RAM_HardFaultsPS -gt $RAM_HardFaults_Critical){"Critical"}elseif($RAM_HardFaultsPS -gt $RAM_HardFaults_Medium){"Medium"}else{"Good"}
$MemoryHealth     = Merge-Health3 @($MemUsedHealth,$MemAvailHealth,$MemFaultHealth)

# Disk performance counters (with logical fallback)
$Disk_Busy_Pct = Get-CtrAvg '\PhysicalDisk(_Total)\% Disk Time' $PerfSamples $PerfInterval
$Disk_Queue    = Get-CtrAvg '\PhysicalDisk(_Total)\Avg. Disk Queue Length' $PerfSamples $PerfInterval
$Read_Bps      = Get-CtrAvg '\PhysicalDisk(_Total)\Disk Read Bytes/sec' $PerfSamples $PerfInterval
$Write_Bps     = Get-CtrAvg '\PhysicalDisk(_Total)\Disk Write Bytes/sec' $PerfSamples $PerfInterval
if ($Read_Bps -eq $null)  { $Read_Bps  = Get-CtrAvg '\LogicalDisk(_Total)\Disk Read Bytes/sec'  $PerfSamples $PerfInterval }
if ($Write_Bps -eq $null) { $Write_Bps = Get-CtrAvg '\LogicalDisk(_Total)\Disk Write Bytes/sec' $PerfSamples $PerfInterval }
if ($Disk_Queue -eq $null -and $TreatMissingBacklogAsGood) { $Disk_Queue = 0 }

$Read_MBps   = if ($Read_Bps -ne $null){[math]::Round(($Read_Bps/1MB),1)}else{$null}
$Write_MBps  = if ($Write_Bps -ne $null){[math]::Round(($Write_Bps/1MB),1)}else{$null}

$DiskBusyHealth  = if ($Disk_Busy_Pct -eq $null){"Unknown"}elseif($Disk_Busy_Pct -ge $Disk_Busy_Critical_Thresh){"Critical"}elseif($Disk_Busy_Pct -ge $Disk_Busy_Medium_Thresh){"Medium"}else{"Good"}
$DiskQueueHealth = if ($Disk_Queue -eq $null){"Unknown"}elseif($Disk_Queue -gt $Disk_Queue_Critical_Thresh){"Critical"}elseif($Disk_Queue -gt $Disk_Queue_Medium_Thresh){"Medium"}else{"Good"}
$DiskPerfHealth  = Merge-Health3 @($DiskBusyHealth,$DiskQueueHealth)
if (-not $DiskSmartHealth) { $DiskSmartHealth="Unknown" }
$DiskHealthCombined = Merge-Health3 @($DiskPerfHealth,$DiskSmartHealth)

# Display variables
$cpuBusyText    = if ($CPU_Busy_Pct -ne $null) { $CPU_Busy_Pct } else { "N/A" }
$cpuBacklogText = if ($CPU_Backlog -ne $null) { $CPU_Backlog } else { "N/A" }
$cpuSpeedText   = if ($CPU_Speed_GHz -ne $null) { $CPU_Speed_GHz } else { "N/A" }
$cpuBaseText    = if ($CPU_Base_GHz -ne $null) { $CPU_Base_GHz } else { "N/A" }

$ramUsedText    = if ($RAM_Used_Pct -ne $null) { $RAM_Used_Pct } else { "N/A" }
$ramAvailText   = if ($RAM_Avail_MB -ne $null) { $RAM_Avail_MB } else { "N/A" }
$ramFaultsText  = if ($RAM_HardFaultsPS -ne $null) { $RAM_HardFaultsPS } else { "N/A" }

$diskBusyText   = if ($Disk_Busy_Pct -ne $null) { $Disk_Busy_Pct } else { "N/A" }
$diskQueueText  = if ($Disk_Queue -ne $null) { $Disk_Queue } else { "N/A" }
$diskReadText   = if ($Read_MBps -ne $null) { $Read_MBps } else { "N/A" }
$diskWriteText  = if ($Write_MBps -ne $null) { $Write_MBps } else { "N/A" }

Status "+" ("CPU: Usage {0}% | Backlog {1} thr | Speed {2} GHz (base {3} GHz)" -f $cpuBusyText,$cpuBacklogText,$cpuSpeedText,$cpuBaseText) (HealthColor $CPUHealth)
Status "+" ("Memory: Used {0}% | Avail {1} MB | HardFaults {2}/s | Total {3} GB" -f $ramUsedText,$ramAvailText,$ramFaultsText,$TotalRAMGB) (HealthColor $MemoryHealth)
Status "+" ("Disk: Active {0}% | Backlog {1} | Read {2} MB/s | Write {3} MB/s" -f $diskBusyText,$diskQueueText,$diskReadText,$diskWriteText) (HealthColor $DiskHealthCombined)

if ($Read_MBps -eq $null -or $Write_MBps -eq $null) {
    Status "-" "Disk throughput counters unavailable. If this persists, run 'diskperf -y' and reboot." "Yellow"
}

# Record missing counters (post-fallback)
if ($CPU_Busy_Pct -eq $null){$SkippedItems.Add("CPU Usage Counter")}
if ($CPU_Backlog -eq $null){$SkippedItems.Add("CPU Backlog Counter")}
if ($RAM_Used_Pct -eq $null){$SkippedItems.Add("Memory % Used Counter")}
if ($RAM_Avail_MB -eq $null){$SkippedItems.Add("Memory Available Counter")}
if ($Disk_Busy_Pct -eq $null){$SkippedItems.Add("Disk Busy Counter")}
if ($Disk_Queue -eq $null){$SkippedItems.Add("Disk Queue Counter")}
if ($Read_MBps -eq $null){$SkippedItems.Add("Disk Read Throughput Counter")}
if ($Write_MBps -eq $null){$SkippedItems.Add("Disk Write Throughput Counter")}

# ---------------------------
# TOP PROCESSES (delta snapshot)
# ---------------------------
try {
    $procBefore = Get-Process | Select-Object Id,ProcessName,CPU,IOReadBytes,IOWriteBytes
    Start-Sleep -Seconds $PerfSamples
    $procAfter  = Get-Process | Select-Object Id,ProcessName,CPU,IOReadBytes,IOWriteBytes
    $cpuDelta = foreach ($p in $procAfter) {
        $before = $procBefore | Where-Object Id -eq $p.Id
        if ($before) {
            [PSCustomObject]@{
                ProcessName = $p.ProcessName
                CPU_Seconds = [math]::Round(($p.CPU - $before.CPU),2)
                IOBytes     = (($p.IOReadBytes - $before.IOReadBytes) + ($p.IOWriteBytes - $before.IOWriteBytes))
            }
        }
    }
    $topCPU = $cpuDelta | Sort-Object CPU_Seconds -Descending | Select-Object -First 5
    $topIO  = $cpuDelta | Sort-Object IOBytes -Descending | Select-Object -First 5
    Add-Content -Path $LogPath -Value "`n-- Top Processes by CPU (delta) --`n$($topCPU | Format-Table -AutoSize | Out-String)"
    Add-Content -Path $LogPath -Value "`n-- Top Processes by IO Bytes (delta) --`n$($topIO | Format-Table -AutoSize | Out-String)"
} catch {
    Status "-" "Top process snapshot failed: $($_.Exception.Message)" "Gray"
    $SkippedItems.Add("Top Process Snapshot")
}

# ---------------------------
# BOOT PERFORMANCE
# ---------------------------
Section "BOOT PERFORMANCE"
Status "~" "Analyzing boot performance events..." "Yellow"
$BootHealth = "Unknown"
$BootAvgSeconds = $null
$BootAvgPostBootSeconds = $null
$BootSamples = 0

try {
    $bootEvents = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue | Select-Object -First 10
    if (-not $bootEvents) {
        $bootEvents = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -ErrorAction SilentlyContinue | Where-Object { $_.Id -eq 100 } | Select-Object -First 10
    }
    if ($bootEvents) {
        $bootStats = foreach ($e in $bootEvents) {
            $props = $e.Properties
            if ($props.Count -ge 18) {
                $bootTimeMs = $props[2].Value
                $postBootMs = $props[16].Value
                if ($bootTimeMs -is [int]) {
                    [PSCustomObject]@{
                        BootTimeSeconds     = [math]::Round(($bootTimeMs/1000),2)
                        PostBootSeconds     = if ($postBootMs -is [int]) { [math]::Round(($postBootMs/1000),2) } else { $null }
                        Timestamp           = $e.TimeCreated
                    }
                }
            }
        }
        if ($bootStats) {
            $BootSamples = $bootStats.Count
            $BootAvgSeconds = [math]::Round((($bootStats | Measure-Object BootTimeSeconds -Average).Average),2)
            $BootAvgPostBootSeconds = [math]::Round((($bootStats | Where-Object PostBootSeconds | Measure-Object PostBootSeconds -Average).Average),2)
            if ($BootAvgSeconds -ne $null) {
                $BootHealth = if ($BootAvgSeconds -le $Boot_Good_Thresh) { "Good" }
                               elseif ($BootAvgSeconds -le $Boot_Medium_Thresh) { "Medium" }
                               else { "Critical" }
            }
            Status "+" ("Boot avg: {0}s | PostBoot avg: {1}s | Samples: {2} | Health: {3}" -f (SafeVal $BootAvgSeconds),(SafeVal $BootAvgPostBootSeconds),$BootSamples,$BootHealth) (HealthColor $BootHealth)
            Add-Content -Path $LogPath -Value "`n-- Boot Samples --`n$($bootStats | Format-Table -AutoSize | Out-String)"
        } else {
            Status "-" "Boot events found but parsing yielded no usable samples." "Gray"
            $SkippedItems.Add("Boot performance parsing")
        }
    } else {
        Status "-" "No boot performance events (ID 100) in last 7 days." "Gray"
        $SkippedItems.Add("Boot performance (no events)")
    }
} catch {
    Status "-" "Boot performance analysis error: $($_.Exception.Message)" "Gray"
    $SkippedItems.Add("Boot performance (error)")
}

# ---------------------------
# REPAIRS
# ---------------------------
Section "REPAIRS"
Status "~" "DISM then SFC..." "Yellow"
$FirstDriveLetter = try { ($disks | Select-Object -First 1).DeviceID.TrimEnd(':') } catch { $null }
$DismResult = "Skipped"
try {
    if ($IsAdmin) {
        Status "~" "Running DISM /RestoreHealth ..." "Yellow"
        Start-Process dism.exe -ArgumentList "/Online","/Cleanup-Image","/RestoreHealth","/NoRestart" -NoNewWindow -Wait -PassThru | Out-Null
        $DismResult = "Completed"; Status "+" "DISM completed." "Green"
    } else { $DismResult = "Skipped (no admin)"; AdminSkip "DISM /RestoreHealth" "dism /online /cleanup-image /restorehealth /norestart" }
} catch { $DismResult = "Error"; Status "!" "DISM error: $($_.Exception.Message)" "Red" }
$SfcResult = "Skipped"
try {
    if ($IsAdmin) {
        Status "~" "Running SFC /scannow ..." "Yellow"
        Start-Process sfc.exe -ArgumentList "/scannow" -NoNewWindow -Wait -PassThru | Out-Null
        $SfcResult = "Completed"; Status "+" "SFC completed." "Green"
    } else { $SfcResult = "Skipped (no admin)"; AdminSkip "SFC /scannow" "sfc /scannow" }
} catch { $SfcResult = "Error"; Status "!" "SFC error: $($_.Exception.Message)" "Red" }

# ---------------------------
# CLEANUPS & TWEAKS
# ---------------------------
Section "CLEANUPS & TWEAKS"
Status "~" "Temp, TRIM, DNS/Winsock, StorageSense, TCP, Power plan..." "Yellow"
try {
    foreach ($p in @("$env:TEMP","$env:TMP","C:\Windows\Temp")) {
        if (Test-Path $p) {
            Get-ChildItem -Path $p -Force -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    Status "+" "Temporary files cleaned." "Green"
} catch { Status "!" "Temp cleanup issue: $($_.Exception.Message)" "Red" }
try {
    if ($IsAdmin) {
        if ($FirstDriveLetter) {
            try { Optimize-Volume -DriveLetter $FirstDriveLetter -ReTrim -ErrorAction SilentlyContinue | Out-Null; Status "+" "TRIM requested on $FirstDriveLetter." "Green" }
            catch { Status "-" "TRIM not supported/failed." "Yellow" }
        } else { Status "-" "No primary volume letter for TRIM." "Yellow" }
    } else {
        $trimCmd = if ($FirstDriveLetter) { "Optimize-Volume -DriveLetter $FirstDriveLetter -ReTrim" } else { "Get-Volume | ? DriveLetter | % { Optimize-Volume -DriveLetter $_.DriveLetter -ReTrim }" }
        AdminSkip "TRIM (Optimize-Volume)" $trimCmd
    }
} catch { Status "-" "TRIM step not available." "Yellow" }
Status "-" "Defrag skipped (safe-mode)." "Yellow"
try {
    if ($IsAdmin) { ipconfig /flushdns | Out-Null; netsh winsock reset | Out-Null; Status "+" "DNS flushed & Winsock reset." "Green" }
    else { AdminSkip "DNS flush & Winsock reset" "ipconfig /flushdns`r`nnetsh winsock reset" }
} catch { Status "!" "DNS/Winsock error: $($_.Exception.Message)" "Red" }
try {
    if ($IsAdmin) {
        $ssKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"
        if (Test-Path $ssKey) {
            New-ItemProperty -Path $ssKey -Name "01" -Value 1 -PropertyType DWord -Force | Out-Null
            Status "+" "Storage Sense basic toggle applied." "Green"
        } else { Status "-" "Storage Sense key not found." "Yellow" }
    } else { AdminSkip "Enable Storage Sense" "reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy /v 01 /t REG_DWORD /d 1 /f" }
} catch { Status "-" "Storage Sense change failed." "Yellow" }
try {
    if ($IsAdmin) {
        netsh interface tcp set global autotuninglevel=normal | Out-Null
        netsh interface tcp set global congestionprovider=ctcp | Out-Null
        Status "+" "TCP autotuning & CTCP applied." "Green"
    } else { AdminSkip "TCP autotuning + CTCP" "netsh interface tcp set global autotuninglevel=normal`r`nnetsh interface tcp set global congestionprovider=ctcp" }
} catch { Status "-" "Network tweaks failed (non-fatal)." "Yellow" }

# ---------------------------
# GRAPHICS / GAMING TOGGLES
# ---------------------------
Section "GRAPHICS / GAMING"
try {
    if ($videoCtrls) {
        $gpuInfo = $videoCtrls | ForEach-Object {
            $age = "N/A"; try { $parsed=[datetime]::Parse($_.DriverDate); $age=(New-TimeSpan -Start $parsed -End (Get-Date)).Days } catch {}
            [PSCustomObject]@{Name=$_.Name;DriverVersion=$_.DriverVersion;DriverAgeDays=$age}
        }
        Add-Content -Path $LogPath -Value "`n-- GPU Driver Age --`n$($gpuInfo | Format-Table -AutoSize | Out-String)"
    }
} catch {
    Status "-" "GPU driver age retrieval failed." "Gray"
    $SkippedItems.Add("GPU Driver Age")
}
$HAGS_State="Unchanged"
if ($EnableHAGS) {
    if (-not $IsAdmin) { AdminSkip "Enable HAGS" "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 2" }
    else {
        try { New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -PropertyType DWord -Value 2 -Force | Out-Null
            Status "+" "HAGS enabled." "Green"; $HAGS_State="Enabled" } catch { Status "-" "Enable HAGS failed: $($_.Exception.Message)" "Yellow"; $SkippedItems.Add("HAGS enable failure") }
    }
} elseif ($DisableHAGS) {
    if (-not $IsAdmin) { AdminSkip "Disable HAGS" "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -Value 1" }
    else {
        try { New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -PropertyType DWord -Value 1 -Force | Out-Null
            Status "+" "HAGS disabled." "Green"; $HAGS_State="Disabled" } catch { Status "-" "Disable HAGS failed: $($_.Exception.Message)" "Yellow"; $SkippedItems.Add("HAGS disable failure") }
    }
} else { $SkippedItems.Add("HAGS unchanged") }

$GameBar_State="Unchanged"
if ($DisableGameBarCapture) {
    try {
        New-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -PropertyType DWord -Value 0 -Force | Out-Null
        if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR")) {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
        }
        New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -PropertyType DWord -Value 0 -Force | Out-Null
        Status "+" "Game Bar capture disabled." "Green"; $GameBar_State="Disabled"
    } catch { Status "-" "Disable Game Bar failed: $($_.Exception.Message)" "Yellow"; $SkippedItems.Add("Game Bar disable failure") }
} elseif ($EnableGameBarCapture) {
    try {
        New-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -PropertyType DWord -Value 1 -Force | Out-Null
        if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR")) {
            New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force | Out-Null
        }
        New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -PropertyType DWord -Value 1 -Force | Out-Null
        Status "+" "Game Bar capture enabled." "Green"; $GameBar_State="Enabled"
    } catch { Status "-" "Enable Game Bar failed: $($_.Exception.Message)" "Yellow"; $SkippedItems.Add("Game Bar enable failure") }
} else { $SkippedItems.Add("Game Bar capture unchanged") }

# ---------------------------
# POWER MODE
# ---------------------------
Section "POWER MODE"
$OriginalPowerScheme = $null
try {
    $activeRaw = (powercfg /getactivescheme) 2>&1
    $OriginalPowerScheme = ($activeRaw -match "([A-F0-9\-]{36})") | ForEach-Object { $Matches[1] }
} catch {}
if ($IsAdmin) {
    try {
        if ($PowerMode -eq "High") {
            powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
            Status "+" "Applied High Performance power plan." "Green"
        } else {
            powercfg /setactive SCHEME_BALANCED | Out-Null
            Status "+" "Applied Balanced power plan." "Green"
        }
    } catch {
        Status "-" "Power plan change failed: $($_.Exception.Message)" "Yellow"
        $SkippedItems.Add("Power plan change failure")
    }
} else {
    $powerCmd = if ($PowerMode -eq "High") { "powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" } else { "powercfg /setactive SCHEME_BALANCED" }
    AdminSkip "Power plan change" $powerCmd
}

# ---------------------------
# WINDOWS UPDATE CACHE
# ---------------------------
Section "WINDOWS UPDATE CACHE"
Status "~" "Clearing WU download cache (if admin)..." "Yellow"
$WUResetResult="Skipped"
try {
    if ($IsAdmin) {
        try { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue } catch {}
        $sd="C:\Windows\SoftwareDistribution\Download"
        if (Test-Path $sd) {
            Get-ChildItem -Path $sd -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            $WUResetResult="Cleared"; Status "+" "WU download cache cleared." "Green"
        } else { $WUResetResult="NoCache"; Status "-" "WU download folder not found." "Gray" }
        try { Start-Service wuauserv -ErrorAction SilentlyContinue } catch {}
    } else {
        AdminSkip "Windows Update cache cleanup" "Stop-Service wuauserv -Force; Remove-Item -Recurse -Force 'C:\Windows\SoftwareDistribution\Download\*' -ErrorAction SilentlyContinue; Start-Service wuauserv"
        $WUResetResult="Skipped (no admin)"
    }
} catch { Status "-" "WU cleanup failed: $($_.Exception.Message)" "Yellow" }

# ---------------------------
# STARTUP OPTIMIZATION (safe & reversible)
# ---------------------------
Section "STARTUP OPTIMIZATION"
$StartupOptimized = $false
if ($ApplyStartupOptimization) {
    if (-not $IsAdmin) {
        AdminSkip "Startup Optimization" "Run elevated with -ApplyStartupOptimization"
    } else {
        Status "~" "Auditing startup entries..." "Yellow"
        try {
            $entries = @()

            # Registry Run keys (64-bit + WOW6432Node)
            $runKeys = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            )
            if ([Environment]::Is64BitOperatingSystem) {
                $runKeys += 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
            }
            foreach ($rk in $runKeys) {
                if (Test-Path $rk) {
                    try {
                        $item = Get-Item -Path $rk -ErrorAction Stop
                        $names = $item.GetValueNames() | Where-Object { $_ -and $_ -ne '(Default)' }
                        foreach ($name in $names) {
                            try {
                                $val = $item.GetValue($name)
                                if ($null -ne $val -and -not [string]::IsNullOrWhiteSpace("$val")) {
                                    $entries += [PSCustomObject]@{
                                        Source  = "RunKey"
                                        Root    = $rk
                                        Name    = $name
                                        Command = "$val"
                                    }
                                }
                            } catch {
                                Status "-" ("Failed reading value '{0}' from {1}: {2}" -f $name,$rk,$_.Exception.Message) "Gray"
                            }
                        }
                    } catch {
                        Status "-" ("Failed opening {0}: {1}" -f $rk,$_.Exception.Message) "Gray"
                    }
                }
            }

            # Startup folders
            $startupFolderPaths = @(
                "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp",
                "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
            )
            foreach ($sf in $startupFolderPaths) {
                if (Test-Path $sf) {
                    Get-ChildItem -Path $sf -File -ErrorAction SilentlyContinue | ForEach-Object {
                        if ($null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.FullName)) {
                            $entries += [PSCustomObject]@{
                                Source  = "StartupFolder"
                                Root    = $sf
                                Name    = $_.Name
                                Command = $_.FullName
                            }
                        }
                    }
                }
            }

            # Win32_StartupCommand (audit-only)
            try {
                $startupCmds = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
                if ($startupCmds) {
                    foreach ($sc in $startupCmds) {
                        if ($sc -and -not [string]::IsNullOrWhiteSpace($sc.Command)) {
                            $entries += [PSCustomObject]@{
                                Source  = "Win32_StartupCommand"
                                Root    = $sc.Location
                                Name    = $sc.Name
                                Command = $sc.Command
                            }
                        }
                    }
                }
            } catch {
                Status "-" "Win32_StartupCommand audit failed (non-fatal)." "Gray"
            }

            # Classification
            $classified = $entries |
                Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Command) } |
                ForEach-Object {
                    $cmd = $_.Command
                    $cat = "Misc"
                    if ($cmd -match "(?i)\b(OneDrive|Dropbox|GoogleDrive)\b") { $cat="CloudSync" }
                    elseif ($cmd -match "(?i)\b(Security|Defender|ESET|Avast|Sophos|McAfee|Kaspersky)\b") { $cat="Security" }
                    elseif ($cmd -match "(?i)\b(NVIDIA|AMD|Radeon|Intel)\b") { $cat="GPU" }
                    elseif ($cmd -match "(?i)\bMicrosoft\b") { $cat="Microsoft" }
                    elseif ($cmd -match "(?i)\b(Update|Updater|Telemetry)\b") { $cat="Updater" }
                    [PSCustomObject]@{
                        Source   = $_.Source
                        Root     = $_.Root
                        Name     = $_.Name
                        Command  = $cmd
                        Category = $cat
                    }
                }

            Add-Content -Path $LogPath -Value "`n-- Startup Entries (Audit) --`n$($classified | Format-Table -AutoSize | Out-String)"

            $candidates = $classified | Where-Object { $_.Category -in @("Updater","Telemetry","Misc") }

            if (-not $candidates -or $candidates.Count -eq 0) {
                Status "-" "No non-critical startup items found to optimize." "Gray"
            } else {
                Status "~" ("Found {0} candidate startup items." -f $candidates.Count) "Yellow"
                foreach ($c in $candidates) {
                    $promptMsg = "Disable startup item: {0} ({1})?" -f $c.Name,$c.Command
                    $doDisable = if ($ForceStartupOptimization) { $true } else {
                        $resp = Read-Host "$promptMsg (Y/N)"; ($resp -match '^[Yy]')
                    }

                    if (-not $doDisable) {
                        Status "-" ("Skipped disabling: {0}" -f $c.Name) "Gray"
                        continue
                    }

                    switch ($c.Source) {
                        "RunKey" {
                            try {
                                $disabledKey = ($c.Root -replace "\\Run$","") + "\Run_DISABLED"
                                if (-not (Test-Path $disabledKey)) { New-Item -Path $disabledKey -Force | Out-Null }
                                $val = (Get-Item -Path $c.Root).GetValue($c.Name)
                                if ($null -ne $val) {
                                    New-ItemProperty -Path $disabledKey -Name $c.Name -Value $val -PropertyType String -Force | Out-Null
                                    Remove-ItemProperty -Path $c.Root -Name $c.Name -Force
                                    Status "+" ("Disabled RunKey: {0}" -f $c.Name) "Green"
                                    $StartupOptimized = $true
                                } else {
                                    Status "-" ("RunKey value empty, skipped: {0}" -f $c.Name) "Gray"
                                }
                            } catch {
                                Status "-" ("Failed to disable RunKey {0}: {1}" -f $c.Name,$_.Exception.Message) "Yellow"
                            }
                        }
                        "StartupFolder" {
                            try {
                                $newName = $c.Name + ".disabled"
                                Rename-Item -Path $c.Command -NewName $newName -ErrorAction SilentlyContinue
                                Status "+" ("Renamed startup file: {0}" -f $c.Name) "Green"
                                $StartupOptimized = $true
                            } catch {
                                Status "-" ("Failed to rename startup file {0}: {1}" -f $c.Name,$_.Exception.Message) "Yellow"
                            }
                        }
                        default {
                            Status "-" ("Skipped disabling {0} (source {1}; manual review)." -f $c.Name,$c.Source) "Gray"
                        }
                    }
                }
            }
        } catch {
            Status "!" "Startup optimization failed: $($_.Exception.Message)" "Red"
            $SkippedItems.Add("Startup Optimization (error)")
        }
    }
} else {
    Status "-" "Startup optimization not requested (-ApplyStartupOptimization)." "Gray"
    $SkippedItems.Add("Startup Optimization (not requested)")
}

# ---------------------------
# DEEP CLEAN
# ---------------------------
Section "DEEP CLEAN"
if ($DeepClean) {
    if (-not $IsAdmin) {
        AdminSkip "Deep Clean operations" "Run elevated with -DeepClean"
    } else {
        Status "~" "Deep clean requested; prompting for each action..." "Yellow"
        if (Prompt-YesNo "Run DISM /StartComponentCleanup?" $DeepCleanAutoYes) {
            try { Start-Process dism.exe -ArgumentList "/Online","/Cleanup-Image","/StartComponentCleanup","/NoRestart" -NoNewWindow -Wait -PassThru | Out-Null; Status "+" "Component cleanup completed." "Green"; $DeepCleanActions.Add("ComponentCleanup") }
            catch { Status "-" "Component cleanup failed." "Yellow" }
        } else { Status "-" "Component cleanup skipped." "Gray" }

        $doCache = "C:\Windows\SoftwareDistribution\DeliveryOptimization\Cache"
        if (Test-Path $doCache -and (Prompt-YesNo "Clear Delivery Optimization cache?" $DeepCleanAutoYes)) {
            try { Get-ChildItem -Path $doCache -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue; Status "+" "Delivery Optimization cache cleared." "Green"; $DeepCleanActions.Add("DeliveryOptimizationCache") }
            catch { Status "-" "DO cache cleanup failed." "Yellow" }
        } else { Status "-" "DO cache skipped or path missing." "Gray" }

        $werQueue = "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"
        if (Test-Path $werQueue -and (Prompt-YesNo "Clear Windows Error Reporting queue?" $DeepCleanAutoYes)) {
            try { Get-ChildItem -Path $werQueue -Force -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue; Status "+" "WER queue cleared." "Green"; $DeepCleanActions.Add("WERQueue") }
            catch { Status "-" "WER queue cleanup failed." "Yellow" }
        } else { Status "-" "WER queue skipped or missing." "Gray" }

        $prefetch = "C:\Windows\Prefetch"
        if (Test-Path $prefetch) {
            $pfSizeMB = (Get-ChildItem -Path $prefetch -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
            $pfRounded = [math]::Round($pfSizeMB,1)
            Status "~" "Prefetch size: $pfRounded MB" "Yellow"
            if ($pfSizeMB -gt $PrefetchClearThresholdMB -and (Prompt-YesNo "Clear Prefetch (size > $PrefetchClearThresholdMB MB)?" $DeepCleanAutoYes)) {
                try { Get-ChildItem -Path $prefetch -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue; Status "+" "Prefetch cleared." "Green"; $DeepCleanActions.Add("PrefetchCleared") }
                catch { Status "-" "Prefetch clear failed." "Yellow" }
            } else { Status "-" "Prefetch retained." "Gray" }
        } else { Status "-" "Prefetch path missing." "Gray" }

        if (Prompt-YesNo "Empty Recycle Bin?" $DeepCleanAutoYes) {
            try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Status "+" "Recycle Bin emptied." "Green"; $DeepCleanActions.Add("RecycleBin") }
            catch { Status "-" "Recycle Bin clear failed." "Yellow" }
        } else { Status "-" "Recycle Bin left intact." "Gray" }
    }
} else {
    Status "-" "Deep clean not requested (-DeepClean)." "Gray"
    $SkippedItems.Add("Deep Clean (not requested)")
}

# ---------------------------
# SUMMARY
# ---------------------------
Section "SUMMARY"
Status "~" "Computing health tiers & saving reports..." "Yellow"
if ($ErrCount -eq $null -or $ErrCount -isnot [int]) { $ErrCount = 0 }
$OverallStatus = OverallHealth -CPU $CPUHealth -Memory $MemoryHealth -Disk $DiskHealthCombined -Events $EventsHealth -DiskSmart $DiskSmartHealth -Boot $BootHealth
$UptimeStr = "{0}d {1}h {2}m" -f $uptime.Days,$uptime.Hours,$uptime.Minutes

# GPU display strings
$GPUModels = if ($videoCtrls){($videoCtrls | Select-Object -ExpandProperty Name) -join "; "}else{"N/A"}
$GPUDriverAges = if ($videoCtrls){
    ($videoCtrls | ForEach-Object {
        try { $d=[datetime]::Parse($_.DriverDate); (New-TimeSpan -Start $d -End (Get-Date)).Days } catch {"N/A"}
    }) -join "; "
}else{"N/A"}

$StartupOptText = if ($ApplyStartupOptimization -and $StartupOptimized) { "Applied" } elseif ($ApplyStartupOptimization) { "No changes" } else { "Not requested" }
$DeepCleanText  = if ($DeepCleanActions.Count -gt 0) { $DeepCleanActions -join "; " } elseif ($DeepClean) { "Requested (no actions taken)" } else { "Not requested" }

# Full object
$ReportObj = [PSCustomObject]@{
    Timestamp             = (Get-Date).ToString("s")
    Script_Version        = $ScriptVersion
    PCName                = $PCName
    User                  = $env:USERNAME
    OS                    = if ($os){$os.Caption+" "+$os.OSArchitecture}else{"Unknown"}
    OSBuild               = if ($os){$os.Version}else{"Unknown"}
    Uptime                = $UptimeStr

    Device_Manufacturer   = $DeviceManufacturer
    Device_Model          = $DeviceModel
    System_Vendor         = $SystemVendor
    System_ProductName    = $SystemProductName
    Identity_Product      = $IdentityProductDisplay

    CPU_Model             = $CpuModel
    CPU_Manufacturer      = if ($cpu){($cpu|Select-Object -First 1).Manufacturer}else{"Unknown"}
    CPU_Base_GHz          = $CPU_Base_GHz
    CPU_Current_GHz       = $CPU_Speed_GHz
    CPU_Usage_Pct         = $CPU_Busy_Pct
    CPU_Backlog_Threads   = $CPU_Backlog
    CPU_Speed_PctOfBase   = $CPU_Speed_Pct
    CPU_Health            = $CPUHealth

    Memory_Total_GB       = $TotalRAMGB
    Memory_TotalVisible_MB= $TotalVisibleMemoryMB
    Memory_Free_MB        = $FreePhysicalMB
    Memory_Used_Pct       = $RAM_Used_Pct
    Memory_Available_MB   = $RAM_Avail_MB
    Memory_HardFaults_s   = $RAM_HardFaultsPS
    Memory_Health         = $MemoryHealth

    Disk_Active_Pct       = $Disk_Busy_Pct
    Disk_Backlog          = $Disk_Queue
    Disk_Read_MB_s        = $Read_MBps
    Disk_Write_MB_s       = $Write_MBps
    Disk_SMART_Health     = $DiskSmartHealth
    Disk_Perf_Health      = $DiskPerfHealth
    Disk_Overall_Health   = $DiskHealthCombined
    Disk_Free_GB          = if ($disks){[math]::Round(($disks|Select-Object -First 1).FreeSpace/1GB,1)}else{"N/A"}

    Boot_Avg_Seconds          = $BootAvgSeconds
    Boot_Avg_PostBoot_Seconds = $BootAvgPostBootSeconds
    Boot_Samples              = $BootSamples
    Boot_Health               = $BootHealth

    EventErrors_72h       = $ErrCount
    EventLog_Health       = $EventsHealth

    CPU_Temp_C            = $CPUTempC

    GPU_Models            = $GPUModels
    GPU_Driver_Age_Days   = $GPUDriverAges

    DISM_Result           = $DismResult
    SFC_Result            = $SfcResult
    WindowsUpdateCache    = $WUResetResult
    StartupOptimized      = $StartupOptText
    DeepCleanPerformed    = $DeepCleanText
    HAGS_State            = $HAGS_State
    GameBarCapture_State  = $GameBar_State
    PowerModeApplied      = $PowerMode
    RepairsPerformed      = "DISM,SFC,TempCleanup,TRIMAttempt,DNSFlush,WinsockReset,PowerPlan"
    Skipped_Items         = if ($SkippedItems.Count -gt 0){$SkippedItems -join "; "}else{""}
    Overall_Health        = $OverallStatus
}

# Compact object
$CompactObj = [PSCustomObject]([ordered]@{
    Identity_Timestamp    = (Get-Date).ToString("s")
    Identity_Version      = $ScriptVersion
    Identity_PC           = $PCName
    Identity_User         = $env:USERNAME
    Identity_OS           = if ($os){$os.Caption+" "+$os.OSArchitecture}else{"Unknown"}
    Identity_Build        = if ($os){$os.Version}else{"Unknown"}
    Identity_Uptime       = $UptimeStr
    Identity_Manufacturer = $DeviceManufacturer
    Identity_Model        = $DeviceModel
    Identity_Product      = $IdentityProductDisplay

    CPU_Model             = $CpuModel
    CPU_Manufacturer      = if ($cpu){($cpu|Select-Object -First 1).Manufacturer}else{"Unknown"}
    CPU_Usage_Pct         = $CPU_Busy_Pct
    CPU_Speed_GHz         = $CPU_Speed_GHz
    CPU_Base_GHz          = $CPU_Base_GHz
    CPU_Backlog_Threads   = $CPU_Backlog
    CPU_Temp_C            = $CPUTempC
    CPU_Health            = $CPUHealth

    Memory_Total_GB       = $TotalRAMGB
    Memory_Used_Pct       = $RAM_Used_Pct
    Memory_Available_MB   = $RAM_Avail_MB
    Memory_HardFaults_s   = $RAM_HardFaultsPS
    Memory_Health         = $MemoryHealth

    Disk_SMART_Health     = $DiskSmartHealth
    Disk_Active_Pct       = $Disk_Busy_Pct
    Disk_Backlog          = $Disk_Queue
    Disk_Read_MB_s        = $Read_MBps
    Disk_Write_MB_s       = $Write_MBps
    Disk_Free_GB          = if ($disks){[math]::Round(($disks|Select-Object -First 1).FreeSpace/1GB,1)}else{"N/A"}
    Disk_Health           = $DiskHealthCombined

    Boot_Avg_s            = $BootAvgSeconds
    Boot_PostBoot_Avg_s   = $BootAvgPostBootSeconds
    Boot_Samples          = $BootSamples
    Boot_Health           = $BootHealth

    Events_SystemErrors_72h = $ErrCount
    Events_Health         = $EventsHealth

    Network_IP            = $IP
    Network_Gateway       = $Gateway
    Network_DNS           = $DNS

    Toggles_PowerMode     = $PowerMode
    Toggles_HAGS          = $HAGS_State
    Toggles_GameBar       = $GameBar_State
    Optimization_Startup  = $StartupOptText
    Cleanup_Deep          = $DeepCleanText

    Overall_Health        = $OverallStatus
    Skipped_Items         = if ($SkippedItems.Count -gt 0){$SkippedItems -join "; "}else{""}
})

# Save CSVs
try {
    $ReportObj  | Export-Csv -Path $CSVPath        -NoTypeInformation -Force -Encoding UTF8 -UseCulture
    $CompactObj | Export-Csv -Path $CSVCompactPath -NoTypeInformation -Force -Encoding UTF8 -UseCulture
    Status "+" "CSV saved: $CSVPath" "Green"
    Status "+" "Compact CSV saved: $CSVCompactPath" "Green"
} catch { Status "!" "CSV save failed: $($_.Exception.Message)" "Red" }

# Append full summary to full log
try {
    Add-Content -Path $LogPath -Value "`n-- Summary Object --`n$($ReportObj | Out-String)"
    if ($SkippedItems.Count -gt 0){ Add-Content -Path $LogPath -Value ("`nSkipped / Unavailable:`n - "+($SkippedItems -join "`n - ")) }
    Status "+" "Summary appended to full log." "Green"
} catch { Status "!" "Failed to append summary." "Red" }

# Build compact log (grouped)
try {
    $compactText = @"
=== PC Health Compact Report ===
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
PC: $PCName

[Identity]
Product: $($CompactObj.Identity_Product)
Manufacturer: $($CompactObj.Identity_Manufacturer)   Model: $($CompactObj.Identity_Model)
OS: $($CompactObj.Identity_OS)   Build: $($CompactObj.Identity_Build)   Uptime: $($CompactObj.Identity_Uptime)

[CPU]
Model: $($CompactObj.CPU_Model)
Usage: $(SafeVal $CompactObj.CPU_Usage_Pct "%")   Speed: $(SafeVal $CompactObj.CPU_Speed_GHz " GHz") (base $(SafeVal $CompactObj.CPU_Base_GHz " GHz"))   Backlog: $(SafeVal $CompactObj.CPU_Backlog_Threads) thr   Temp: $(SafeVal $CompactObj.CPU_Temp_C " C")   Health: $($CompactObj.CPU_Health)

[Memory]
Total: $(SafeVal $CompactObj.Memory_Total_GB " GB")   Used: $(SafeVal $CompactObj.Memory_Used_Pct "%")   Free: $(SafeVal $CompactObj.Memory_Available_MB " MB")   Faults: $(SafeVal $CompactObj.Memory_HardFaults_s "/s")   Health: $($CompactObj.Memory_Health)

[Disk]
SMART: $($CompactObj.Disk_SMART_Health)   Active: $(SafeVal $CompactObj.Disk_Active_Pct "%")   Queue: $(SafeVal $CompactObj.Disk_Backlog)   R/W: $(SafeVal $CompactObj.Disk_Read_MB_s " MB/s") / $(SafeVal $CompactObj.Disk_Write_MB_s " MB/s")   Free: $(SafeVal $CompactObj.Disk_Free_GB " GB")   Health: $($CompactObj.Disk_Health)

[Boot]
Avg: $(SafeVal $CompactObj.Boot_Avg_s " s")   Post-boot: $(SafeVal $CompactObj.Boot_PostBoot_Avg_s " s")   Samples: $(SafeVal $CompactObj.Boot_Samples)   Health: $($CompactObj.Boot_Health)

[Events]
System errors (72h): $(SafeVal $CompactObj.Events_SystemErrors_72h)   Health: $($CompactObj.Events_Health)

[Network]
IP: $($CompactObj.Network_IP)   GW: $($CompactObj.Network_Gateway)   DNS: $($CompactObj.Network_DNS)

[Toggles / Actions]
Power mode: $($CompactObj.Toggles_PowerMode)   HAGS: $($CompactObj.Toggles_HAGS)   Game Bar: $($CompactObj.Toggles_GameBar)   Startup opt: $($CompactObj.Optimization_Startup)   Deep clean: $($CompactObj.Cleanup_Deep)

[Overall]
Overall health: $($CompactObj.Overall_Health)
Skipped/Unavailable: $($CompactObj.Skipped_Items)
"@
    $compactText | Out-File -FilePath $LogCompactPath -Encoding UTF8 -Force
    Status "+" "Compact log saved: $LogCompactPath" "Green"
} catch {
    Status "!" "Failed to write compact log: $($_.Exception.Message)" "Red"
}

# Restore original power plan unless user wants to keep new plan
if ($OriginalPowerScheme -and $IsAdmin -and -not $KeepNewPowerPlan) {
    try { powercfg /setactive $OriginalPowerScheme | Out-Null; Status "+" "Original power plan restored." "Green" }
    catch { Status "-" "Failed to restore original power plan." "Yellow" }
} elseif ($KeepNewPowerPlan) {
    Status "-" "Keeping new power plan as per -KeepNewPowerPlan." "Yellow"
}

# ---------------------------
# FINAL DASHBOARD (grouped)
# ---------------------------
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "               HEALTH CHECK REPORT           " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

function PrintRow { param($Label,$Value,$State="None")
    $color = if ($State -eq "None") {"White"} else { HealthColor $State }
    Write-Host ("{0,-25} : {1}" -f $Label,$Value) -ForegroundColor $color
}
$CpuTempState = if ($CPUTempC -is [double]) { if ($CPUTempC -gt $CPU_Temp_Critical) { "Critical" } else { "Good" } } else { "Unknown" }

Write-Host "-- System Hardware and Identity: Identity, CPU, Memory, Disk, GPU --" -ForegroundColor DarkCyan

# Identity
Write-Host "   Identity" -ForegroundColor DarkGray
PrintRow "Product"       (SafeVal $ReportObj.Identity_Product)
PrintRow "Manufacturer"  (SafeVal $ReportObj.Device_Manufacturer)
PrintRow "Model"         (SafeVal $ReportObj.Device_Model)
PrintRow "OS"            $ReportObj.OS
PrintRow "Build"         $ReportObj.OSBuild
PrintRow "Uptime"        $ReportObj.Uptime

# CPU
Write-Host "   CPU" -ForegroundColor DarkGray
PrintRow "Model"        $ReportObj.CPU_Model $CPUHealth
PrintRow "Usage (%)"    (SafeVal $ReportObj.CPU_Usage_Pct) $CPUHealth
PrintRow "Backlog"      (SafeVal $ReportObj.CPU_Backlog_Threads) $CPUHealth
PrintRow "Speed (GHz)"  (SafeVal $ReportObj.CPU_Current_GHz) $CPUHealth
PrintRow "% of Base"    (SafeVal $ReportObj.CPU_Speed_PctOfBase "%") $CPUHealth
PrintRow "Base (GHz)"   (SafeVal $ReportObj.CPU_Base_GHz)
PrintRow "Temp (C)"     (SafeVal $ReportObj.CPU_Temp_C) $CpuTempState

# Memory
Write-Host "   Memory" -ForegroundColor DarkGray
PrintRow "Total (GB)"   (SafeVal $ReportObj.Memory_Total_GB)
PrintRow "Used (%)"     (SafeVal $ReportObj.Memory_Used_Pct "%") $ReportObj.Memory_Health
PrintRow "Avail (MB)"   (SafeVal $ReportObj.Memory_Available_MB) $ReportObj.Memory_Health
PrintRow "HardFaults/s" (SafeVal $ReportObj.Memory_HardFaults_s) $ReportObj.Memory_Health
PrintRow "Health"       $ReportObj.Memory_Health $ReportObj.Memory_Health

# Disk
Write-Host "   Disk" -ForegroundColor DarkGray
PrintRow "SMART"        $ReportObj.Disk_SMART_Health $DiskSmartHealth
PrintRow "Active (%)"   (SafeVal $ReportObj.Disk_Active_Pct "%") $DiskPerfHealth
PrintRow "Backlog"      (SafeVal $ReportObj.Disk_Backlog) $DiskPerfHealth
PrintRow "Read MB/s"    (SafeVal $ReportObj.Disk_Read_MB_s) $DiskPerfHealth
PrintRow "Write MB/s"   (SafeVal $ReportObj.Disk_Write_MB_s) $DiskPerfHealth
PrintRow "Free (GB)"    (SafeVal $ReportObj.Disk_Free_GB)
PrintRow "Disk Health"  $ReportObj.Disk_Overall_Health $DiskHealthCombined

# GPU
Write-Host "   GPU / Integrated graphics" -ForegroundColor DarkGray
PrintRow "GPU Models"     $ReportObj.GPU_Models
PrintRow "Driver Age (d)" $ReportObj.GPU_Driver_Age_Days

Write-Host "-- System Performance and Maintenance: Boot, Events, Repairs/Tweaks, Skipped, Overall --" -ForegroundColor DarkCyan

# Boot
Write-Host "   Boot" -ForegroundColor DarkGray
PrintRow "Avg Boot (s)"     (SafeVal $ReportObj.Boot_Avg_Seconds) $ReportObj.Boot_Health
PrintRow "Avg PostBoot (s)" (SafeVal $ReportObj.Boot_Avg_PostBoot_Seconds) $ReportObj.Boot_Health
PrintRow "Boot Samples"     (SafeVal $ReportObj.Boot_Samples)
PrintRow "Boot Health"      $ReportObj.Boot_Health $ReportObj.Boot_Health

# Events
Write-Host "   Events (72h)" -ForegroundColor DarkGray
PrintRow "Critical/Error Count" (SafeVal $ReportObj.EventErrors_72h) $ReportObj.EventLog_Health

# Repairs / Tweaks
Write-Host "   Repairs / Tweaks" -ForegroundColor DarkGray
PrintRow "DISM"         $ReportObj.DISM_Result
PrintRow "SFC"          $ReportObj.SFC_Result
PrintRow "WU Cache"     $ReportObj.WindowsUpdateCache
PrintRow "Power Mode"   $ReportObj.PowerModeApplied
PrintRow "HAGS"         $ReportObj.HAGS_State
PrintRow "Game Bar"     $ReportObj.GameBarCapture_State
PrintRow "Startup Opt"  $ReportObj.StartupOptimized
PrintRow "DeepClean"    $ReportObj.DeepCleanPerformed

# Skipped / Unavailable
if ($SkippedItems.Count -gt 0) {
    Write-Host "   Skipped / Unavailable" -ForegroundColor DarkGray
    foreach ($sk in $SkippedItems) { PrintRow $sk "" "Unknown" }
}

# Overall
Write-Host "   Overall" -ForegroundColor DarkGray
PrintRow "Overall Health" $ReportObj.Overall_Health $ReportObj.Overall_Health

Write-Host ("CSV: {0}" -f $CSVPath) -ForegroundColor White
Write-Host ("Compact CSV: {0}" -f $CSVCompactPath) -ForegroundColor White
Write-Host ("Full Log: {0}" -f $LogPath) -ForegroundColor White
Write-Host ("Compact Log: {0}" -f $LogCompactPath) -ForegroundColor White
if (Test-Path $AdminTodoPath) { Write-Host ("Admin To-Do: {0}" -f $AdminTodoPath) -ForegroundColor Yellow }

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Scan complete." -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
# End of script