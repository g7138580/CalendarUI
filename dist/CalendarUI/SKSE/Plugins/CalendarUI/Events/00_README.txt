Adding events to the Calendar
=============================

Every *.json file in this folder is loaded and merged. To add your own events,
ship your own file here -- do not edit 10_Vanilla.json. Yours will keep working
when the Calendar updates, and two mods can add events without either having to
overwrite the other's file.

Name your file after your mod so it is obvious where an event came from:

    Data/SKSE/Plugins/CalendarUI/Events/MyMod.json


A minimal file
--------------

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

A bare array also works if you prefer: [ { ... }, { ... } ]

That event recurs every year. To mark something that happened once, add a
"year":

    {
      "id": "mymod.the_collapse",
      "name": "The Great Collapse",
      "month": "Sun's Dusk",
      "day": 1,
      "year": 122,
      "kind": "history",
      "description": "Winterhold falls into the sea."
    }

It will then appear only when the calendar is showing 4E 122.


Fields
------

  name         Required. Shown on the day and in the tooltip.

  month        Required. A Tamriel month name ("Last Seed"), or a 0-based
               index (0 = Morning Star ... 11 = Evening Star).

  day          Required. 1-based, and must exist in that month -- Sun's Dawn
               has 28 days and there is no leap year.

  year         Optional. Leave it out and the event happens every year, which
               is what a holiday wants. Set it and the event appears in that
               one year only -- for something that happened once, like the
               Great Collapse. Write the Fourth Era year as the game reports
               it (vanilla starts at 201), not an offset.

  id           Optional but strongly recommended. A stable identifier, by
               convention "yourmod.event_name". It is what lets anyone else
               patch your event instead of duplicating it. See below.

  kind         holiday | festival | history | note. Defaults to holiday.

               holiday   a named day: Old Life, a Divine's feast
               festival  a celebration
               history   something that happened on this date rather than
                         something kept -- usually paired with a "year"
               note      anything else worth marking

               Nothing acts on kind yet beyond carrying it through to the
               menu, but it is the field a future version would colour or
               filter by, so it is worth setting correctly now.

  description  Optional. Shown in the tooltip and the detail panel.

  icon         Optional. Reserved. Parsed and carried, but nothing draws it
               yet -- safe to author now.

  effect       Optional. Reserved for the date engine. Parsed and carried, but
               nothing acts on it yet -- safe to author now.


Making your events translatable
-------------------------------

"name" and "description" may be written either as plain text or as a $KEY:

    {
      "id": "mymod.founding_day",
      "name": "$MyMod_FoundingDay",
      "description": "$MyMod_FoundingDayDesc",
      "month": "Sun's Height",
      "day": 12
    }

A value starting with '$' is looked up in the translation files under
Data/Interface/Translations/ and replaced with the text for the player's
language. Anything not starting with '$' is shown exactly as written, so
plain text keeps working and this is entirely optional.

If you use keys, ship the English text in your own translation file:

    Data/Interface/Translations/MyMod_ENGLISH.txt

as UTF-16 LE, one "$Key<TAB>Value" per line. See the 00_README.txt in that
folder for the details and the common pitfalls.

An unresolved key is shown as-is (you will see "$MyMod_FoundingDay" on the
day), which makes a missing or misspelled entry obvious rather than blank.


Month names and renaming mods
-----------------------------

Month names in "month" are matched against BOTH the standard Tamriel names
and whatever the game currently calls that month.

Write the standard English name -- "Last Seed" -- and your file keeps working
for every player regardless of their game language or whether they run a mod
that renames the months. That is the stable choice, and it is what the shipped
files use.

A 0-based index (0 = Morning Star ... 11 = Evening Star) also works and is
immune to naming entirely.


Overriding someone else's event
-------------------------------

Reuse their "id" in your own file. The later file wins, so your entry replaces
theirs entirely rather than adding a second one on the same day:

    {
      "events": [
        {
          "id": "vanilla.witches_festival",
          "name": "Witches' Festival",
          "month": "Frostfall",
          "day": 13,
          "kind": "festival",
          "description": "My own description for this one."
        }
      ]
    }

To delete an event instead, reuse the id with "remove":

    { "id": "vanilla.emperor_s_day", "name": "-", "month": 0, "day": 1,
      "remove": true }

(name/month/day are still required by the parser, but are ignored when
removing.)

Every shipped holiday carries an id of the form <file>.<slugged name>, with
apostrophes dropped: "Harvest's End" is vanilla.harvests_end, and holidays in
the optional province file use the provinces. prefix.


The shipped files
-----------------

    10_Vanilla.json      holidays kept across Tamriel, plus Skyrim's own
    20_Provinces.json    optional: holidays of the individual provinces
                         (High Rock, Hammerfell, Morrowind, Elsweyr,
                         Summerset). Leave it out for a Skyrim-only calendar.

No date collides between the two, so both can be installed together and there
is still at most one holiday per day.


Load order
----------

Files load in file-name order, so a patch that must win should sort last. The
usual convention works:

    10_Vanilla.json      the shipped holidays
    20_Provinces.json    the optional province set
    50_MyMod.json        your events
    zz_MyPatch.json      a patch that overrides things

Only ordering between *overriding* entries matters. Plain additions are
independent of order.


If something does not show up
-----------------------------

Check Documents\My Games\Skyrim Special Edition\SKSE\CalendarUI.log. Anything
skipped is logged with the reason. Set LogLevel=info in CalendarUI.ini to also
see every file that loaded and how many events it contributed. Common causes:

  * A day outside the month's real length (Sun's Dawn only has 28).
  * A misspelled month name -- they must match the Tamriel names exactly,
    though case does not matter.
  * A "year" that does not match the year being viewed. An event with a year
    set appears in that year and no other; drop the field to make it recur.
  * Invalid JSON. The file is skipped whole, but every other mod's events
    still load, so look for a line naming your file.

Two events with the same name on the same day from different files are also
warned about: that is usually two mods shipping the same holiday, and giving
it a shared id in both is the fix.
