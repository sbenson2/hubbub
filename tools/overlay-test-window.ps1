# Shows a plain test window for checking the game overlay's detection by hand.
#   borderless: no frame, covering the whole primary screen including the taskbar, like a
#               borderless-fullscreen game (the fullscreen rule says "game").
#   windowed:   an ordinary sizable 1280x720 window (not a game).
# Esc closes it, and so does a timer after -Seconds.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\overlay-test-window.ps1 -Mode borderless
param(
  [ValidateSet('borderless', 'windowed')][string]$Mode = 'borderless',
  [ValidateRange(1, 86400)][int]$Seconds = 120
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Hubbub overlay test window ($Mode)"
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#2B3A55')
$form.KeyPreview = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = 'Hubbub overlay test window (Esc closes)'
$label.ForeColor = [System.Drawing.Color]::White
$label.Font = New-Object System.Drawing.Font('Segoe UI', 20)
$label.Dock = [System.Windows.Forms.DockStyle]::Fill
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($label)

if ($Mode -eq 'borderless') {
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
} else {
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.Size = New-Object System.Drawing.Size(1280, 720)
}

$form.Add_KeyDown({
  if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $Seconds * 1000
$timer.Add_Tick({
  $timer.Stop()
  $form.Close()
})
$timer.Start()

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
