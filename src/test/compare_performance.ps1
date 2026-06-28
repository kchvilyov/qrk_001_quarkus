<#
.SYNOPSIS
    Скрипт для сравнения производительности Quarkus и Spring Boot
.DESCRIPTION
    Запускает оба приложения, измеряет время запуска и потребление памяти,
    выполняет тестовые запросы и завершает процессы.
#>

# --- Конфигурация ---
$QuarkusPath = "C:\Projects\ws_IBS\qrk_001\qrk_001_quarkus\target\quarkus-app"
$SpringPath = "C:\Projects\ws_IBS\qrk_001\qrk_001_spring\target"

$QuarkusJar = "quarkus-run.jar"
$SpringJar = "qrk_001_spring-0.0.1-SNAPSHOT.jar"

$QuarkusPort = 8080
$SpringPort = 8081

$QuarkusMaxMem = "128m"
$SpringMaxMem = "128m"

$TestEndpoint = "/hello"

# --- Функции ---
function Log-Start {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Log-Success {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Green
}

function Log-Error {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Red
}

function Get-ProcessMemory {
    param([string]$ProcessName)

    $process = Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "java.exe" -and $_.CommandLine -like "*$ProcessName*"
    } | Select-Object -First 1

    if ($process) {
        $memoryMB = [math]::round($process.WorkingSetSize / 1MB, 2)
        return $memoryMB
    }
    return $null
}

function Wait-For-Server {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 30
    )

    $startTime = Get-Date
    while ($true) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                return $true
            }
        } catch {
            # Игнорируем ошибки, сервер ещё не готов
        }

        if ((Get-Date) - $startTime -gt (New-TimeSpan -Seconds $TimeoutSeconds)) {
            return $false
        }
        Start-Sleep -Milliseconds 500
    }
}

function Start-And-Measure {
    param(
        [string]$Name,
        [string]$Path,
        [string]$JarFile,
        [int]$Port,
        [string]$MaxMem,
        [string]$ProcessMarker,
        [string]$LogFile
    )

    Log-Start "Запуск $Name..."

    # Убеждаемся, что порт свободен
    $existingProcess = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
    if ($existingProcess) {
        Log-Error "Порт $Port уже занят. Завершите процесс и повторите запуск."
        return $null
    }

    $startTime = Get-Date

    # Запускаем процесс
    $process = Start-Process -FilePath "java" -ArgumentList "-Xmx$MaxMem -jar $JarFile" -WorkingDirectory $Path -PassThru -NoNewWindow -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err"

    # Ждём запуска
    $url = "http://localhost:$Port$TestEndpoint"
    if (Wait-For-Server -Url $url) {
        $endTime = Get-Date
        $startupTime = [math]::round(($endTime - $startTime).TotalMilliseconds, 2)

        $memoryMB = Get-ProcessMemory -ProcessName $ProcessMarker

        Log-Success "$Name запущен за $startupTime мс, память: $($memoryMB) МБ"

        return @{
            Process    = $process
            StartupTime = $startupTime
            MemoryMB   = $memoryMB
            Port       = $Port
            Name       = $Name
        }
    } else {
        Log-Error "$Name не запустился за отведённое время"
        return $null
    }
}

function Test-Endpoint {
    param(
        [string]$Name,
        [int]$Port
    )

    $url = "http://localhost:$Port$TestEndpoint"
    try {
        $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 5
        $body = $response.Content
        Log-Success "$Name ответ: $body"
        return $body
    } catch {
        Log-Error "$Name не ответил: $($_.Exception.Message)"
        return $null
    }
}

function Show-Results {
    param(
        $QuarkusData,
        $SpringData,
        $QuarkusResponse,
        $SpringResponse
    )

    Clear-Host
    Write-Host "==========================================" -ForegroundColor Magenta
    Write-Host "   СРАВНЕНИЕ ПРОИЗВОДИТЕЛЬНОСТИ" -ForegroundColor Magenta
    Write-Host "   Quarkus vs Spring Boot" -ForegroundColor Magenta
    Write-Host "==========================================" -ForegroundColor Magenta
    Write-Host ""

    if ($QuarkusData -and $SpringData) {
        Write-Host "ПАРАМЕТРЫ ЗАПУСКА:" -ForegroundColor Yellow
        Write-Host ""

        $quarkusMem = if ($QuarkusData.MemoryMB) { "$($QuarkusData.MemoryMB) МБ" } else { "N/A" }
        $springMem = if ($SpringData.MemoryMB) { "$($SpringData.MemoryMB) МБ" } else { "N/A" }

        Write-Host "  Quarkus:  Время: $($QuarkusData.StartupTime) мс | Память: $quarkusMem | Порт: $($QuarkusData.Port)" -ForegroundColor Green
        Write-Host "  Spring:   Время: $($SpringData.StartupTime) мс | Память: $springMem | Порт: $($SpringData.Port)" -ForegroundColor Green
        Write-Host ""

        # Сравнение
        if ($QuarkusData.StartupTime -lt $SpringData.StartupTime) {
            $diff = $SpringData.StartupTime - $QuarkusData.StartupTime
            Write-Host "Quarkus быстрее Spring на $diff мс" -ForegroundColor Green
        } else {
            $diff = $QuarkusData.StartupTime - $SpringData.StartupTime
            Write-Host "Spring быстрее Quarkus на $diff мс" -ForegroundColor Yellow
        }

        if ($QuarkusData.MemoryMB -and $SpringData.MemoryMB) {
            if ($QuarkusData.MemoryMB -lt $SpringData.MemoryMB) {
                $diffMem = [math]::round($SpringData.MemoryMB - $QuarkusData.MemoryMB, 2)
                Write-Host "Quarkus потребляет на $diffMem МБ меньше памяти" -ForegroundColor Green
            } else {
                $diffMem = [math]::round($QuarkusData.MemoryMB - $SpringData.MemoryMB, 2)
                Write-Host "Spring потребляет на $diffMem МБ меньше памяти" -ForegroundColor Yellow
            }
        }
        Write-Host ""
    }

    Write-Host "ОТВЕТЫ СЕРВЕРОВ:" -ForegroundColor Yellow
    Write-Host ""
    if ($QuarkusResponse) {
        Write-Host "  Quarkus: $QuarkusResponse" -ForegroundColor Green
    } else {
        Write-Host "  Quarkus: (нет ответа)" -ForegroundColor Red
    }
    if ($SpringResponse) {
        Write-Host "  Spring:  $SpringResponse" -ForegroundColor Green
    } else {
        Write-Host "  Spring:  (нет ответа)" -ForegroundColor Red
    }
    Write-Host ""

    Write-Host "==========================================" -ForegroundColor Magenta
    Write-Host "Приложения запущены. Для остановки нажмите Enter..." -ForegroundColor Cyan
}

function Stop-Applications {
    param($QuarkusProcess, $SpringProcess)

    Log-Start "Остановка приложений..."

    if ($QuarkusProcess -and -not $QuarkusProcess.HasExited) {
        $QuarkusProcess.Kill()
        Log-Success "Quarkus остановлен"
    }

    if ($SpringProcess -and -not $SpringProcess.HasExited) {
        $SpringProcess.Kill()
        Log-Success "Spring остановлен"
    }

    # Дополнительная очистка
    Get-Process -Name java -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowTitle -like "*quarkus*" -or $_.MainWindowTitle -like "*spring*"
    } | Stop-Process -Force -ErrorAction SilentlyContinue

    Log-Success "Все процессы завершены"
}

# --- Основной сценарий ---
function Main {
    $quarkusData = $null
    $springData = $null
    $quarkusResponse = $null
    $springResponse = $null

    try {
        # Создаём папку для логов
        $logDir = Join-Path $PSScriptRoot "logs"
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        $quarkusLog = Join-Path $logDir "quarkus.log"
        $springLog = Join-Path $logDir "spring.log"

        # 1. Запуск Quarkus
        $quarkusData = Start-And-Measure -Name "Quarkus" -Path $QuarkusPath -JarFile $QuarkusJar -Port $QuarkusPort -MaxMem $QuarkusMaxMem -ProcessMarker "quarkus" -LogFile $quarkusLog

        # 2. Запуск Spring Boot
        $springData = Start-And-Measure -Name "Spring Boot" -Path $SpringPath -JarFile $SpringJar -Port $SpringPort -MaxMem $SpringMaxMem -ProcessMarker "spring" -LogFile $springLog

        # 3. Выполнение запросов
        if ($quarkusData) {
            $quarkusResponse = Test-Endpoint -Name "Quarkus" -Port $QuarkusPort
        }
        if ($springData) {
            $springResponse = Test-Endpoint -Name "Spring Boot" -Port $SpringPort
        }

        # 4. Отображение результатов
        Show-Results -QuarkusData $quarkusData -SpringData $springData -QuarkusResponse $quarkusResponse -SpringResponse $springResponse

        # 5. Ожидание остановки
        Read-Host

        # 6. Завершение приложений
        Stop-Applications -QuarkusProcess $quarkusData.Process -SpringProcess $springData.Process

    } catch {
        Log-Error "Ошибка: $($_.Exception.Message)"
        # Аварийная очистка
        Stop-Applications -QuarkusProcess $quarkusData.Process -SpringProcess $springData.Process
    }
}

# --- Запуск ---
Main