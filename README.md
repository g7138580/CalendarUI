# CalendarUI

A Tamriel calendar for Skyrim Special Edition, built as a real Scaleform menu.

Page through the year, see holidays and festivals marked on the grid, and click
any day for the details. Because it is a real menu rather than an overlay, a UI
replacer such as SkyUI or NORDIC UI restyles it for free.

Opens with **L**, or from the Tween Menu wheel.

## Features

- Month and day names are read from the game, so the calendar is already
  translated in a localized copy of Skyrim and follows any mod that renames
  the months.
- Holidays are plain JSON. A mod adds its own by shipping a file; nobody has to
  edit or overwrite anyone else's.
- Translatable through Skyrim's own `Interface/Translations` format.
- Seasons, the hotkey, the nav keys and the log level are set in an INI.

## Building

Needs Visual Studio with the C++ toolchain, CMake, and vcpkg.

```powershell
$env:VCPKG_ROOT = "C:\vcpkg"
$env:SKYRIM_MODS_FOLDER = "<your MO2 mods folder>"
.\build.ps1
```

That builds `CalendarUI.dll` and copies it, the INI, the event data and the
translations into `<mods>/CalendarUI`.

### The movie

The `.swf` is built separately, because it needs
[JPEXS FFDec](https://github.com/jindrapetrik/jpexs-decompiler) rather than the
C++ toolchain:

```powershell
cd flash
.\build-swf.ps1 -Deploy
```

Skyrim runs SWF 10 / ActionScript 2, and the tools that targeted it are gone.
Rather than needing Flash CS6, the menu is built by replacing one class inside a
copy of the game's own `messagebox.swf`, so the panel art, fonts and input
handling all come along unmodified.

`flash/base-messagebox.swf` is not in this repository: it is a game asset. Copy
`interface/messagebox.swf` out of `Skyrim - Interface.bsa` and rename it.

## Layout

| Path | What |
| --- | --- |
| `include/`, `src/` | the SKSE plugin |
| `flash/src/CalendarMenu.as` | the menu itself, in ActionScript 2 |
| `flash/build-swf.ps1` | builds the movie with FFDec |
| `dist/CalendarUI/` | INI, event data and translations, copied on build |
| `dist/optional/` | the optional province holidays add-on |

## Adding holidays

Drop a JSON file in `SKSE/Plugins/CalendarUI/Events/`. Every file in that folder
is loaded and merged.

```json
{
  "events": [
    {
      "id": "mymod.founding_day",
      "name": "Founding Day",
      "month": "Sun's Height",
      "day": 12,
      "kind": "festival",
      "description": "The city marks the year it was raised."
    }
  ]
}
```

Add a `"year"` to pin an event to a single year instead of recurring. Full
reference, including how to override or remove someone else's holiday, is in
`dist/CalendarUI/SKSE/Plugins/CalendarUI/Events/00_README.txt`.

## Translating

Copy `dist/CalendarUI/Interface/Translations/CalendarUI_ENGLISH.txt`, rename it
for your language, and translate the text after each tab. Save as UTF-16 LE.

Month and day names are not in that file on purpose; they come from the game and
are already translated. See the `00_README.txt` beside it.

## Licence

GPL-3.0. See [LICENSE](LICENSE).
