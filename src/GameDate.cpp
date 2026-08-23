// The calendar model. See GameDate.h for why this layer stays free of UI code
// and touches RE:: only where it must.

#include "GameDate.h"

#include "Localization.h"

namespace {
    // Cached names, filled on first use and dropped by RefreshNames().
    //
    // Cached because a single month view asks for a month name once per cell
    // plus once per heading, and each miss is a hash lookup through the game's
    // setting collection. Empty string means "not yet read".
    std::array<std::string, GameDate::kMonthsPerYear> g_monthNames{};
    std::array<std::string, GameDate::kDaysPerWeek>   g_dayNames{};
    std::array<std::string, GameDate::kDaysPerWeek>   g_dayAbbrev{};

    // First `count` CHARACTERS of `text` -- not bytes.
    //
    // The game's strings are UTF-8, so a blind substr(0, 3) would cut a
    // multi-byte character in half and render the tail as garbage. Russian
    // "Воскресенье" is two bytes per letter and Japanese three, so a byte cut
    // would take 1.5 and 1 letter respectively rather than 3.
    //
    // Continuation bytes are 10xxxxxx; every other byte starts a character.
    // Counting only the starts gives character positions without needing a
    // full decode.
    std::string Truncate(const std::string& text, int count) {
        int         chars = 0;
        std::size_t pos = 0;

        while (pos < text.size() && chars < count) {
            ++pos;
            // Skip this character's continuation bytes.
            while (pos < text.size() &&
                   (static_cast<unsigned char>(text[pos]) & 0xC0) == 0x80) {
                ++pos;
            }
            ++chars;
        }

        return text.substr(0, pos);
    }

    // Reads a string game setting. Returns empty when the setting is absent,
    // is not a string, or holds an empty value -- all of which mean "the game
    // cannot answer this", and the caller should use its own fallback.
    std::string ReadGameSetting(const char* name) {
        auto* settings = RE::GameSettingCollection::GetSingleton();
        if (!settings) {
            return {};
        }

        auto* setting = settings->GetSetting(name);
        if (!setting || setting->GetType() != RE::Setting::Type::kString) {
            return {};
        }

        const char* value = setting->GetString();
        return (value && *value) ? std::string(value) : std::string{};
    }
}

namespace GameDate {

    void RefreshNames() {
        for (auto& name : g_monthNames) {
            name.clear();
        }
        for (auto& name : g_dayNames) {
            name.clear();
        }
        for (auto& name : g_dayAbbrev) {
            name.clear();
        }
    }

    std::string MonthName(int month) {
        if (month < 0 || month >= kMonthsPerYear) {
            return "?";
        }

        if (g_monthNames[month].empty()) {
            // The game first -- it is the source of truth, and it is already
            // localized and already carries any renaming mod's values.
            g_monthNames[month] = ReadGameSetting(kMonthSettings[month]);

            if (g_monthNames[month].empty()) {
                g_monthNames[month] = kFallbackMonthNames[month];
            }
        }
        return g_monthNames[month];
    }

    std::string DayName(int weekday) {
        if (weekday < 0 || weekday >= kDaysPerWeek) {
            return "?";
        }

        if (g_dayNames[weekday].empty()) {
            g_dayNames[weekday] = ReadGameSetting(kDaySettings[weekday]);

            if (g_dayNames[weekday].empty()) {
                g_dayNames[weekday] = kFallbackDayNames[weekday];
            }
        }
        return g_dayNames[weekday];
    }

    std::string DayAbbrev(int weekday) {
        if (weekday < 0 || weekday >= kDaysPerWeek) {
            return "?";
        }

        if (g_dayAbbrev[weekday].empty()) {
            // A translation may override the heading outright, for a language
            // where cutting the name short reads badly. Keyed by index rather
            // than by name so a mod renaming the days cannot orphan it.
            //
            // Empty fallback so an absent key is distinguishable from a real
            // one, and we fall through to truncating instead.
            const auto key = std::format("CalendarUI_DayAbbrev{}", weekday);
            g_dayAbbrev[weekday] = Localization::Get(key, "");

            if (g_dayAbbrev[weekday].empty()) {
                // Otherwise shorten the game's own name, so the heading tracks
                // whatever the day is currently called.
                g_dayAbbrev[weekday] = Truncate(DayName(weekday), kDayAbbrevLength);
            }

            // Both paths can still come up empty (no game, no translation).
            if (g_dayAbbrev[weekday].empty()) {
                g_dayAbbrev[weekday] = kFallbackDayAbbrev[weekday];
            }
        }
        return g_dayAbbrev[weekday];
    }

    Date Today() {
        // The vanilla start, used when the Calendar singleton is not up yet
        // (main menu, very early load). Matches Skyrim.esm's GameDay/Month/Year
        // globals: 17 Last Seed, 4E 201.
        Date date{ 201, 7, 17 };

        auto* calendar = RE::Calendar::GetSingleton();
        if (!calendar) {
            return date;
        }

        // GetYear() reads the GameYear global, which vanilla ships as 201 --
        // it is the era year itself, not an offset from one.
        date.year = static_cast<int>(calendar->GetYear());

        // GetMonth() is 0-based (kMorningStar == 0), matching our tables.
        date.month = std::clamp(static_cast<int>(calendar->GetMonth()), 0, kMonthsPerYear - 1);

        date.day = std::clamp(static_cast<int>(calendar->GetDay()), 1, DaysInMonth(date.month));

        return date;
    }

    float CurrentHour() {
        auto* calendar = RE::Calendar::GetSingleton();
        return calendar ? calendar->GetHour() : 8.0f;
    }

    int DayOfYear(const Date& date) {
        int ordinal = date.day - 1;
        for (int month = 0; month < date.month && month < kMonthsPerYear; ++month) {
            ordinal += kDaysInMonth[month];
        }
        return ordinal;
    }

    int DaysBetween(const Date& from, const Date& to) {
        constexpr int kDaysPerYear = 365;  // no leap year in Tamriel
        return (to.year - from.year) * kDaysPerYear + (DayOfYear(to) - DayOfYear(from));
    }

    int WeekdayOf(const Date& date) {
        // Anchor on the game's own weekday for today. GetDayOfWeek() is
        // GameDaysPassed % 7, so it is only meaningful relative to today --
        // there is no date epoch to count from.
        int todayWeekday = 0;
        if (auto* calendar = RE::Calendar::GetSingleton()) {
            todayWeekday = static_cast<int>(calendar->GetDayOfWeek()) % kDaysPerWeek;
        }

        const int delta = DaysBetween(Today(), date);

        // C++ % keeps the sign of the dividend, so a date before today would
        // give a negative index. Bias back into range.
        int weekday = (todayWeekday + delta) % kDaysPerWeek;
        if (weekday < 0) {
            weekday += kDaysPerWeek;
        }
        return weekday;
    }

    Date AddMonths(const Date& date, int delta) {
        int absolute = date.year * kMonthsPerYear + date.month + delta;

        Date result{};
        result.year = absolute / kMonthsPerYear;
        result.month = absolute % kMonthsPerYear;
        if (result.month < 0) {
            result.month += kMonthsPerYear;
            --result.year;
        }

        // Clamp so stepping off a 31-day month onto a 30-day one stays valid.
        result.day = std::min(date.day, DaysInMonth(result.month));
        return result;
    }

}
