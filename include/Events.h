#pragma once

// Calendar events: holidays, festivals and seasons.
//
// This is the seam the date engine grows into. Right now events are inert --
// loaded from JSON and drawn on the grid, nothing more. The point is that
// *what* a date means is data, not code, so giving a day an effect later is a
// matter of acting on an Event that already exists rather than inventing the
// concept then.

#include "GameDate.h"

namespace Events {

    // What a day is marked as. Kept separate from the event itself so the
    // window can colour a festival differently from a plain note.
    enum class Kind {
        kHoliday,   // a named day: Old Life, New Life, a Divine's feast
        kFestival,  // a celebration, usually with an effect attached later
        kHistory,   // something that happened on this date, not celebrated
        kNote       // anything else worth marking
    };

    struct Event {
        std::string name;
        std::string description;
        Kind        kind = Kind::kHoliday;

        // Optional stable identifier. Two files using the same id refer to the
        // same event: the later one replaces the earlier, or removes it with
        // "remove": true. This is what lets a patch adjust a holiday it did
        // not author without editing that mod's file.
        std::string id;

        // The file this came from. Kept so a conflict can name both sides.
        std::string source;

        // When it falls. Month is 0-based; day is 1-based.
        int month = 0;
        int day = 1;

        // The year it falls in, or kEveryYear for one that recurs.
        //
        // Omitting "year" in the JSON gives a holiday: the same date every
        // year, which is what nearly every entry wants. Setting it pins the
        // event to that one year, for a historical date ("the Great Collapse,
        // 4E 122") that should not reappear annually.
        //
        // Fourth era only, so this is the era year as the game reports it
        // (GameYear is 201 in vanilla), not an offset.
        static constexpr int kEveryYear = -1;
        int                  year = kEveryYear;

        [[nodiscard]] bool RecursEveryYear() const { return year == kEveryYear; }

        // Whether this event falls on the given date.
        [[nodiscard]] bool FallsOn(const GameDate::Date& date) const {
            return month == date.month && day == date.day &&
                   (RecursEveryYear() || year == date.year);
        }

        // Art for this day, a bare stem under
        // Data/Interface/Calendar/Events/. Optional: without it the event's
        // own name is tried, then a generic icon for its kind.
        std::string icon;

        // Reserved for the engine: the id of an effect to apply on this day.
        // Unused by the viewer -- parsed and carried so authored data does not
        // have to be rewritten once effects land.
        std::string effect;
    };

    // Seasons, for tinting the month view. Skyrim's own weather does not follow
    // a season system; this is the calendar's own notion.
    enum class Season { kWinter, kSpring, kSummer, kAutumn };

    [[nodiscard]] Season SeasonOf(int month);
    [[nodiscard]] std::string SeasonName(Season season);

    // "holiday" / "festival" / "history" / "note" -- also the stem of the
    // generic icon used when an event has no art of its own.
    [[nodiscard]] const char* KindName(Kind kind);

    // Loads the event list from
    // Data/SKSE/Plugins/CalendarUI/Events. Safe to call more than once;
    // a missing or malformed file leaves the list empty and logs why.
    void Load();

    // Every event in a month, in day order. `year` filters the ones pinned to
    // a single year; recurring events are always included.
    [[nodiscard]] std::vector<const Event*> InMonth(int year, int month);

    // The next event on or after `from`, searching forward up to a year.
    // Returns nullptr when no events are loaded. `outDaysAway` receives how
    // many days ahead it falls (0 = today).
    [[nodiscard]] const Event* Next(const GameDate::Date& from, int* outDaysAway);

}
