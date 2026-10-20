# Makes a reference speech WAV (48 kHz, 16-bit, mono) with Windows SAPI text-to-speech, for
# app/integration_test/audio_quality_test.dart. Nothing is downloaded and no licence applies.
# Several sentences, pauses between them, and words that end in soft consonants.
#   powershell -File tools\make-speech-ref.ps1 -Out ref.wav [-Voice "Microsoft Zira Desktop"] [-Rate 0]
param(
  [Parameter(Mandatory = $true)][string]$Out,
  [string]$Voice = "",
  [int]$Rate = 0
)
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
if ($Voice -ne "") { $s.SelectVoice($Voice) }
$s.Rate = $Rate
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(48000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$s.SetOutputToWaveFile($Out, $fmt)
$pb = New-Object System.Speech.Synthesis.PromptBuilder
$sentences = @(
  "He took a deep breath and lifted the sheath.",
  "The fifth path leads beneath the bridge.",
  "She reads the lists of gifts and facts aloud.",
  "Every month the moths ate half of the cloth.",
  "Please tell me what you think of this."
)
$pb.AppendBreak([TimeSpan]::FromMilliseconds(600))
foreach ($t in $sentences) {
  $pb.AppendText($t)
  $pb.AppendBreak([TimeSpan]::FromMilliseconds(900))
}
$s.Speak($pb)
$s.Dispose()
Write-Output "wrote $Out"
