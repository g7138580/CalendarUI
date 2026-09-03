// Reads user settings from INI.

#include "Settings.h"

#include <Windows.h>

#include "GameDate.h"

namespace {
    constexpr auto kIniPath = L"Data/SKSE/Plugins/CalendarUI.ini";

    // Hex in the INI (0x10), so read as a string -- GetPrivateProfileInt is
    // decimal only and would silently read 0x10 as 0.
    std::uint32_t ReadScanCode(const wchar_t* a_key, std::uint32_t a_default) {
        wchar_t buffer[32];
        GetPrivateProfileStringW(L"Controls", a_key, L"", buffer, 32, kIniPath);
        if (buffer[0] == 0) {
            return a_default;
        }
        return static_cast<std::uint32_t>(wcstoul(buffer, nullptr, 0));
    }

    // A month, written either as a name ("First Seed") or a 0-based index.
    //
    // Names are matched against the built-in table rather than the live GMSTs
    // because settings are read at plugin load, before the game's own strings
    // are reliably up. An unreadable or out-of-range value keeps the default
    // and says so -- silently sliding a season by a month would be very hard
    // to notice.
    int ReadMonth(const wchar_t* a_key, const char* a_name, int a_default) {
        wchar_t buffer[64];
        GetPrivateProfileStringW(L"Seasons", a_key, L"", buffer, 64, kIniPath);
        if (buffer[0] == 0) {
            return a_default;
        }

        // Numeric first.
        wchar_t*  end = nullptr;
        const long value = wcstol(buffer, &end, 0);
        if (end != buffer && (end == nullptr || *end == L'\0')) {
            if (value >= 0 && value < GameDate::kMonthsPerYear) {
                return static_cast<int>(value);
            }
            logger::warn("{}: month index {} is out of range (0-11); keeping default", a_name,
                         value);
            return a_default;
        }

        // Otherwise a name. Narrow it for comparison; these are ASCII.
        char narrow[64]{};
        WideCharToMultiByte(CP_UTF8, 0, buffer, -1, narrow, sizeof(narrow) - 1, nullptr, nullptr);

        for (int month = 0; month < GameDate::kMonthsPerYear; ++month) {
            const char* alt = GameDate::kAltMonthNames[month];
            if (_stricmp(narrow, GameDate::kFallbackMonthNames[month]) == 0 ||
                (*alt && _stricmp(narrow, alt) == 0)) {
                return month;
            }
        }

        logger::warn("{}: '{}' is not a month name; keeping default", a_name, narrow);
        return a_default;
    }
}

namespace Settings {

    LogLevel ReadLogLevel() {
        wchar_t buffer[32];
        GetPrivateProfileStringW(L"General", L"LogLevel", L"", buffer, 32, kIniPath);
        if (buffer[0] == 0) {
            return logLevel;  // the default
        }

        char narrow[32]{};
        WideCharToMultiByte(CP_UTF8, 0, buffer, -1, narrow, sizeof(narrow) - 1, nullptr, nullptr);

        if (_stricmp(narrow, "off") == 0 || _stricmp(narrow, "none") == 0) {
            return LogLevel::kOff;
        }
        if (_stricmp(narrow, "error") == 0) {
            return LogLevel::kError;
        }
        if (_stricmp(narrow, "warn") == 0 || _stricmp(narrow, "warning") == 0) {
            return LogLevel::kWarn;
        }
        if (_stricmp(narrow, "info") == 0) {
            return LogLevel::kInfo;
        }
        if (_stricmp(narrow, "debug") == 0 || _stricmp(narrow, "trace") == 0) {
            return LogLevel::kDebug;
        }

        // Cannot warn about this through the log: the log's level is what is
        // being decided. Fall back to the noisier of the two so a typo does
        // not silence a player who was trying to turn logging up.
        return LogLevel::kInfo;
    }

    void Load() {
        // Written as hex in the INI (0x26), so read it as a string and convert
        // rather than using GetPrivateProfileInt, which is decimal only.
        wchar_t keyBuffer[32];
        GetPrivateProfileStringW(L"General", L"Hotkey", L"", keyBuffer, 32, kIniPath);
        if (keyBuffer[0] != L'\0') {
            hotkey = static_cast<std::uint32_t>(wcstoul(keyBuffer, nullptr, 0));
        }

        // Already applied to the logger in InitializeLog, which runs before
        // this. Stored here too so the value is visible to anything that asks
        // and so the line logged below reports what is actually in force.
        logLevel = ReadLogLevel();

        prevMonthKey = ReadScanCode(L"PrevMonthKey", prevMonthKey);
        nextMonthKey = ReadScanCode(L"NextMonthKey", nextMonthKey);
        todayKey = ReadScanCode(L"TodayKey", todayKey);

        noteKey = ReadScanCode(L"NoteKey", noteKey);
        noteSaveKey = ReadScanCode(L"NoteSaveKey", noteSaveKey);
        noteCancelKey = ReadScanCode(L"NoteCancelKey", noteCancelKey);
        noteSwitchKey = ReadScanCode(L"NoteSwitchKey", noteSwitchKey);
        noteDeleteKey = ReadScanCode(L"NoteDeleteKey", noteDeleteKey);
        noteDeleteNeedsCtrl =
            GetPrivateProfileIntW(L"Controls", L"NoteDeleteNeedsCtrl",
                                  noteDeleteNeedsCtrl ? 1 : 0, kIniPath) != 0;

        // Moons.
        showMoonPhases = GetPrivateProfileIntW(L"Moons", L"ShowMoonPhases",
                                               showMoonPhases ? 1 : 0, kIniPath) != 0;

        // Validated rather than trusted: both values divide in PhaseOf, so a
        // zero would be a divide-by-zero on a code path that runs for every
        // cell of every month. A negative cycle would send the modulo the
        // wrong way. Clamping silently would hide the typo, so each is
        // rejected back to its default with a line saying why.
        const int cycle = static_cast<int>(
            GetPrivateProfileIntW(L"Moons", L"CycleDays", moonCycleDays, kIniPath));
        if (cycle > 0) {
            moonCycleDays = cycle;
        } else {
            logger::warn("CycleDays must be at least 1 (got {}); keeping {}", cycle,
                         moonCycleDays);
        }

        const int perPhase = static_cast<int>(
            GetPrivateProfileIntW(L"Moons", L"DaysPerPhase", moonDaysPerPhase, kIniPath));
        if (perPhase > 0) {
            moonDaysPerPhase = perPhase;
        } else {
            logger::warn("DaysPerPhase must be at least 1 (got {}); keeping {}", perPhase,
                         moonDaysPerPhase);
        }

        // A cycle shorter than one full set of phases means the moon never
        // reaches the later ones -- it would jump from waxing straight back to
        // full. Legal, and someone may want it, but it is far more likely to
        // be a mistake than an intention.
        if (moonCycleDays < moonDaysPerPhase * 8) {
            logger::warn("CycleDays={} over DaysPerPhase={} covers only {} of 8 phases; "
                         "the later phases will never be shown",
                         moonCycleDays, moonDaysPerPhase, moonCycleDays / moonDaysPerPhase);
        }

        // Seasons. Each is the month that season begins on.
        winterStart = ReadMonth(L"WinterStart", "WinterStart", winterStart);
        springStart = ReadMonth(L"SpringStart", "SpringStart", springStart);
        summerStart = ReadMonth(L"SummerStart", "SummerStart", summerStart);
        autumnStart = ReadMonth(L"AutumnStart", "AutumnStart", autumnStart);

        // Two seasons starting on the same month makes one of them
        // unreachable. Harmless, but always a mistake, so it is worth naming.
        const int starts[] = { winterStart, springStart, summerStart, autumnStart };
        const char* names[] = { "Winter", "Spring", "Summer", "Autumn" };
        for (int i = 0; i < 4; ++i) {
            for (int j = i + 1; j < 4; ++j) {
                if (starts[i] == starts[j]) {
                    logger::warn("{} and {} both start on {} -- one of them will never be "
                                 "shown", names[i], names[j],
                                 GameDate::kFallbackMonthNames[starts[i]]);
                }
            }
        }

        logger::info("settings: hotkey=0x{:02X} log={}", hotkey,
                     static_cast<int>(logLevel));
        logger::info("settings: prev=0x{:02X} next=0x{:02X} today=0x{:02X}", prevMonthKey,
                     nextMonthKey, todayKey);
        logger::info("settings: note=0x{:02X} save=0x{:02X} cancel=0x{:02X} switch=0x{:02X} "
                     "delete=0x{:02X}{}",
                     noteKey, noteSaveKey, noteCancelKey, noteSwitchKey, noteDeleteKey,
                     noteDeleteNeedsCtrl ? " (+ctrl)" : "");
        logger::info("settings: moons show={} cycle={}d perPhase={}d", showMoonPhases,
                     moonCycleDays, moonDaysPerPhase);
        logger::info("settings: seasons winter={} spring={} summer={} autumn={}",
                     GameDate::kFallbackMonthNames[winterStart],
                     GameDate::kFallbackMonthNames[springStart],
                     GameDate::kFallbackMonthNames[summerStart],
                     GameDate::kFallbackMonthNames[autumnStart]);
    }

}
