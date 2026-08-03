param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

$ErrorActionPreference = "Stop"
$mutex = [System.Threading.Mutex]::new($false, "Local\R15PoseTunerExportHelperV1")
$hasMutex = $false

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { exit 0 }

    $resolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    $exportRoot = [System.IO.Path]::GetFullPath((Join-Path $resolvedProjectRoot "pose-exports"))
    [System.IO.Directory]::CreateDirectory($exportRoot) | Out-Null
    $exportPrefix = $exportRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $seenTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    while ($true) {
        $settingsFiles = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA "Roblox") -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "InstalledPlugins\0\settings.json" } |
            Where-Object { Test-Path -LiteralPath $_ }

        foreach ($settingsFile in $settingsFiles) {
            try {
                $settings = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $request = $settings.R15PoseTunerExportRequestV1
                if ($null -eq $request -or [string]::IsNullOrWhiteSpace([string]$request.Token)) { continue }

                $token = [string]$request.Token
                if (-not $seenTokens.Add($token)) { continue }
                $extension = ([string]$request.Extension).ToLowerInvariant()
                if ($extension -notin @("txt", "luau")) { continue }

                $content = [string]$request.Content
                if ([System.Text.Encoding]::UTF8.GetByteCount($content) -gt 7500000) { continue }

                $requestedName = [System.IO.Path]::GetFileName([string]$request.FileName)
                $baseName = [System.IO.Path]::GetFileNameWithoutExtension($requestedName)
                $baseName = [regex]::Replace($baseName, '[\x00-\x1f<>:"/\\|?*]', '_').Trim().TrimEnd('.')
                if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = "Untitled Animation" }
                if ($baseName.Length -gt 96) { $baseName = $baseName.Substring(0, 96) }

                $destination = [System.IO.Path]::GetFullPath((Join-Path $exportRoot ($baseName + "." + $extension)))
                if (-not $destination.StartsWith($exportPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $suffix = 2
                while ([System.IO.File]::Exists($destination)) {
                    $destination = [System.IO.Path]::GetFullPath((Join-Path $exportRoot ($baseName + " (" + $suffix + ")." + $extension)))
                    if (-not $destination.StartsWith($exportPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { break }
                    $suffix += 1
                }
                [System.IO.File]::WriteAllText($destination, $content, $utf8NoBom)
            } catch {
                # Studio may be replacing settings.json while it is read. Retry on
                # the next polling pass without touching or locking Studio's file.
            }
        }

        Start-Sleep -Milliseconds 400
    }
} finally {
    if ($hasMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
