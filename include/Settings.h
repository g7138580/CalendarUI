#pragma once

// User settings, read from an INI next to the plugin.

namespace Settings {

    // Scan code of the key that opens the calendar. Default 0x26 = L.
    inline std::uint32_t hotkey = 0x26;

    // Pause the game (freeze time) while the window is open.
    inline bool pauseGame = true;

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

    [[nodiscard]] inline std::uint32_t PrevMonthKey() { return prevMonthKey; }
    [[nodiscard]] inline std::uint32_t NextMonthKey() { return nextMonthKey; }
    [[nodiscard]] inline std::uint32_t TodayKey() { return todayKey; }

    // Reads only LogLevel, so the log can be configured before anything has
    // had a chance to write to it. Load() reads everything else.
    [[nodiscard]] LogLevel ReadLogLevel();

    void Load();

}
