// The lunar cycle. See Moons.h for why this is pure arithmetic on a Date.

#include "Moons.h"

#include "Localization.h"
#include "Settings.h"

namespace {
    // Cached phase names, filled on first use and dropped by RefreshNames().
    std::array<std::string, Moons::kPhaseCount> g_phaseNames{};

    // The day counter the cycle is measured against.
    //
    // RE::Calendar::GetDaysPassed() rather than RE::Sky, deliberately. Sky is
    // only valid in a loaded world, so reading the phase from it would fail in
    // exactly the places a menu can still be opened. The day counter is the
    // same number the engine feeds its own moon update, and it survives being
    // asked early.
    //
    // Returns 0 when the Calendar is not up, which pairs with GameDate::Today's
    // fallback to the vanilla start date: both then describe day zero of a
    // fresh game, so the grid is self-consistent rather than half-anchored.
    int DaysPassed() {
        auto* calendar = RE::Calendar::GetSingleton();
        if (!calendar) {
            return 0;
        }

        // Floor, not round. The counter is fractional -- it carries the time of
        // day -- and the phase must not tick over at noon.
        return static_cast<int>(std::floor(calendar->GetDaysPassed()));
    }

    // Where `date` falls within the cycle, 0 .. cycle-1.
    //
    // Anchored on today and walked by the day difference, exactly as
    // GameDate::WeekdayOf is and for the same reason: the cycle is measured
    // from the save's own origin, so there is no epoch a date could be
    // resolved against on its own.
    //
    // The anchor is passed in rather than read here. It is the same for every
    // cell of a month, and reading it per cell meant a Calendar singleton
    // lookup and three virtual getters (GameDate::Today) roughly 124 times per
    // view for a value that cannot change during one push. Cycle() is the
    // entry point that reads it once; this is the arithmetic underneath.
    int DayInCycle(const Moons::Cycle& cycle, const GameDate::Date& date) {
        const int delta = GameDate::DaysBetween(cycle.today, date);

        // C++ % keeps the sign of the dividend, so a date far enough in the
        // past would index backwards out of the table. Bias into range.
        int dayInCycle = (cycle.daysPassed + delta) % cycle.length;
        if (dayInCycle < 0) {
            dayInCycle += cycle.length;
        }
        return dayInCycle;
    }
}

namespace Moons {

    void RefreshNames() {
        for (auto& name : g_phaseNames) {
            name.clear();
        }
    }

    Cycle Cycle::Current() {
        Cycle cycle{};
        cycle.today = GameDate::Today();
        cycle.daysPassed = DaysPassed();

        // Both are validated at load (see Settings::Load), so they are known
        // positive here -- but this is the one place they are divided by, and
        // an INI reload or a future caller must not be able to make that a
        // divide by zero. Cheap insurance on a value read once per month view.
        cycle.length = std::max(1, Settings::MoonCycleDays());
        cycle.daysPerPhase = std::max(1, Settings::MoonDaysPerPhase());
        return cycle;
    }

    Phase Cycle::PhaseOf(const GameDate::Date& date) const {
        // Clamped for a configured cycle that is not a whole number of phases:
        // an 11-day cycle over 3-day phases leaves a short final phase rather
        // than overrunning the table.
        const int index = std::min(DayInCycle(*this, date) / daysPerPhase, kPhaseCount - 1);
        return static_cast<Phase>(index);
    }

    bool Cycle::IsMarked(const GameDate::Date& date) const {
        // The first day of a phase, not every day of it. A phase lasts
        // daysPerPhase days, so without this every cell would be marked --
        // only the day the moon actually changes is worth an icon.
        //
        // Every phase counts, not just the quarters, so this modulo is the
        // whole test: there is no phase to work out afterwards.
        return DayInCycle(*this, date) % daysPerPhase == 0;
    }

    const std::string& PhaseName(Phase phase) {
        // Returned for an out-of-range phase, which cannot happen from our own
        // enum but keeps the reference valid rather than dangling if it did.
        static const std::string kUnknown = "?";

        const int index = static_cast<int>(phase);
        if (index < 0 || index >= kPhaseCount) {
            return kUnknown;
        }

        if (g_phaseNames[index].empty()) {
            g_phaseNames[index] =
                Localization::Get(kPhaseKeys[index], kFallbackPhaseNames[index]);
        }

        // A view into the cache, which lives until RefreshNames(). The caller
        // hands this straight to GFxValue, which borrows the pointer without
        // copying -- so returning by value meant a std::string built per
        // marked cell and kept alive in the menu's string store for no reason.
        return g_phaseNames[index];
    }

}
