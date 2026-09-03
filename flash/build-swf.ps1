# Build Interface/CalendarUI.swf.
#
# There is no Flash IDE involved. The menu is a copy of the game's own
# messagebox.swf with its MessageBox class replaced by ours, using JPEXS
# FFDec's CLI. Starting from a vanilla menu is what gives us the real border
# art, the game's fonts, the focusable buttons and gamepad input for free.
#
# FFDec labels AS1/2 replacement EXPERIMENTAL. It works, but the script
# verifies the result decompiles back with our code intact rather than
# trusting the exit code -- a silently mangled SWF would otherwise only show
# up as a menu that does nothing in game.

param(
    [switch]$Deploy
)

# Continue, not Stop.
#
# FFDec writes ordinary progress and warnings to stderr, and PowerShell
# surfaces native-command stderr as a NativeCommandError -- under 'Stop' that
# aborts a build that is actually succeeding. It first bit when the class grew
# past FFDec's SI16 header threshold and it emitted a purely informational
# "This should not have any negative impact" warning.
#
# Real failures are still caught: every step checks $LASTEXITCODE, and the
# verification pass at the end re-reads the built SWF.
$ErrorActionPreference = 'Continue'

$here   = $PSScriptRoot
$ffdec  = 'e:\Skyrim Modlists\Tools\Flash Decompiler\ffdec-cli.exe'
$base   = Join-Path $here 'base-messagebox.swf'
$source = Join-Path $here 'src\CalendarMenu.as'
$out    = Join-Path $here 'CalendarUI.swf'

if (-not (Test-Path $ffdec))  { throw "FFDec not found at $ffdec" }
if (-not (Test-Path $base))   { throw "Base SWF not found at $base" }
if (-not (Test-Path $source)) { throw "Source not found at $source" }

# The class is replaced in place, so start from a clean copy of the base each
# time -- otherwise edits would stack on top of the previous build.
$work = Join-Path $here 'build.swf'
Copy-Item $base $work -Force

Write-Host 'Compiling CalendarMenu.as...' -ForegroundColor Cyan
& $ffdec -replace $work $out '\__Packages\MessageBox' $source
if ($LASTEXITCODE -ne 0) { throw 'FFDec replace failed.' }

# --- import ButtonArt ---------------------------------------------------
#
# The prompt bar draws its key icons from "ButtonArt", a sprite living in
# SkyUI's interface/skyui/buttonart.swf, indexed by DX scan code. It is pulled
# in with an ImportAssets2 tag -- exactly how Character Menu SE's
# charactersheet.swf gets it.
#
# FFDec's -replace only swaps a class body, so the tag is added at the XML
# level: swf2xml, splice, xml2swf. The splice is done in Python because the
# url attribute needs a DOUBLED backslash ("skyui\buttonart.swf"): that is
# FFDec's own escaping on export, and writing a single one makes its XML
# reader fold "" into a 0x08 backspace, silently corrupting the path.
#
# Character id 200 is free -- messagebox.swf only uses 1..28.
Write-Host 'Importing ButtonArt from SkyUI...' -ForegroundColor Cyan

$xml    = Join-Path $here 'build.xml'
$xmlOut = Join-Path $here 'build.import.xml'

& $ffdec -swf2xml $out $xml
if ($LASTEXITCODE -ne 0) { throw 'FFDec swf2xml failed.' }

python (Join-Path $here 'import-buttonart.py') $xml $xmlOut
if ($LASTEXITCODE -ne 0) { throw 'ButtonArt XML injection failed.' }

& $ffdec -xml2swf $xmlOut $out
if ($LASTEXITCODE -ne 0) { throw 'FFDec xml2swf failed.' }

Remove-Item $xml, $xmlOut -Force -ErrorAction SilentlyContinue

# Confirm the path survived the round trip. A corrupted url fails silently at
# runtime -- the import just resolves to nothing and every icon is blank.
$imported = & $ffdec -dumpSWF $out 2>$null | Select-String 'ImportAssets2 \(chid: 200'
if (-not $imported) { throw 'Verify failed: the ButtonArt import tag is not in the built SWF.' }
if ($imported -notmatch '73 6b 79 75 69 5c') {
    throw ("Verify failed: the ButtonArt url is corrupted -- expected the bytes for " +
           "'skyuiuttonart.swf' with a single 0x5c separator. Check the backslash " +
           "escaping in import-buttonart.py.")
}
Write-Host '  ButtonArt imported (character 200)' -ForegroundColor Green

# --- verify ------------------------------------------------------------
# Decompile the result and check our code is really in there.
Write-Host 'Verifying...' -ForegroundColor Cyan
$verify = Join-Path $env:TEMP 'calendarui-verify'
if (Test-Path $verify) { Remove-Item $verify -Recurse -Force }
& $ffdec -export script $verify $out | Out-Null

$decompiled = Join-Path $verify 'scripts\__Packages\MessageBox.as'
if (-not (Test-Path $decompiled)) { throw 'Verify failed: no class in the output SWF.' }

$text = Get-Content $decompiled -Raw

# The class MUST be declared `class MessageBox`. The base movie's last init
# action is `Object.registerClass("MessageBox", MessageBox)`, which binds the
# symbol the stage places as `MessageMenu` to whatever `_global.MessageBox`
# holds. The class statement inside __Packages/MessageBox is what decides
# which global gets defined -- so declaring `class CalendarMenu` defines
# `_global.CalendarMenu`, leaves `_global.MessageBox` undefined, and
# registerClass silently binds nothing.
#
# The sprite then instantiates as a plain MovieClip: no constructor, no
# addCallBack, and the menu renders the authored "<message text>" placeholder
# forever while the plugin's FxDelegate::Invoke has no receiver. It fails
# silently and looks like a data problem, so it is checked here.
if ($text -notmatch 'class\s+MessageBox\s+extends') {
    throw ("Verify failed: the class must be declared 'class MessageBox extends MovieClip'. " +
           "Object.registerClass binds the symbol 'MessageBox', so any other class name " +
           "leaves _global.MessageBox undefined and the menu never initialises.")
}

# Every htmlText write must carry the vanilla font tag.
#
# messagebox.swf names its font inline in the HTML as
# face="$EverywhereMediumFont" (imported from gfxfontlib.swf) rather than via
# a TextFormat, and setNewTextFormat() does not carry that binding to fields
# made with createTextField(). A write without it renders every glyph as an
# empty black box -- visible only in game, so it is checked here.
# Every htmlText write must carry the vanilla font tag.
#
# The font is named inline in the HTML as face="$EverywhereMediumFont"; a
# field made with createTextField() has no other binding, so a write without
# it renders every glyph as an empty black box -- visible only in game.
#
# A write may assign a local that was itself built from Markup(), so when the
# right-hand side is a bare variable the check looks at that variable's
# assignments WITHIN THE SAME FUNCTION. Locals like _loc7_ are reused across
# the class, so a class-wide search gives false positives.
$funcs = [regex]::Matches($text, '(?ms)^   function\s+\w+\s*\([^)]*\)\s*
?
   \{(.*?)^   \}')
foreach ($f in $funcs) {
    $bodyText = $f.Groups[1].Value
    foreach ($w in [regex]::Matches($bodyText, '\.htmlText\s*=\s*([^;]+);')) {
        $rhs = $w.Groups[1].Value.Trim()
        if ($rhs -match '^""$' -or $rhs -match 'Markup(2|Block)?\(') { continue }

        if ($rhs -match '^(_loc\d+_|[A-Za-z_]\w*)$') {
            $var = $Matches[1]
            $asgn = [regex]::Matches($bodyText,
                        '(?:var\s+)?' + [regex]::Escape($var) + '\s*(?:\+=|=)\s*([^;]+);')
            $ok = $asgn.Count -gt 0
            foreach ($a in $asgn) {
                if ($a.Groups[1].Value -notmatch 'Markup\(') { $ok = $false }
            }
            if ($ok) { continue }
        }

        throw ("Verify failed: an htmlText write does not go through Markup(): $rhs`n" +
               "  Runtime text fields have no usable font unless the markup carries " +
               "<font face='`$EverywhereMediumFont'>, and render as black boxes without it.")
    }
}

$expected = @('setCalendarData', 'BuildGrid', 'MoveSelection', 'ScanTable', 'CELL_W',
              'EverywhereMediumFont')
$missing = $expected | Where-Object { $text -notmatch [regex]::Escape($_) }
if ($missing) { throw "Verify failed: missing from the built SWF: $($missing -join ', ')" }

# Guard against referencing stage instances the base SWF does not define.
#
# messagebox.swf names only Background_mc, Divider, MessageText (plus the
# button internals). Referencing anything else as a stage field silently
# assigns to undefined -- which is what left the vanilla "<message text>"
# placeholder on screen while the class itself was bound and running.
$stage = @('Background_mc', 'Divider', 'MessageText')
$referenced = [regex]::Matches($text, 'this\.([A-Z][A-Za-z_]+)\.') |
              ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
# Anything the class assigns to itself is created at runtime and therefore
# fine: `this.X = ...` covers createTextField results, attachMovie'd buttons
# (the nav row) and createEmptyMovieClip containers alike. Deriving this
# rather than listing names by hand means adding a widget does not need the
# guard updated -- and, more to the point, does not train us to ignore a
# warning that is sometimes real.
# Includes properties assigned onto OTHER clips (`clip.Owner = this`), since
# inside an attached closure `this` is that clip, not the menu -- the popup's
# and prompts' Owner/Handler are set that way and are not stage references.
$created = [regex]::Matches($text, '(?:this|_loc\d+_)\.([A-Z][A-Za-z_]+)\s*=') |
           ForEach-Object { $_.Groups[1].Value }
$known = $stage + $created
$unknown = $referenced | Where-Object { $known -notcontains $_ }
if ($unknown) {
    Write-Warning "References not on the stage and not created at runtime: $($unknown -join ', ')"
    Write-Warning "  (these assign to undefined at runtime and fail silently)"
}

Write-Host "  all $($expected.Count) markers present" -ForegroundColor Green
Remove-Item $work -Force

$size = (Get-Item $out).Length
Write-Host "Built $out ($('{0:N0}' -f $size) bytes)" -ForegroundColor Green

if ($Deploy) {
    $dist = Join-Path $here '..\dist\CalendarUI\Interface'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Copy-Item $out (Join-Path $dist 'CalendarUI.swf') -Force
    Write-Host "Deployed to dist/CalendarUI/Interface/" -ForegroundColor Green

    # Also deploy into the MO2 mods folder, the way build.ps1 does for the
    # DLL. Without this the game keeps loading whatever .swf was there last,
    # which is indistinguishable in game from the new one not working -- an
    # entire test cycle was spent on a stale movie once already.
    $mods = if ($env:SKYRIM_MODS_FOLDER) { $env:SKYRIM_MODS_FOLDER }
            else { 'e:\Skyrim Modlists\Winds of the North\mods' }

    # The mod's folder name is NOT always "CalendarUI". Winds of the North
    # installs it as "[NoDelete] CalendarUI" -- the Wabbajack prefix marking a
    # folder the modlist installer must not remove. Deploying to a guessed
    # "CalendarUI" there would silently CREATE a second, empty-but-for-the-swf
    # mod that MO2 has never heard of: the build reports success, the game
    # keeps loading the old movie from the real folder, and nothing looks
    # wrong. So the existing folder is found rather than assumed, and a miss
    # is a warning instead of a new directory.
    $modDir = $null
    foreach ($name in @($env:CALENDARUI_MOD_FOLDER, 'CalendarUI', '[NoDelete] CalendarUI')) {
        if (-not $name) { continue }
        $candidate = Join-Path $mods $name
        if (Test-Path -LiteralPath $candidate) { $modDir = $candidate; break }
    }

    if ($modDir) {
        $target = Join-Path $modDir 'Interface'
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Copy-Item $out (Join-Path $target 'CalendarUI.swf') -Force
        Write-Host "Deployed to $target" -ForegroundColor Green
    } else {
        Write-Warning "No CalendarUI mod folder found under $mods -- the .swf was NOT deployed to the game."
        Write-Warning "  Set CALENDARUI_MOD_FOLDER to the mod's folder name if it differs."
    }
}
