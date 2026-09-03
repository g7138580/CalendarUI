#pragma once

// The lunar cycle: which phase Masser and Secunda show on a given date.
//
// Vanilla Skyrim does not simulate its moons. They are flat billboards with
// eight pre-rendered textures each (RE::Moon holds `stateTextures[kTotal]`),
// and the phase is chosen by a modulo on the day counter -- 24 days, eight
// phases, three days apiece. Both moons share one phase; there is no offset
// coded between them, which is why they always match in the sky.
//
// Because it is a pure function of the day counter, the phase is deterministic
// in BOTH directions: any past or future date can be computed without the game
// ever having been there. That is what makes this usable on a calendar grid
// rather than only as a "tonight's moon" readout.
//
// Like GameDate, this layer is plain arithmetic over a Date and touches RE::
// only to anchor on the game's own day counter.

#include "GameDate.h"

namespace Moons {

    // The eight phases, in the order the engine's own enum runs
    // (RE::Moon::Phase). Phase 0 is full, and the cycle wanes from there.
    //
    // Kept in the engine's order rather than a "nicer" one so a value here can
    // be compared against the game's own state directly, should this ever grow
    // a mod-aware path.
    enum class Phase {
        kFull = 0,
        kWaningGibbous,
        kWaningQuarter,
        kWaningCrescent,
        kNew,
        kWaxingCrescent,
        kWaxingQuarter,
        kWaxingGibbous,

        kTotal
    };

    inline constexpr int kPhaseCount = static_cast<int>(Phase::kTotal);

    // The cycle as it stands right now: the anchor, and the configured shape.
    //
    // Taken ONCE per month view and then asked about each day, rather than
    // every query re-reading the game.
    //
    // The anchor is a Calendar singleton lookup plus three virtual getters
    // (GameDate::Today) and a fourth for the day counter. Asking per cell
    // repeated that around 124 times for a month -- four times per day, since
    // marking a cell needs both the phase and its offset -- to recompute a
    // value that cannot change while a single month is being pushed.
    //
    // Holding it in a value also makes the whole month consistent by
    // construction: every cell is measured against the same "today", so a
    // date rollover mid-push cannot leave one row anchored differently from
    // the next.
    struct Cycle {
        GameDate::Date today{};
        int            daysPassed = 0;

        // From Settings, validated positive. See Cycle::Current.
        int length = 24;
        int daysPerPhase = 3;

        // Reads the game and the settings. The only function here that does.
        [[nodiscard]] static Cycle Current();

        // The phase on `date`.
        [[nodiscard]] Phase PhaseOf(const GameDate::Date& date) const;

        // Whether the grid should mark `date`.
        //
        // True on the FIRST day of any phase -- the day the moon actually
        // changes. All eight phases are marked, so a month carries nine to
        // eleven icons, one every three days.
        //
        // Marking the turn is the part that matters, and it is not the same
        // as asking which phase a day falls in: a phase LASTS three days, so
        // testing the phase alone would mark every single cell. Only the day
        // it changes is news.
        [[nodiscard]] bool IsMarked(const GameDate::Date& date) const;
    };

    // Untranslated names, used as the fallback behind $CalendarUI_Moon* keys.
    inline constexpr const char* kFallbackPhaseNames[kPhaseCount] = {
        "Full Moon",      "Waning Gibbous",  "Third Quarter", "Waning Crescent",
        "New Moon",       "Waxing Crescent", "First Quarter", "Waxing Gibbous"
    };

    // The translation key for each phase, so a localized game can name them.
    inline constexpr const char* kPhaseKeys[kPhaseCount] = {
        "CalendarUI_MoonFull",           "CalendarUI_MoonWaningGibbous",
        "CalendarUI_MoonThirdQuarter",   "CalendarUI_MoonWaningCrescent",
        "CalendarUI_MoonNew",            "CalendarUI_MoonWaxingCrescent",
        "CalendarUI_MoonFirstQuarter",   "CalendarUI_MoonWaxingGibbous"
    };

    // The phase's display name, translated when a key is present.
    //
    // Returns a reference to an internal cache entry that lives until
    // RefreshNames(), so .c_str() can be handed straight to a GFxValue --
    // which borrows the pointer rather than copying it -- without a string
    // being built per marked cell.
    //
    // A reference rather than a string_view precisely so .c_str() is available
    // and null-termination is guaranteed by the type, not by an assumption
    // about where the view came from.
    [[nodiscard]] const std::string& PhaseName(Phase phase);

    // Drops cached names so the next call re-reads the translation. Paired
    // with GameDate::RefreshNames.
    void RefreshNames();

}
