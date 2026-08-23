# The movie

`CalendarUI.swf` is built by replacing the `MessageBox` class inside a copy of
the game's own `messagebox.swf`, using JPEXS FFDec's CLI. Starting from a vanilla
menu is the point: the panel art, the fonts, the button prompts and the input
handling all come along unmodified.

## Before building

Two things are not in this repository.

**`base-messagebox.swf`** is a game asset. Extract `interface/messagebox.swf`
from `Skyrim - Interface.bsa` with BSA Browser or a similar tool, and put it here
renamed:

    flash/base-messagebox.swf

**FFDec** is needed on PATH, or at the path the script expects. Get it from
https://github.com/jindrapetrik/jpexs-decompiler

The prompt bar also imports `ButtonArt` from SkyUI's `buttonart.swf` at runtime,
so SkyUI must be installed to see the key icons. It is imported by reference; no
SkyUI asset is copied into this repository or into the built movie.

## Building

```powershell
.\build-swf.ps1 -Deploy
```

`-Deploy` copies the result into `dist/CalendarUI/Interface/`. Without it the
build stops at `flash/CalendarUI.swf`.

FFDec marks ActionScript 1/2 replacement as experimental, so the script does not
trust its exit code. It decompiles the result back and fails the build unless the
class really is in there, the font tags are present on every text write, and the
ButtonArt import survived.

## Editing

`src/CalendarMenu.as` is the whole menu.

The class must stay named `MessageBox`. The base movie ends with
`Object.registerClass("MessageBox", MessageBox)`, which binds the stage symbol to
whatever `_global.MessageBox` holds. Renaming the class leaves that global
undefined, so the sprite falls back to a plain MovieClip, the constructor never
runs, and the movie sits there showing the placeholder text with no error.
