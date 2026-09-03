# CalendarUI

A Tamriel calendar as a real Skyrim menu, opened with **L** or from the tween
wheel (Tween Menu Overhaul or Extended Tween Menu, both supported out of the
box). It shows the month as a grid of day squares, marks holidays and
moon phases, and opens a panel with a day's events -- where the player can also
write notes of their own.

The movie is produced without a Flash IDE by injecting our class into a copy of
the game's own `messagebox.swf` -- see *How the .swf is built* below.

**Requires** SKSE and [Address Library for SKSE
Plugins](https://www.nexusmods.com/skyrimspecialedition/mods/32444). The plugin
is version-independent and one binary covers **1.6 and 1.7**; Address Library
is the mechanism that makes that work, so without it nothing loads.

## Why a Scaleform menu

A Scaleform menu *is* the game's UI. It is registered on the menu stack, takes
input through the game's own handling, and is drawn by the same renderer as
`statsmenu.swf`. A replacer such as NORDIC UI or SkyUI restyles it for free.

Nothing about the look is imitated: the panel art, the border, the font and the
button prompts are all the game's own, so the menu follows whatever the player
has installed instead of drifting from it.

The C++/AS2 split is deliberate: **C++ owns the data, ActionScript owns the
look.** `CalendarMenu::PushMonth` builds a plain object -- month, day cells,
today, events -- and calls `_root.setCalendarData`. It draws nothing. That
means the entire appearance is in the one file a replacer would override.

Paging is a round trip (`RequestMonth`) rather than the movie doing its own
date maths. Month lengths and the weekday anchor are calendar rules, and
Skyrim's weekday comes from `GameDaysPassed` rather than from the date -- see
`GameDate::WeekdayOf`. Reimplementing that in AS2 would let the two drift.

## How the .swf is built

**Skyrim runs SWF 10 / ActionScript 2**, and the Flash authoring tools that
targeted it are gone. Rather than needing Flash CS6, the menu is built by
replacing one class inside a copy of the game's own `messagebox.swf`, using
JPEXS FFDec's CLI:

```powershell
cd flash
.uild-swf.ps1 -Deploy
```

That starts from `base-messagebox.swf` and swaps its `MessageBox` class for
`src/CalendarMenu.as`. Starting from a vanilla menu is the point of the
approach: everything below comes along unmodified, with no stage to author.

| Inherited | What it gives us |
| --- | --- |
| `Background_mc` | the real panel, with a `DefineScalingGrid` 9-slice |
| `MessageBoxButton` | a focusable button with a selection indicator |
| `Divider` / `DiamondMarker` | the vanilla rule and ornament |
| `$EverywhereMediumFont` | the game's font, imported from `gfxfontlib.swf` |
| `handleInput` | keyboard **and** gamepad navigation |
| `GameDelegate` | the call/callback bridge to the SKSE plugin |

FFDec labels AS1/2 replacement EXPERIMENTAL, so the script does not trust its
exit code: it decompiles the result back and fails the build unless our code
is really in there.

### What the base movie actually provides

The stage names only three instances -- confirmed from the SWF's `PlaceObject`
tags. Every other field the calendar needs is created at runtime in
`BuildText()` and `BuildGrid()`. Referencing a stage name that does not exist
fails *silently* (the assignment goes to `undefined`), which is what once left
the vanilla `<message text>` placeholder on screen with the class bound and
running; `build-swf.ps1` now warns about it.

| Instance | Notes |
| --- | --- |
| `Background_mc` | shape is 432×155px, ~30px 9-slice margins |
| `Divider` | 396×2px rule |
| `MessageText` | 348×119px, multiline + wordWrap, reused as the heading |

Text fields created at runtime are a trap: the vanilla fields name their font
**inline in the HTML** as `face="$EverywhereMediumFont"` (imported from
`gfxfontlib.swf`), and `setNewTextFormat()` does not carry that binding across.
A field built with `createTextField()` renders every glyph as an empty black
box unless the markup supplies the font tag itself. Everything this menu writes
therefore goes through `Markup()`, and `build-swf.ps1` fails the build on any
`htmlText` write that does not.

`MessageMenu` -- the root placement of the whole menu -- sits at **(640, 360)**
on the 1280×720 stage, so the class lays everything out around `(0,0)` and the
origin is already screen centre.

### Controls

| Action | Keyboard | Gamepad |
| --- | --- | --- |
| Previous month | `Q` | `LB` |
| Next month | `R` | `RB` |
| Back to today | `T` | `Y` |
| Move selection | arrows | d-pad |
| Select | click | `A` |
| Open a day | `Enter`, click | `A` |
| Close | `Esc` | `B` |

Not `E`. The game claims it in menu contexts, so the keypress never reaches
this menu -- it looks like the feature is broken rather than unbound. See
`Settings::prevMonthKey` for the rest of that reasoning.

Inside the note editor:

| Action | Key |
| --- | --- |
| Add or edit a note | `N` |
| Switch field | `Tab` |
| Save | `Enter` |
| Cancel | `Esc` |
| Delete the note | `F4` |

Every one of these is a prompt on screen as well as a key: icon plus caption,
clickable, drawn from the live binding so a rebind moves the key and its
picture together.

### The day popup

Pressing `Enter`/`A` on a selected day -- or clicking one -- opens a panel with
the day's holidays and their full descriptions. **A day with no events does
nothing**, so an empty square never produces an empty panel.

The panel is `CalendarPanel`: the base movie's own `Background_mc` (sprite 11),
exported by `import-buttonart.py` because messagebox.swf does not export it
itself. It carries a `DefineScalingGrid`, so the popup is sized from its
**measured** text height (`autoSize` keeps `_height` honest) and the border
9-slices correctly however far it stretches. Nothing guesses a line count.

The `MessageBox` symbol (chid 15) holds the same art and *is* exported, but is
deliberately not used: `registerClass` binds that symbol to this very class, so
attaching it would construct a second entire calendar rather than a blank panel.

While the popup is open it owns the keyboard -- month keys are swallowed so the
grid cannot page behind it -- and it closes on `Enter`/`A`/`Esc`/`B`, on a click
anywhere over it, or automatically if the month changes underneath it.

There are no on-screen nav buttons: the prompt bar under the sub-line *is*
the control, showing each bound key's ButtonArt icon next to its caption.

The bar shows **Prev Month · Today · Next Month**, in that order, so Today sits
between the two months it steps back from. There is deliberately no Close
prompt: `Esc` (and `B`) closes every menu in the game, so labelling it taught
nobody anything and cost a quarter of the bar. The binding is untouched -- only
the label is gone, and the close scan codes are still sent, so restoring the
prompt is a one-line `AddPrompt`.

A prompt bar along the bottom labels the bindings, and switches between the
keyboard and gamepad sets based on `usingGamepad`, which the plugin sends with
each month. That comes from `BSInputDeviceManager::IsGamepadEnabled()` rather
than Scaleform's `setPlatform` callback: the game pushes `setPlatform` only
when the device *changes*, so a menu opened after a switch would never receive
it and would label the wrong buttons.

`Q`/`E`/`R` are matched on `details.code`, not `navEquivalent` -- `NavigationCode`
only covers mapped navigation (arrows, pageUp/Down, face buttons) and has no
entry for plain letters. `details.code` is a Windows **VK** code, so bound scan
codes go through `ScanToVK` before comparison.

Escape is matched by raw code (27) as well as by `navEquivalent`: a day cell
holds focus while the menu is open and consumes the key before the mapped
`ESCAPE` case is reached, so without the raw check the menu cannot be closed
from the keyboard.

Today is reached with `RequestMonth(0)` -- the plugin's "snap back to today" --
so month arithmetic stays in C++ and cannot drift from the grid.

`setKeys` arrives from the plugin **before** `setCalendarData`, so `SetKeys`
records the bindings first and only *draws* the prompt row if the bar already
exists; `SetCalendarData` calls `DrawPrompts()` once it has built it. Getting
that order wrong leaves the row blank on first open and no key bound until the
player pages the month.

Arrow keys always drive the day grid: `handleInput` intercepts them and
returns handled before the focus chain sees them, so clicking a nav button
never strands keyboard navigation on it.

Cell geometry is measured rather than guessed: `MessageBoxButton`'s
`ButtonText` is 100×55px at `x=-48`, so `CELL_W`/`CELL_H` match that and the
cells are resized with `setSize()` -- not `_width`/`_height`, which
`gfx.core.UIComponent` caches in `__width`/`__height` and writes back over on
the next redraw.

## Notes

The player writes their own entries on any day: a name and a description,
opened with `N` from the day panel.

Notes live in the **SKSE co-save**, not in a JSON file. They belong to one
playthrough, so a note written on one character never appears on another, and
they travel with the save rather than with the mod. `Notes::Register` installs
the save, load and revert callbacks at plugin load rather than at
`kDataLoaded` -- SKSE dispatches the load callback for a save that was already
loading when the game started, and a handler registered later misses it.

Revert matters as much as load. The store is global, so without a revert
callback notes from the previous character would survive into the next one
loaded in the same session.

At the movie boundary a note is merged into the same per-day `events` array the
JSON events use, carrying `isNote: true`. The .swf draws both the same way and
knows nothing about the distinction; only the editor cares, and it keys off
that flag rather than the kind string -- authored JSON may legitimately use
`"note"` too.

Note text is stored verbatim and deliberately **not** run through
`Localization::Resolve`. A player who types a `$` means the character, not a
translation key.

Deleting is either the `F4` prompt, which asks first, or clearing both fields
-- an entirely blank note removes itself rather than occupying a day as an
invisible entry.

### Text entry

Getting a Scaleform text field to work in Skyrim is the fiddly part, and the
working reference is SkyUI's own search box
(`skyui.components.SearchWidget`). What it does, and what this follows:

* **`skse.AllowTextInput` is called from the movie**, and owned there. SKSE
  injects it into every Scaleform movie. It is a refcount: calling it from the
  plugin *as well* raises the count twice per edit while lowering it once, and
  the game then stays in text mode after the menu closes with the player unable
  to move. One owner. The plugin touches it only in the menu's destructor, to
  release a hold the movie can no longer release itself.
* **`handleInput` returns the delegate's answer**, not `true`. Typed characters
  never travel through `handleInput` -- Scaleform routes them straight to
  whatever `Selection.setFocus` points at, but only if the menu does not claim
  the event. Returning `true` to "block" keys is exactly what stops the field
  ever receiving a character.
* **`FocusHandler.instance.setFocus` is not called** for a bare `TextField`.
  It writes `currentFocusLookup`, which `getPathToFocus` walks, and pointing
  that at something with no `handleInput` breaks dispatch to the menu.
* **Real keys come from `skse.GetLastKeycode`.** `details.code` is the
  player's *binding* rather than the key, and inside a focused field it cannot
  tell one letter from another.

The plugin's only other job is staying out of the way: `InputHandler` skips its
own hotkey while a field is live, or typing the hotkey's letter would both type
the character and close the menu.

## Moon phases

Each day's cell shows the moon, and the day panel names the phase.

Vanilla Skyrim does not simulate its moons. They are flat billboards with eight
pre-rendered textures, and the phase is a modulo on the day counter: 24 days,
eight phases, three days each. Both moons share one phase, which is why Masser
and Secunda always match in the sky.

Because it is a pure function of that counter, the phase is deterministic in
**both directions** -- any past or future date can be computed without the game
having been there. That is what makes it usable across a calendar grid rather
than only as a "tonight's moon" readout.

The phase is drawn in ActionScript rather than shipped as art: a lit disc with
the terminator placed for the crescent and gibbous phases. The dark side is
drawn too, not left empty -- a new moon with nothing drawn is indistinguishable
from a day with no phase marked.

Phase names go through the translation table (`CalendarUI_MoonFull` and
friends), so a localized game names them in its own language.

## Holidays

Events are data, not code: every `*.json` under
`SKSE/Plugins/CalendarUI/Events/` is loaded and merged, so a mod adds holidays
by shipping its own file rather than editing anyone else's. Full authoring
reference is in that folder's `00_README.txt`.

Two sets ship, split by *who actually keeps the holiday*:

| File | Count | Contents |
| --- | --- | --- |
| `10_Vanilla.json` | 17 | Kept across Tamriel as a whole, plus Skyrim's own |
| `20_Provinces.json` | 41 | Optional. High Rock, Hammerfell, Morrowind, Elsweyr, Summerset |

The province set ships as a separate folder under `dist/optional/` so it is
installed deliberately, not by default. A Nord in Skyrim would never have heard
of Riglametha in Lainlyn, so the base file stays to what such a character would
plausibly observe; the add-on is for players who want the whole Tamrielic year.

An event recurs every year unless it carries a **`year`**, which pins it to that
one Fourth Era year -- for something that happened once rather than something
kept, such as the Great Collapse in 4E 122. `InMonth` filters on the year being
viewed, and `Next` deliberately does *not* roll a pinned event over to the
following year the way it does a holiday: it happens once, so once it is past it
is never "next" again.

**`kind`** is `holiday`, `festival`, `history` or `note`. Nothing acts on it yet
beyond carrying it through to the movie, but it is the field a later version
would colour or filter by, so it is worth setting correctly now. `history` pairs
naturally with a `year`.

**At most one holiday per day** in the shipped data, and that holds with *both*
files installed --
no date in the province set collides with one in the base set. A day with two
events would draw only the first on the cell, so this is enforced when the
files are generated rather than left to chance.

Dates follow the Arena and Daggerfall era lore. Three in the previous file were
wrong and have been corrected:

| Holiday | Was | Now |
| --- | --- | --- |
| Marukh's Day | First Seed 21 | Second Seed 9 (First Seed 21 is Hogithum) |
| Warriors' Festival | Evening Star 20 | Sun's Dusk 20 |
| Emperor's Day | Sun's Dusk 30 | Frostfall 30, as *The Emperor's Birthday* |

Old Life stays on Evening Star 31. Daggerfall put it on the 30th, but later
games use the 31st, which is the right call for a Skyrim-era mod.

## Settings

`SKSE/Plugins/CalendarUI.ini`. Appearance is not here -- that lives in the
`.swf`, which is the point of this build.

| Section | Key | Default | Notes |
| --- | --- | --- | --- |
| `General` | `Hotkey` | `0x26` (L) | DX scan code |
| | `LogLevel` | `warn` | `off` / `error` / `warn` / `info` / `debug` |
| `Controls` | `PrevMonthKey` | `0x10` (Q) | also picks the ButtonArt icon |
| | `NextMonthKey` | `0x13` (R) | |
| | `TodayKey` | `0x14` (T) | |
| | `NoteKey` | `0x31` (N) | opens the note editor |
| | `NoteDeleteKey` | `0x3E` (F4) | deletes the note being edited |
| | `NoteDeleteNeedsCtrl` | `0` | set to `1` if you rebind delete to a letter |
| `Moons` | `ShowMoonPhases` | `1` | the disc in a day's top-right corner |
| | `CycleDays` | `24` | vanilla's lunar cycle |
| | `DaysPerPhase` | `3` | 8 phases x 3 days = the 24-day cycle |
| `Seasons` | `WinterStart` | `Evening Star` | month name or 0-based index |
| | `SpringStart` | `First Seed` | |
| | `SummerStart` | `Midyear` | |
| | `AutumnStart` | `Hearthfire` | |

**`LogLevel`** defaults to `warn` rather than `info`, so a working setup writes
almost nothing while anything the Calendar had to *throw away* -- a malformed
event file, an unparsable translation line -- still reports itself. It is read
before the logger is created, so nothing is written at a level the player asked
not to see. A typo falls back to `info` rather than silence: somebody editing
this key is usually trying to turn logging **up**.

**`NoteDeleteKey`** defaults to `F4` because a function key is never text: it
cannot be confused with typing into the note fields, so it needs no modifier.
Rebind it to a plain letter and set `NoteDeleteNeedsCtrl=1`, where the modifier
becomes the only thing separating the command from the character.

`NoteSaveKey`, `NoteCancelKey` and `NoteSwitchKey` also appear in the INI but
feed the **on-screen hint only**. The editor matches those three through
Scaleform's own navigation events rather than a scan code, which is what makes
them work on a gamepad as well as a keyboard, so the real keys are always
Enter, Escape and Tab. Changing the values would make the hint disagree with
reality.

**`[Moons]`** draws a small moon in the top-right corner of a day.

Vanilla Skyrim does not simulate its moons. `RE::Moon` holds eight
pre-rendered textures and the engine picks one by a modulo on the day counter:
a 24-day cycle, eight phases, three days each. Both moons always show the same
phase -- no offset is coded between them. Because it is a pure function of the
day counter it is deterministic in *both* directions, so any past or future
month can be drawn without the game having been there, which is what makes it
usable on a grid rather than only as a "tonight's moon" readout.

The anchor is `Calendar::GetDaysPassed()` rather than `RE::Sky`: `Sky` is only
valid in a loaded world, so it is null in exactly the places this menu can
still be open. There is no date epoch, so `Moons::Cycle` anchors on today and
walks the day difference -- the same trick `GameDate::WeekdayOf` uses, and for
the same reason.

All **eight phases** are marked, but only on the day each one *begins* --
nine to eleven icons a month, one every three days. Marking the turn is the
part that matters: a phase *lasts* three days, so testing which phase a day
falls in would put an icon on every single cell. Only the day the moon
actually changes is news.

The disc itself is one closed path per phase, never a mask. Each is a **lune**:
a semicircular limb on the lit side, closed by a half-*ellipse* for the
terminator, whose width shrinks to nothing at the quarters and whose bulge
direction separates a crescent from a gibbous. Masking instead would mean a
second clip for every cell, and 31 of those a month is what makes a menu feel
heavy. Waxing phases are lit on the right and waning on the left, matching the
game's own moon textures -- the icon should not disagree with the sky.

`CycleDays` and `DaysPerPhase` are settings rather than constants because the
moons are the one thing a mod is likely to have changed underneath the
calendar -- *Moons and Stars - Sky Overhaul*, for instance, runs Masser on 24
days and Secunda on 20. There is no API to ask such a mod what it did, so the
next best thing is letting the player say. Both are validated positive at load;
they are divided by once per cell, so a `0` would otherwise be a divide by
zero.

The disc is drawn with the AS2 drawing API, not attached as artwork -- the same
choice the cell frames make. No new symbol has to be authored into the SWF, so
the phases survive the FFDec injection step and a UI replacer inherits them
without holding any assets. The dark side is *drawn* rather than left empty: a
new moon has no lit part, so with nothing behind it the corner would be blank
and indistinguishable from an unmarked day.

**`[Seasons]`** exists because Skyrim has none of its own -- the four seasons are
the calendar's own notion, so there is no correct set to inherit. Each key is
the month that season *begins*, and a season runs until the next one starts, so
they need not be equal: a long winter and a short spring is just a matter of
moving the boundaries. `SeasonOf` walks backwards from the month to the most
recent start rather than dividing by three, so neither the order nor the lengths
are assumed. The shipped defaults reproduce the previous hardcoded split exactly.

## Why the menu is preloaded

`CalendarMenu::Preload()` builds one menu at `kDataLoaded` and immediately
throws it away. That is not redundant -- deleting it brings back a visible stall
on the **first** open, with every later open instant.

The cause is not this mod's `.swf`, which is 20KB. It is the font: the movie
names `$EverywhereMediumFont`, imported from `gfxfontlib.swf` (347KB) inside
`Skyrim - Interface.bsa` (**106MB**), and those glyphs have to be found,
decompressed and rasterized before anything can draw. The game caches that
globally, which is exactly why only the first open pays for it.

Preloading moves the cost into load, where a pause is expected, instead of onto
the player's first keypress -- where it reads as a broken hotkey. The instance
is discarded; the warmed cache is what we keep. It is deliberately **not**
pushed onto the menu stack, so nothing is shown: `PostCreate()` is called by the
menu system rather than by the constructor, so a bare construction loads the
movie without pushing data or touching the UI stack.

## Names and translation

**No month or day name is hardcoded.** They are read from the game's own
settings -- `sMonthJanuary`…`sMonthDecember` and `sDaySunday`…`sDaySaturday`.

That identifier is misleading: vanilla Skyrim ships *"Morning Star"* in
`sMonthJanuary`, not *"January"*. (An earlier comment in `GameDate.h` claimed
the opposite, which is why the names used to be a hardcoded table.) Reading
the setting is therefore both correct and free:

- **Localized automatically** -- every localized copy of Skyrim already
  translates these, so a French player sees French months with nothing shipped
  by us.
- **Follows renaming mods** -- a mod that renames the months is picked up
  because the game, not a table of ours, is the source of truth.

The tables in `GameDate.h` survive only as a fallback for when the setting is
missing or empty, and are never preferred over what the game reports.
`GameDate::RefreshNames()` drops the cache at `kDataLoaded`, once every plugin
has applied its GMSTs.

The grid's three-letter column headings are derived the same way -- Skyrim has
no abbreviated-weekday setting (a scan of all 1,584 GMSTs in `Skyrim.esm`
finds only the seven full names), so `DayAbbrev` truncates the day name to
three characters. That still beats a table of our own, because it shortens
whatever the name currently is: a localized game abbreviates its own
translated names and a renaming mod's days are shortened too. The cut is
character-wise, not byte-wise, so Cyrillic and CJK names are not split
mid-character. `$CalendarUI_DayAbbrev0..6` override it where a blind cut reads
badly.

Everything else the menu says -- button hints, seasons, the `4E` era prefix and
`Next: … (in 5 days)` -- goes through `Localization`, which reads Skyrim's own
translation format:

```
Data/Interface/Translations/CalendarUI_ENGLISH.txt   # UTF-16 LE, $KEY<TAB>Value
```

English loads first as a base and the player's language over the top, so a
partial translation falls back key by key instead of showing raw `$KEY`s.

Two deliberate choices are worth knowing:

- **The strings live in C++, not in the `.swf`.** The movie is the file a UI
  replacer overrides; a caption baked into ActionScript would be lost on
  reskin, and translating would mean rebuilding the movie with FFDec. Instead
  `PushMonth` sends a `labels` object and AS2 only ever reads it.
- **`noTranslate = true` on every text field, so the engine's own `$KEY`
  substitution never runs.** It has to be -- the fields are fed hand-built HTML
  and the engine's pass would mangle the font tags. The plugin resolves keys
  itself and pushes finished text.

Event `name`/`description` may also be written as a `$KEY`, so a mod author's
own holidays can be translated without that being forced on anyone.

`Interface/Translations/00_README.txt` is the translator-facing guide.

## Building

CommonLibSSE-NG is a **submodule**, so clone with it:

```powershell
git clone --recursive https://github.com/g7138580/CalendarUI.git
```

If you already cloned without `--recursive`:

```powershell
git submodule update --init --recursive
```

It is the [alandtse fork](https://github.com/alandtse/CommonLibSSE-NG), built
from source and pinned to an exact commit rather than pulled from vcpkg. That
fork is what lets one binary serve **1.6 and 1.7** -- stock CommonLibSSE-NG
misreads the 1.7 minor-version bump as SE. Building it is most of the build
time; the plugin itself takes seconds.

Then:

```powershell
.\build.ps1
```

Builds and deploys the DLL, the INI and the event data. Set
`SKYRIM_MODS_FOLDER` to your MO2 `mods` directory first, and
`CALENDARUI_MOD_FOLDER` if the mod is installed under a name other than
`CalendarUI`. A Wabbajack list may use something like `[NoDelete] CalendarUI`,
and deploying to a guessed name silently creates a folder MO2 has never heard
of while the game goes on loading the old DLL.

It does **not** build the `.swf` -- that is a separate step, because it needs
FFDec rather than the C++ toolchain:

```powershell
cd flash
.\build-swf.ps1 -Deploy
```

Run it after any change to `flash/src/CalendarMenu.as`. `-Deploy` copies the
result into `dist/CalendarUI/Interface/`; without it the build stops at
`flash/CalendarUI.swf`.

## Opening it from other mods

The menu is registered as **`CalendarUI`** -- the same string as the movie, so
there is only one name to know. That is what anything else uses to open it.

Two tween wheels are supported out of the box, and each gets **its own file**
-- they read different folders and take different formats, so one config cannot
serve both. Both ship with the mod; the wheel you do not use simply ignores its
file.

[Tween Menu Overhaul](https://www.nexusmods.com/skyrimspecialedition/mods/64409)
reads `Interface/tweenoptions/calendarui.json`:

```json
{
	"skseName":"CalendarUI",
	"menuName":"CALENDAR",
	"icon":"scroll",
	"priority": 70,
	"category": "bottom"
}
```

[Extended Tween
Menu](https://www.nexusmods.com/skyrimspecialedition/mods/184488) reads
`Interface/ExtendedTweenMenu/CalendarUI.json`, which is a different shape
entirely:

```json
{
    "menuName": "CalendarUI",
    "label": "Calendar",
    "icon": "note"
}
```

Note that `menuName` means different things in the two. For Extended Tween Menu
it is the **registered menu name** -- the string Tween Menu Overhaul calls
`skseName` -- while Tween Menu Overhaul's own `menuName` is the *caption on the
wheel*, which Extended Tween Menu calls `label`. The same word, swapped roles;
copying a value across from one file to the other produces an entry that does
nothing.

`skseName` must be the **registered menu name**, not the `.swf` -- that is the
one thing to get right here, and a mismatch fails silently: the entry appears on
the wheel and simply does nothing when clicked. The other shipped options are
the same shape (`InventoryMenu`, `MagicMenu`, `Journal Menu` -- note the space in
that one; they are exact engine strings).

Opening from the wheel is also what settled the **cursor flags**. This menu
originally set `kUsesCursor | kAssignCursorToRenderer | kUpdateUsesCursor`,
which works by hotkey but hands the pointer back to *Windows* when opened from
the wheel -- the cursor leaves the game rather than merely disappearing.

`kAssignCursorToRenderer` is simply the wrong flag for a stacked menu. Across
all of vanilla only `HUDMenu` and `KinectMenu` set it, and both are
`kAlwaysOpen` overlays that own the screen -- never something pushed on top of
another menu. Every stacked menu that works from the wheel (Inventory, Magic,
Container, Barter, Gift, Favorites, Journal) uses `kUpdateUsesCursor` and sets
*neither* `kUsesCursor` nor `kAssignCursorToRenderer`.

The flags here now follow `JournalMenu`, the closest vanilla match -- the only
one that also sets `kTopmostRenderedMenu`. Cursor handling is left entirely to
the menu system, as it is for every vanilla menu.

`category` is one of `top` / `left` / `right` / `bottom`, mapped to a label by
the wheel mod's own `categories/categories.json`, and `priority` orders entries
within a category.

## Where things live

| What | Path |
| --- | --- |
| Hotkey | **L** (`0x26`), set in the INI |
| Log | `Documents\My Games\Skyrim Special Edition\SKSE\CalendarUI.log` |
| Settings | `SKSE/Plugins/CalendarUI.ini` |
| Events | `SKSE/Plugins/CalendarUI/Events/` |
| Translations | `Interface/Translations/` |
| Movie | `Interface/CalendarUI.swf` |
