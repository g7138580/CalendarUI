Translating CalendarUI
======================

Thank you for translating this mod. It should take about ten minutes, needs no
tools beyond a text editor, and nothing has to be recompiled.


What to do
----------

1. Copy CalendarUI_ENGLISH.txt and rename the copy for your language:

       CalendarUI_FRENCH.txt
       CalendarUI_GERMAN.txt
       CalendarUI_RUSSIAN.txt
       ...

   The name must match the language Skyrim is running in -- that is the
   sLanguage setting in Skyrim.ini. Use the same spellings Bethesda does:
   ENGLISH, FRENCH, GERMAN, ITALIAN, SPANISH, POLISH, RUSSIAN, JAPANESE,
   CHINESE, CZECH.

2. Translate the text to the RIGHT of the tab on each line. Leave the $KEY on
   the left exactly as it is -- that is what the mod looks the line up by.

3. Save the file as UTF-16 LE (see "Encoding" below -- this part matters).

That is the whole job. Drop the file in Interface/Translations and it loads
the next time the game starts.


Encoding -- please read this
---------------------------

The file MUST be saved as **UTF-16 LE**. This is Skyrim's own requirement for
translation files, not ours.

  * Notepad:      Save As -> Encoding: "Unicode"  (this means UTF-16 LE)
  * Notepad++:    Encoding menu -> "UTF-16 LE BOM"
  * VS Code:      click the encoding in the status bar -> Save with Encoding
                  -> "UTF-16 LE with BOM"

Saving as UTF-8 is the single most common mistake. CalendarUI will still try
to read a UTF-8 file so your work is not lost, but it writes a warning to the
log and other mods' tools may not be as forgiving -- so fix the encoding.

Lines end with CRLF and the key is separated from the value by a TAB, not
spaces. Copying the English file rather than typing one from scratch keeps all
of that correct automatically.


A partial translation is fine
-----------------------------

English is loaded first as a base, then your file on top. Any line you have
not translated yet falls back to English rather than showing a raw $KEY, so
you can ship an incomplete file and finish it later.


What you do NOT need to translate
---------------------------------

**Month and day names are not in this file, on purpose.**

CalendarUI reads them from the game itself (the sMonthJanuary..sMonthDecember
and sDaySunday..sDaySaturday game settings). Your copy of Skyrim already has
those translated, so the calendar shows the correct month names in your
language with no work from you -- and it automatically follows any mod that
renames the months.

The three-letter column headings above the grid are not in this file either.
They are the first three characters of the game's own day name, so "Sundas"
becomes "Sun" and a translated or renamed day is shortened the same way.

If that reads badly in your language -- some languages need a different
abbreviation than a blind cut gives -- you can override any of them by adding
these lines yourself:

    $CalendarUI_DayAbbrev0	Sun     (Sundas)
    $CalendarUI_DayAbbrev1	Mor     (Morndas)
    $CalendarUI_DayAbbrev2	Tir     (Tirdas)
    $CalendarUI_DayAbbrev3	Mid     (Middas)
    $CalendarUI_DayAbbrev4	Tur     (Turdas)
    $CalendarUI_DayAbbrev5	Fre     (Fredas)
    $CalendarUI_DayAbbrev6	Lor     (Loredas)

They are optional -- leave them out entirely unless you need them. Keep any you
do add SHORT: they sit in narrow grid columns and long text is clipped. Three
or four characters is right.


The keys
--------

  $CalendarUI_PrevMonth      Button hint: go back one month.
  $CalendarUI_NextMonth      Button hint: go forward one month.
  $CalendarUI_Today          Button hint: jump back to today.
  $CalendarUI_Close          Button hint: close the calendar.

  $CalendarUI_Era            The era prefix in a date: "4E" in "4E 201".
                             Translate only if your language writes the
                             Fourth Era differently.

  $CalendarUI_Next           Label before the next upcoming holiday.
  $CalendarUI_OnToday        Used when that holiday is today.
  $CalendarUI_Tomorrow       Used when it is tomorrow.
  $CalendarUI_InDays         Used otherwise. {} is replaced by the number of
                             days -- keep the {} and put it wherever your
                             language needs it.

  $CalendarUI_SeasonWinter   The four seasons, shown next to the month name.
  $CalendarUI_SeasonSpring
  $CalendarUI_SeasonSummer
  $CalendarUI_SeasonAutumn

  $CalendarUI_MoonNew        The eight moon phases. Shown beside the date when
  $CalendarUI_MoonWaxingCrescent  you select a day the moon changes phase on --
  $CalendarUI_MoonFirstQuarter    the small disc drawn in the day's top-right
  $CalendarUI_MoonWaxingGibbous   corner is the shorthand for this.
  $CalendarUI_MoonFull
  $CalendarUI_MoonWaningGibbous   All eight are shown, so all eight are worth
  $CalendarUI_MoonThirdQuarter    translating.
  $CalendarUI_MoonWaningCrescent

Optional, not in the shipped file -- add them only if you need them:

  $CalendarUI_DayAbbrev0     Grid column headings, Sundas..Loredas in order.
  ...                        Defaults to the first three characters of the
  $CalendarUI_DayAbbrev6     game's day name. Keep to 3-4 characters.


Holiday names
-------------

The holidays themselves (New Life Festival, Heart's Day, ...) come from the
event files in SKSE/Plugins/CalendarUI/Events/, not from here.

To translate those, add a file of your own to that folder that overrides each
event's text by reusing its "id" -- see the 00_README.txt in that folder. Do
not edit 10_Vanilla.json directly; your changes would be lost on update.

An event's "name" and "description" may also be written as a $KEY, in which
case it is looked up in this file like anything else. That is the tidiest way
for a mod author to make their own events translatable.


Checking your work
------------------

Open the calendar in game. If something is still English, look at:

    Documents\My Games\Skyrim Special Edition\SKSE\CalendarUI.log

It logs which language it detected, which file it loaded, how many strings it
read, and it names any line it could not parse and why.
