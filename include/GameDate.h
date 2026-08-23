#pragma once

// The calendar model: Tamriel's date, independent of both the game and the UI.
//
// This is the layer the event engine will build on, so it deliberately knows
// nothing about the UI and touches RE:: only where it reads the game's own
// date and names. Everything else is plain arithmetic on a Date, which means
// it can be reasoned about (and later tested) without a running game.

namespace GameDate {

    inline constexpr int kMonthsPerYear = 12;
    inline constexpr int kDaysPerWeek = 7;

    // Skyrim has no leap year: Sun's Dawn is always 28 days. Mirrors
    // RE::Calendar::DAYS_IN_MONTH, restated here so the model stands alone.
    inline constexpr int kDaysInMonth[kMonthsPerYear] = {
        31,  // Morning Star
        28,  // Sun's Dawn
        31,  // First Seed
        30,  // Rain's Hand
        31,  // Second Seed
        30,  // Midyear
        31,  // Sun's Height
        31,  // Last Seed
        30,  // Hearthfire
        31,  // Frostfall
        30,  // Sun's Dusk
        31   // Evening Star
    };

    // ---- names ----------------------------------------------------------
    //
    // Month and weekday names are READ FROM THE GAME, not from this file.
    //
    // Skyrim keeps them in game settings: sMonthJanuary..sMonthDecember and
    // sDaySunday..sDaySaturday. The names are real-world in the *identifier*
    // only -- vanilla ships "Morning Star" in sMonthJanuary, which is exactly
    // what a Tamriel calendar wants. (An earlier comment here claimed these
    // returned "August"; that was wrong, and it is why the names used to be
    // hardcoded.)
    //
    // Reading them buys two things at once:
    //
    //   * Localization for free. The GMST is already translated in every
    //     localized copy of the game, so a French player sees French months
    //     with no work from us and no translation file entry.
    //   * Mod awareness. A mod that renames the months -- and several calendar
    //     and roleplay mods do -- is followed automatically, because the game
    //     is the single source of truth rather than a table we shipped.
    //
    // The tables below remain as the LAST-RESORT fallback, used only when the
    // setting is missing or empty (no game loaded, a broken modlist). They are
    // never preferred over what the game reports.

    inline constexpr const char* kFallbackMonthNames[kMonthsPerYear] = {
        "Morning Star", "Sun's Dawn",  "First Seed", "Rain's Hand",
        "Second Seed",  "Midyear",     "Sun's Height", "Last Seed",
        "Hearthfire",   "Frostfall",   "Sun's Dusk", "Evening Star"
    };

    // Alternative spellings accepted when parsing authored data.
    //
    // Vanilla's own strings differ from the spellings above in two places --
    // Skyrim.esm ships "Mid Year" (two words) and "Heartfire" (no 'h'),
    // confirmed by resolving the GMSTs through skyrim_english.strings. Both
    // forms are in circulation, so an event file written with either has to
    // load, and a player whose game reports the vanilla spelling must not see
    // their events silently skipped.
    //
    // Display still uses whatever the game returns; this table only widens
    // what ParseMonth will accept. Indexed to match kFallbackMonthNames; an
    // empty entry means the month has no common variant.
    inline constexpr const char* kAltMonthNames[kMonthsPerYear] = {
        "", "", "", "",
        "", "Mid Year", "", "",
        "Heartfire", "", "", ""
    };

    // The weekday names, indexed to match RE::Calendar::Days.
    inline constexpr const char* kFallbackDayNames[kDaysPerWeek] = {
        "Sundas", "Morndas", "Tirdas", "Middas", "Turdas", "Fredas", "Loredas"
    };

    // Column headings for the grid.
    //
    // Derived by truncating the game's own day name to kDayAbbrevLength, NOT
    // stored as their own strings. Skyrim has no abbreviated-weekday setting
    // -- a scan of all 1,584 GMSTs in Skyrim.esm finds only the seven full
    // names -- so there is nothing to read directly.
    //
    // Truncating is still better than a table of our own, because it follows
    // whatever the full name currently is: a localized game abbreviates its
    // own translated names, and a mod that renames the days has its headings
    // shortened too. A static table would go stale against both.
    //
    // $CalendarUI_DayAbbrev0..6 still override this when present, for
    // languages where a blind cut reads badly.
    inline constexpr int kDayAbbrevLength = 3;

    // Used only when the day name itself is unavailable.
    inline constexpr const char* kFallbackDayAbbrev[kDaysPerWeek] = {
        "Sun", "Mor", "Tir", "Mid", "Tur", "Fre", "Lor"
    };

    // The GMST each month/day name is read from. Indexed as above.
    inline constexpr const char* kMonthSettings[kMonthsPerYear] = {
        "sMonthJanuary", "sMonthFebruary", "sMonthMarch",     "sMonthApril",
        "sMonthMay",     "sMonthJune",     "sMonthJuly",      "sMonthAugust",
        "sMonthSeptember", "sMonthOctober", "sMonthNovember", "sMonthDecember"
    };

    inline constexpr const char* kDaySettings[kDaysPerWeek] = {
        "sDaySunday", "sDayMonday", "sDayTuesday", "sDayWednesday",
        "sDayThursday", "sDayFriday", "sDaySaturday"
    };

    // A day on the calendar. `month` is 0-based to match RE::Calendar and index
    // the tables above; `day` is 1-based, as a date is written.
    struct Date {
        int year = 201;
        int month = 0;  // 0 = Morning Star
        int day = 1;    // 1-based

        [[nodiscard]] constexpr bool operator==(const Date&) const = default;
    };

    [[nodiscard]] constexpr int DaysInMonth(int month) {
        return (month >= 0 && month < kMonthsPerYear) ? kDaysInMonth[month] : 30;
    }

    // The month's name as the running game reports it, falling back to the
    // table above. Not constexpr any more, and deliberately so: the whole
    // point is that this is a runtime question with a runtime answer.
    //
    // Cached rather than read per call -- a month view asks for a name once
    // per cell -- and the cache is dropped by RefreshNames() so a mid-session
    // language or mod change is still picked up.
    [[nodiscard]] std::string MonthName(int month);

    [[nodiscard]] std::string DayName(int weekday);

    // The grid's column heading. From the translation file, not the game.
    [[nodiscard]] std::string DayAbbrev(int weekday);

    // Drops the cached names so the next call re-reads the game. Called once
    // the data files are loaded, when the GMSTs are known good.
    void RefreshNames();

    // Today, read from the running game. Falls back to the vanilla start date
    // (17 Last Seed, 4E 201) if the Calendar singleton is not up yet.
    [[nodiscard]] Date Today();

    // The in-game hour, 0-24.
    [[nodiscard]] float CurrentHour();

    // Weekday (0 = Sundas) of `date`.
    //
    // The game derives the weekday from GameDaysPassed, not from the date, so
    // it cannot be recomputed from a date in isolation -- there is no fixed
    // epoch to count from. Instead we anchor on today's known (date, weekday)
    // pair and walk the day difference. That keeps the grid aligned with
    // whatever the game itself reports for today.
    [[nodiscard]] int WeekdayOf(const Date& date);

    // Ordinal day within the year, 0-based. Used to measure date differences.
    [[nodiscard]] int DayOfYear(const Date& date);

    // Signed day count from `from` to `to`.
    [[nodiscard]] int DaysBetween(const Date& from, const Date& to);

    // Month stepping, rolling the year over. `day` is clamped into the new
    // month so stepping off 31 Frostfall lands on a valid date.
    [[nodiscard]] Date AddMonths(const Date& date, int delta);

}
