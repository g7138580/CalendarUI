#pragma once

// User settings, read from an INI next to the plugin.

namespace Settings {

    // Scan code of the key that opens the calendar. Default 0x26 = L.
    inline std::uint32_t hotkey = 0x26;

    // How much is written to CalendarUI.log.
    //
    // Default is "warn": a normal, working setup then writes almost nothing,
    // while anything actually wrong -- a bad event file, a broken translation
    // -- is still reported. "info" is the old always-on behaviour and is what
    // to switch to when diagnosing; "off" silences the log entirely.
    //
    // Errors are never suppressed except by "off", because a silent failure
    // is worse than a line in a log nobody reads.
    enum class LogLevel { kOff, kError, kWarn, kInfo, kDebug };

    inline LogLevel logLevel = LogLevel::kWarn;

    // Seasons: which month each one starts on, 0-based (0 = Morning Star).
    //
    // Skyrim has no season system of its own, so this is the calendar's own
    // notion and there is no "correct" answer to inherit -- which is exactly
    // why it is configurable. The defaults put deep winter over the turn of
    // the year (Evening Star / Morning Star / Sun's Dawn) and step in
    // three-month blocks from there.
    //
    // A season runs from its start month until the next season's start, so
    // they need not be equal lengths: a modlist wanting a long winter and a
    // short spring just moves the boundaries. Order is not assumed either --
    // SeasonOf walks the list rather than dividing by three.
    inline int winterStart = 11;  // Evening Star
    inline int springStart = 2;   // First Seed
    inline int summerStart = 5;   // Midyear
    inline int autumnStart = 8;   // Hearthfire

    // Month navigation, as DX scan codes. These are sent to the movie, which
    // both binds them and draws the matching ButtonArt icon -- so a rebind
    // moves the key and its picture together.
    // Q / R / T -- deliberately NOT E. E is 0x12, which the game already binds
    // in menu contexts, so the calendar never saw the keypress even though
    // every other key on the same code path worked.
    inline std::uint32_t prevMonthKey = 0x10;  // Q
    inline std::uint32_t nextMonthKey = 0x13;  // R
    inline std::uint32_t todayKey = 0x14;      // T

    // The note editor's keys, also DX scan codes.
    //
    // Sent to the movie alongside the month keys, for the same reason: a
    // rebind has to move the binding and the on-screen hint together, and the
    // .swf must not carry a hardcoded key it cannot explain.
    //
    // noteKey opens the editor from the day popup. N by default, deliberately
    // not E -- see the month keys above.
    //
    // noteDeleteKey removes the note being edited, and IS rebindable: it is
    // matched against the raw scan code, so any key works.
    //
    // F4 by default: a function key is never text, so it cannot be confused
    // with typing into the note fields and needs no modifier.
    inline std::uint32_t noteKey = 0x31;         // N
    inline std::uint32_t noteDeleteKey = 0x3E;   // F4

    // Save / cancel / switch-field are reported for the on-screen hint only.
    //
    // They are NOT rebindable in practice. The editor matches them on
    // Scaleform's navEquivalent (ENTER / ESCAPE / TAB) rather than a scan
    // code, because that is the only form that works for a gamepad as well as
    // a keyboard -- and it is what SkyUI's own text field does. Changing these
    // values moves the hint text without moving the binding, so they are left
    // at the real keys.
    inline std::uint32_t noteSaveKey = 0x1C;     // Enter
    inline std::uint32_t noteCancelKey = 0x01;   // Escape
    inline std::uint32_t noteSwitchKey = 0x0F;   // Tab

    // Whether noteDeleteKey needs CTRL held as well.
    //
    // OFF by default now that the default is F4. Turn it on if you rebind
    // delete to a plain letter, where the modifier is the only thing that
    // separates the command from typing the character.
    inline bool noteDeleteNeedsCtrl = false;

    // --- Moons -----------------------------------------------------------
    //
    // Whether the grid marks the moon phases at all. On by default: it is the
    // kind of thing a calendar is FOR, and it costs a corner of a cell.
    inline bool showMoonPhases = true;

    // The lunar cycle, in days, and how long one phase lasts.
    //
    // Vanilla is 24 days over eight phases -- three days each -- and those are
    // the defaults. They are settings rather than constants because the moons
    // are the one part of this calendar a mod is likely to have changed
    // underneath us: Moons and Stars - Sky Overhaul, for instance, runs Masser
    // on 24 days and Secunda on 20. There is no API to ask such a mod what it
    // did, so the next best thing is letting the player tell us.
    //
    // The two are kept separate rather than deriving one from the other so an
    // uneven cycle still works: the last phase is short instead of the count
    // being wrong. See Moons::PhaseOf, which clamps for exactly that case.
    inline int moonCycleDays = 24;
    inline int moonDaysPerPhase = 3;

    [[nodiscard]] inline std::uint32_t PrevMonthKey() { return prevMonthKey; }
    [[nodiscard]] inline std::uint32_t NextMonthKey() { return nextMonthKey; }
    [[nodiscard]] inline std::uint32_t TodayKey() { return todayKey; }

    [[nodiscard]] inline int MoonCycleDays() { return moonCycleDays; }
    [[nodiscard]] inline int MoonDaysPerPhase() { return moonDaysPerPhase; }

    // Reads only LogLevel, so the log can be configured before anything has
    // had a chance to write to it. Load() reads everything else.
    [[nodiscard]] LogLevel ReadLogLevel();

    void Load();

}
