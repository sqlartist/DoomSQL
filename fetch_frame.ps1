<#
    fetch_frame.ps1 -- pull one frame and write it to disk. No window, no
    timer, no PictureBox. If the file this produces opens and shows the level,
    the database and the BMP are correct and the problem is purely display.

        .\fetch_frame.ps1 -Server . -Database doom
#>
param(
    [string]$Server   = ".",
    [string]$Database = "doom",
    [int]$Tics        = 0,
    [string]$Out      = "frame0.bmp",
    [switch]$UseSqlAuth, [string]$User, [string]$Password
)

$ErrorActionPreference = "Stop"

$cs = if ($UseSqlAuth) {
    "Server=$Server;Database=$Database;User Id=$User;Password=$Password;TrustServerCertificate=true"
} else {
    "Server=$Server;Database=$Database;Integrated Security=true;TrustServerCertificate=true"
}

$connType = $null
foreach ($t in @('Microsoft.Data.SqlClient.SqlConnection',
                 'System.Data.SqlClient.SqlConnection')) {
    if ($t -as [type]) { $connType = $t -as [type]; break }
}
if ($null -eq $connType) {
    Write-Host "No SqlClient provider available in this PowerShell host." -ForegroundColor Red
    Write-Host "Try Windows PowerShell 5.1, or: Install-Module SqlServer -Scope CurrentUser" -ForegroundColor Yellow
    return
}
Write-Host "provider      : $($connType.FullName)"
$conn = $connType::new($cs)
$conn.Open()
Write-Host "connected to $Server/$Database"

$cmd = $conn.CreateCommand()
$cmd.CommandType = [System.Data.CommandType]::StoredProcedure
$cmd.CommandText = "dbo.p_frame"
$cmd.CommandTimeout = 120
[void]$cmd.Parameters.AddWithValue("@tics", $Tics)

# Called directly rather than via a function on purpose: PowerShell enumerates
# a collection returned from a function, turning byte[] into Object[].
$result = $cmd.ExecuteScalar()

Write-Host "returned type : $(if ($null -eq $result) { '<null>' } else { $result.GetType().FullName })"
if ($result -is [System.Array] -and $result -isnot [byte[]]) {
    Write-Host "got $($result.GetType().FullName) -- coercing to byte[]" -ForegroundColor Yellow
    $result = [byte[]]@($result)
}
if ($result -isnot [byte[]]) {
    Write-Host "NOT a byte array -- p_frame did not return the BMP as the first column of the first row." -ForegroundColor Red
    $conn.Close(); return
}

$bytes = [byte[]]$result
Write-Host "bytes         : $($bytes.Length) (expected 192054)"
Write-Host "magic         : $([char]$bytes[0])$([char]$bytes[1])"

$nonZero = 0
for ($i = 54; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -ne 0) { $nonZero++ } }
Write-Host "non-zero pixel bytes: $nonZero of $($bytes.Length - 54)"

$path = Join-Path (Get-Location) $Out
[System.IO.File]::WriteAllBytes($path, $bytes)
Write-Host "wrote $path" -ForegroundColor Green

# and prove GDI+ (what the window uses) can decode it, which PIL-style
# decoders being happy does not guarantee
Add-Type -AssemblyName System.Drawing
try {
    $ms  = New-Object System.IO.MemoryStream (,$bytes)
    $img = [System.Drawing.Image]::FromStream($ms)
    Write-Host "GDI+ decoded  : $($img.Width)x$($img.Height) $($img.PixelFormat)" -ForegroundColor Green

    # sample a few pixels so 'decoded but black' is distinguishable
    $bmp = New-Object System.Drawing.Bitmap $img
    $samples = @()
    foreach ($p in @(@(160,100), @(80,150), @(240,60), @(160,20))) {
        $c = $bmp.GetPixel($p[0], $p[1])
        $samples += "($($p[0]),$($p[1]))=$($c.R),$($c.G),$($c.B)"
    }
    Write-Host "sampled pixels: $($samples -join '  ')"
    $bmp.Dispose(); $img.Dispose(); $ms.Dispose()
}
catch {
    Write-Host "GDI+ FAILED to decode: $($_.Exception.Message)" -ForegroundColor Red
}

$conn.Close()
