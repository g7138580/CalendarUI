CalendarUI - Province Holidays
==============================

An optional add-on for CalendarUI.

CalendarUI ships with the holidays kept across Tamriel as a whole, plus
Skyrim's own -- New Life, Heart's Day, Harvest's End, the Burning of King Olaf
and so on. Seventeen in all.

This add-on adds forty-one more: the holidays of the individual provinces,
drawn from Arena and Daggerfall era lore. High Rock's Scour Day and Fishing
Day, Hammerfell's Ovank'a and Dirij Tereur, Morrowind's Hogithum, Elsweyr's
Feast of the Tiger, the Psijic rites of Summerset.

These are local customs, not continental ones. A Nord in Skyrim would most
likely never have heard of Riglametha in Lainlyn -- so if you want a calendar
that reflects what your character would actually observe, leave this out. If
you want the full Tamrielic year, install it.


Installing
----------

Install it with your mod manager after CalendarUI, or drop the SKSE folder into
Data. It is a single JSON file and nothing overwrites CalendarUI's own:

    Data/SKSE/Plugins/CalendarUI/Events/20_Provinces.json

To remove it, delete that file. Nothing else changes.


Compatibility
-------------

No date in this file collides with one in CalendarUI's 10_Vanilla.json, so
there is still at most one holiday per day with both installed.

Every entry carries a stable id of the form provinces.<name>, so another mod
can override or remove any of them without editing this file. See the
00_README.txt in the Events folder for how.
