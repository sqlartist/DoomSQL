<#
    doom_client.ps1 -- keyboard and monitor for Doom running in SQL Server.

    The database does everything: simulation, collision, rasterising, palette
    lookup, BMP assembly. This is a window that shows bytes and reports which
    keys are held. That division is the whole point -- by the standards of the
    "Doom on anything" sport, the display and input device being external is
    fair; the computation is what has to happen on the target.

    Usage:
        .\doom_client.ps1 -Server . -Database doom
        .\doom_client.ps1 -Server "localhost\SQLEXPRESS" -Tics 12 -Scale 3

    Keys: W/S forward and back, A/D turn, Q/E strafe, Shift run,
          SPACE open doors, CTRL fire, 1-4 select weapon,
          R respawn at the player start, Esc quit.
#>

param(
    [string]$Server   = ".",
    [string]$Database = "doom",
    [int]$Tics        = 6,     # 35Hz tics simulated per displayed frame
    [int]$Scale       = 3,     # integer upscale of the 320x200 frame
    [switch]$DumpFirstFrame,
    [switch]$UseSqlAuth,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --------------------------------------------------------------- connection
$cs = if ($UseSqlAuth) {
    "Server=$Server;Database=$Database;User Id=$User;Password=$Password;" +
    "TrustServerCertificate=true"
} else {
    "Server=$Server;Database=$Database;Integrated Security=true;" +
    "TrustServerCertificate=true"
}

# PowerShell 7 runs on .NET Core, where System.Data.SqlClient may be absent.
# Use whichever provider this host actually has.
$connType = $null
foreach ($t in @('Microsoft.Data.SqlClient.SqlConnection',
                 'System.Data.SqlClient.SqlConnection')) {
    if ($t -as [type]) { $connType = $t -as [type]; break }
}
if ($null -eq $connType) {
    Write-Host "No SqlClient provider found. On PowerShell 7 run:" -ForegroundColor Red
    Write-Host "  Install-Module SqlServer -Scope CurrentUser" -ForegroundColor Yellow
    Write-Host "or use Windows PowerShell 5.1 instead." -ForegroundColor Yellow
    return
}
Write-Host "provider: $($connType.FullName)"

$conn = $connType::new($cs)
try { $conn.Open() }
catch { Write-Host "Could not connect: $($_.Exception.Message)" -ForegroundColor Red; return }
Write-Host "connected to $Server/$Database"

function Invoke-Proc($name, [hashtable]$params, [switch]$Scalar) {
    $cmd = $conn.CreateCommand()
    $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
    $cmd.CommandText = $name
    $cmd.CommandTimeout = 120
    if ($params) {
        foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $params[$k]) }
    }
    try {
        if ($Scalar) {
            # The unary comma is load-bearing. PowerShell ENUMERATES a
            # collection returned from a function, so "return $bytes" emits
            # 192,054 separate bytes that the caller recollects as
            # System.Object[] -- and every "-is [byte[]]" test then fails.
            # ",$x" wraps it so exactly one object comes back out.
            return ,$cmd.ExecuteScalar()
        }
        [void]$cmd.ExecuteNonQuery()
        return $null
    }
    finally { $cmd.Dispose() }
}

Invoke-Proc "dbo.setup_game" $null | Out-Null
Invoke-Proc "dbo.build_collision" $null | Out-Null
Write-Host "game reset"

# ---- frame 0, synchronously, with the window not yet in the way ------------
function Get-Frame([int]$tics, [int]$use = 0, [int]$fire = 0, [int]$weapon = 0) {
    $raw = Invoke-Proc "dbo.p_frame" `
             @{ tics = $tics; use = $use; fire = $fire; weapon = $weapon } -Scalar
    if ($null -eq $raw -or $raw -is [System.DBNull]) {
        throw "p_frame returned NULL. Check that dbo.frame_bmp exists (doom_present.sql)."
    }
    # An Object[] here means something enumerated the array on the way back;
    # coerce rather than fail, but anything else is a genuine problem.
    if ($raw -is [byte[]]) {
        $bytes = $raw
    } elseif ($raw -is [System.Array]) {
        $bytes = [byte[]]@($raw)
    } else {
        throw ("p_frame returned $($raw.GetType().FullName), not a byte array. " +
               "Its first result set must be the BMP.")
    }
    $ms = New-Object System.IO.MemoryStream (,$bytes)
    try {
        $tmp = [System.Drawing.Image]::FromStream($ms)
        $bmp = New-Object System.Drawing.Bitmap $tmp
        $tmp.Dispose()
    } finally { $ms.Dispose() }
    return @{ bytes = $bytes; bitmap = $bmp }
}

Write-Host "fetching frame 0 (the first call also compiles render_frame, ~1s extra)..."
$sw0 = [System.Diagnostics.Stopwatch]::StartNew()
try   { $first = Get-Frame 0 }
catch {
    Write-Host "FAILED on the first frame: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Run .\fetch_frame.ps1 for a more detailed breakdown." -ForegroundColor Yellow
    $conn.Close(); return
}
$sw0.Stop()

$nz = 0
for ($i = 54; $i -lt $first.bytes.Length; $i += 97) { if ($first.bytes[$i] -ne 0) { $nz++ } }
Write-Host ("frame 0 ok: {0} bytes, {1}x{2}, {3:N0} ms, {4} of {5} sampled bytes non-zero" -f
    $first.bytes.Length, $first.bitmap.Width, $first.bitmap.Height,
    $sw0.Elapsed.TotalMilliseconds, $nz, [int](($first.bytes.Length - 54) / 97))
if ($nz -eq 0) {
    Write-Host ("every sampled byte is zero -- the image really is black. " +
                "Run doom_display_check.sql.") -ForegroundColor Yellow
}
if ($DumpFirstFrame) {
    $p = Join-Path (Get-Location) 'frame0.bmp'
    [System.IO.File]::WriteAllBytes($p, $first.bytes)
    Write-Host "wrote $p" -ForegroundColor Green
}

# ---------------------------------------------------------------- the window
$form              = New-Object System.Windows.Forms.Form
$form.Text         = "DOOM (SQL Server $Server/$Database)"
$form.ClientSize   = New-Object System.Drawing.Size(
                        (320 * $Scale), ([int](200 * $Scale * 1.2)))
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox  = $false
$form.BackColor    = [System.Drawing.Color]::Black
$form.KeyPreview   = $true

# The frame is drawn in a Paint handler rather than assigned to a PictureBox.
# 320x200 is not square-pixel, so it is stretched to a 1.2 aspect on the way
# out -- the same correction the original hardware applied.
$script:frame = $first.bitmap

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock      = 'Fill'
$panel.BackColor = [System.Drawing.Color]::Black
# double-buffer via reflection: the property is protected on Control
$panel.GetType().GetProperty('DoubleBuffered',
    [Reflection.BindingFlags]'Instance,NonPublic').SetValue($panel, $true, $null)

$panel.Add_Paint({
    param($sender, $e)
    if ($null -ne $script:frame) {
        $e.Graphics.InterpolationMode = 'NearestNeighbor'
        $e.Graphics.PixelOffsetMode   = 'Half'
        $e.Graphics.DrawImage($script:frame,
            (New-Object System.Drawing.Rectangle 0, 0,
                $sender.ClientSize.Width, $sender.ClientSize.Height))
    } else {
        $e.Graphics.DrawString('waiting for first frame...',
            $sender.Font, [System.Drawing.Brushes]::Gray, 8, 8)
    }
})

$status            = New-Object System.Windows.Forms.Label
$status.Dock       = 'Bottom'
$status.Height     = 18
$status.ForeColor  = [System.Drawing.Color]::Gray
$status.BackColor  = [System.Drawing.Color]::Black

# Docked controls claim space in reverse z-order, so the Fill control is added
# LAST -- added first it takes the whole client area and the label overlaps it.
$form.Controls.Add($status)
$form.Controls.Add($panel)

# ------------------------------------------------------------------ input
$keys = @{ forward=0; back=0; turnleft=0; turnright=0
           strafeleft=0; straferight=0; run=0 }

# Movement keys are level-triggered (held down = keep moving); use is
# edge-triggered (one door per press, however long the key is held).
$script:useEdge = $false
$script:fireEdge = $false
$script:weaponPick = 0

function Set-Key($code, $v) {
    switch ($code) {
        'W'       { $script:keys.forward     = $v }
        'Up'      { $script:keys.forward     = $v }
        'S'       { $script:keys.back        = $v }
        'Down'    { $script:keys.back        = $v }
        'A'       { $script:keys.turnleft    = $v }
        'Left'    { $script:keys.turnleft    = $v }
        'D'       { $script:keys.turnright   = $v }
        'Right'   { $script:keys.turnright   = $v }
        'Q'       { $script:keys.strafeleft  = $v }
        'E'       { $script:keys.straferight = $v }
        'ShiftKey'{ $script:keys.run         = $v }
    }
}

$form.Add_KeyDown({
    if ($_.KeyCode -eq 'Escape') { $form.Close(); return }
    if ($_.KeyCode -eq 'R') {
        Invoke-Proc "dbo.setup_game" $null | Out-Null
        Invoke-Proc "dbo.build_collision" $null | Out-Null
        Invoke-Proc "dbo.setup_player" $null | Out-Null
        return
    }
    if ($_.KeyCode -eq 'Space') { $script:useEdge = $true; return }
    if ($_.KeyCode -eq 'ControlKey') { $script:fireEdge = $true; return }
    if ($_.KeyCode -match '^D([1-4])$') {
        $script:weaponPick = [int]$Matches[1]; return      # number keys 1-4
    }
    Set-Key $_.KeyCode.ToString() 1
})
$form.Add_KeyUp({ Set-Key $_.KeyCode.ToString() 0 })

# ------------------------------------------------------------------- loop
$busy = $false
$sw   = [System.Diagnostics.Stopwatch]::new()
$frames = 0; $totalMs = 0.0

$timer          = New-Object System.Windows.Forms.Timer
$timer.Interval = 30
$timer.Add_Tick({
    # a frame can take longer than the timer interval; don't queue up behind it
    if ($script:busy) { return }
    $script:busy = $true
    try {
        $sw.Restart()
        Invoke-Proc "dbo.p_input_set" $script:keys | Out-Null
        # Read the edges first, THEN clear them: clearing before reading
        # means the key press never leaves this function.
        $useNow  = if ($script:useEdge)  { 1 } else { 0 }
        $fireNow = if ($script:fireEdge) { 1 } else { 0 }
        $wpnNow  = $script:weaponPick

        $script:useEdge    = $false      # one door per press
        $script:fireEdge   = $false      # one shot per press
        $script:weaponPick = 0

        $f = Get-Frame $Tics $useNow $fireNow $wpnNow
        $bytes = $f.bytes

        $old = $script:frame
        $script:frame = $f.bitmap
        if ($old) { $old.Dispose() }
        $panel.Invalidate()
        $sw.Stop()
        $script:frames++
        $script:totalMs += $sw.Elapsed.TotalMilliseconds
        $status.Text = ("frame {0}  {1:N0} ms  avg {2:N0} ms  {3:N1} fps  {4} bytes  ({5} tics/frame)" -f
            $script:frames, $sw.Elapsed.TotalMilliseconds,
            ($script:totalMs / $script:frames),
            (1000.0 / [Math]::Max(1, $script:totalMs / $script:frames)),
            $(if ($bytes) { $bytes.Length } else { 0 }), $Tics)
    }
    catch {
        $timer.Stop()
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message, "SQL error") | Out-Null
        $form.Close()
    }
    finally { $script:busy = $false }
})

$form.Add_Shown({ $timer.Start() })
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose()
    if ($conn.State -eq 'Open') { $conn.Close() }
    $conn.Dispose()
    if ($script:frame) { $script:frame.Dispose() }
    if ($script:frames) {
        Write-Host ("{0} frames, average {1:N0} ms ({2:N1} fps)" -f
            $script:frames, ($script:totalMs / $script:frames),
            (1000.0 / ($script:totalMs / $script:frames)))
    }
})

[void]$form.ShowDialog()
