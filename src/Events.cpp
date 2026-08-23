// Loads calendar events from JSON and answers date queries about them.

#include "Events.h"

#include <fstream>

#include <nlohmann/json.hpp>

#include "Localization.h"
#include "Settings.h"

namespace {
    using json = nlohmann::json;

    // A folder, not a file. Every *.json in it is loaded and merged, so a mod
    // adds events by dropping in its own file -- nobody has to edit, or win a
    // file-overwrite fight over, anyone else's. Resolved through MO2's VFS at
    // runtime, exactly like TalentsWindow's Classes folder.
    constexpr auto kEventsDir = "Data/SKSE/Plugins/CalendarUI/Events";

    std::vector<Events::Event> g_events;

    Events::Kind ParseKind(const std::string& text) {
        if (text == "festival") {
            return Events::Kind::kFestival;
        }
        if (text == "history") {
            return Events::Kind::kHistory;
        }
        if (text == "note") {
            return Events::Kind::kNote;
        }
        return Events::Kind::kHoliday;
    }

    // Accepts either a 0-based index ("month": 7) or a name ("month":
    // "Last Seed"). Names are what an author actually wants to write, but the
    // index is what the code uses everywhere else.
    bool ParseMonth(const json& node, int& outMonth) {
        if (node.is_number_integer()) {
            const int value = node.get<int>();
            if (value < 0 || value >= GameDate::kMonthsPerYear) {
                return false;
            }
            outMonth = value;
            return true;
        }
        if (node.is_string()) {
            const auto name = node.get<std::string>();

            // Matched against BOTH the canonical English names and whatever
            // the game currently calls the month.
            //
            // The canonical name has to keep working: it is what every
            // existing event file is authored with, and an author writing
            // "Last Seed" must not have their file silently stop loading
            // because the player installed a month-renaming mod or plays in
            // German. Data files are authored once, in one language, and are
            // not translated -- so canonical English is the stable contract.
            //
            // The game's current name is accepted as well, so an author
            // working inside a renaming mod's world can write the names they
            // actually see.
            for (int month = 0; month < GameDate::kMonthsPerYear; ++month) {
                const char* alt = GameDate::kAltMonthNames[month];

                if (_stricmp(name.c_str(), GameDate::kFallbackMonthNames[month]) == 0 ||
                    _stricmp(name.c_str(), GameDate::MonthName(month).c_str()) == 0 ||
                    (*alt && _stricmp(name.c_str(), alt) == 0)) {
                    outMonth = month;
                    return true;
                }
            }
        }
        return false;
    }

    // Parses one file's worth of events into g_events. `source` is the file
    // name, kept for logging and for the "which mod added this" question.
    void LoadFile(const std::filesystem::path& path, int& fileCount, int& added) {
        std::ifstream stream(path);
        if (!stream) {
            logger::warn("could not open {}", path.string());
            return;
        }

        const auto source = path.filename().string();

        json root;
        try {
            stream >> root;
        } catch (const std::exception& e) {
            // One bad file must not cost every other mod's events, so this
            // returns rather than aborting the whole load.
            logger::error("{}: invalid JSON ({}); file skipped", source, e.what());
            return;
        }

        // Accept either a bare array or { "events": [ ... ] }.
        const json* list = nullptr;
        if (root.is_array()) {
            list = &root;
        } else if (root.contains("events") && root["events"].is_array()) {
            list = &root["events"];
        } else {
            logger::error("{}: expected an array, or an object with an 'events' array", source);
            return;
        }

        ++fileCount;
        int fromThisFile = 0;

        for (const auto& node : *list) {
            if (!node.is_object()) {
                continue;
            }

            Events::Event event;
            event.name = node.value("name", std::string{});
            if (event.name.empty()) {
                logger::warn("{}: an entry has no name; skipped", source);
                continue;
            }

            if (!node.contains("month") || !ParseMonth(node["month"], event.month)) {
                logger::warn("{}: event '{}' has a missing or unknown month; skipped", source,
                             event.name);
                continue;
            }

            event.day = node.value("day", 0);
            if (event.day < 1 || event.day > GameDate::DaysInMonth(event.month)) {
                logger::warn("{}: event '{}' day {} is outside {} (1-{}); skipped", source,
                             event.name, event.day, GameDate::MonthName(event.month),
                             GameDate::DaysInMonth(event.month));
                continue;
            }

            // "year" is optional. Without it the event recurs every year,
            // which is what a holiday wants; with it the event is pinned to
            // that one year, for a historical date that should not come round
            // again. Fourth era only, so this is the era year the game
            // reports (201 in vanilla), not an offset.
            if (node.contains("year")) {
                const auto& yearNode = node["year"];
                if (!yearNode.is_number_integer()) {
                    logger::warn("{}: event '{}' has a non-numeric year; treated as recurring",
                                 source, event.name);
                } else {
                    const int year = yearNode.get<int>();
                    if (year < 1) {
                        logger::warn("{}: event '{}' has year {}, which is not a valid era "
                                     "year; treated as recurring",
                                     source, event.name, year);
                    } else {
                        event.year = year;
                    }
                }
            }

            event.description = node.value("description", std::string{});
            event.kind = ParseKind(node.value("kind", std::string{ "holiday" }));
            event.icon = node.value("icon", std::string{});
            event.effect = node.value("effect", std::string{});
            event.source = source;

            // An event may claim an id. A later file reusing that id replaces
            // the earlier entry instead of adding a second one -- this is how
            // a patch moves, retitles or removes a holiday it did not author,
            // without touching the file that defined it.
            event.id = node.value("id", std::string{});

            if (!event.id.empty()) {
                const auto existing = std::ranges::find_if(
                    g_events, [&](const Events::Event& e) { return e.id == event.id; });
                if (existing != g_events.end()) {
                    // "remove": true deletes the entry outright.
                    if (node.value("remove", false)) {
                        logger::info("{}: removed event '{}' (id '{}') from {}", source,
                                     existing->name, event.id, existing->source);
                        g_events.erase(existing);
                        continue;
                    }
                    logger::info("{}: overrode event '{}' (id '{}') from {}", source, event.name,
                                 event.id, existing->source);
                    *existing = std::move(event);
                    continue;
                }
                if (node.value("remove", false)) {
                    logger::warn("{}: asked to remove unknown id '{}'", source, event.id);
                    continue;
                }
            }

            g_events.push_back(std::move(event));
            ++fromThisFile;
        }

        added += fromThisFile;
        logger::info("{}: {} event(s)", source, fromThisFile);
    }

    void SortEvents() {
        // By date, with recurring events before year-pinned ones on the same
        // day so a holiday is listed ahead of a one-off that shares its date.
        std::ranges::sort(g_events, [](const Events::Event& a, const Events::Event& b) {
            if (a.month != b.month) {
                return a.month < b.month;
            }
            if (a.day != b.day) {
                return a.day < b.day;
            }
            return a.year < b.year;
        });
    }
}

namespace Events {

    Season SeasonOf(int month) {
        // Driven by the INI's [Seasons] start months rather than a fixed
        // three-month split, so a modlist can make winter long and spring
        // short, or shift the whole cycle.
        //
        // Found by walking backwards from `month` until a start month is hit,
        // rather than by comparing ranges. That is what makes the seasons free
        // of any assumption about order or length: whichever season started
        // most recently is the one we are in, and stepping back at most twelve
        // months is guaranteed to find one (or to find none, if the settings
        // are broken, which falls through to the default below).
        const struct {
            int    start;
            Season season;
        } seasons[] = {
            { Settings::winterStart, Season::kWinter },
            { Settings::springStart, Season::kSpring },
            { Settings::summerStart, Season::kSummer },
            { Settings::autumnStart, Season::kAutumn },
        };

        for (int back = 0; back < GameDate::kMonthsPerYear; ++back) {
            int probe = (month - back) % GameDate::kMonthsPerYear;
            if (probe < 0) {
                probe += GameDate::kMonthsPerYear;
            }
            for (const auto& entry : seasons) {
                if (entry.start == probe) {
                    return entry.season;
                }
            }
        }

        // Only reachable if every start month is out of range, which Load()
        // already prevents. Winter matches the vanilla turn of the year.
        return Season::kWinter;
    }

    const char* KindName(Kind kind) {
        switch (kind) {
            case Kind::kFestival: return "festival";
            case Kind::kHistory:  return "history";
            case Kind::kNote:     return "note";
            default:              return "holiday";
        }
    }

    // Shown in the menu, so it goes through the translation file. Unlike the
    // month names there is no GMST for a season -- Skyrim has no season
    // concept at all, this is the calendar's own notion -- so this is one of
    // the strings a translator really does have to provide.
    std::string SeasonName(Season season) {
        switch (season) {
            case Season::kWinter: return Localization::Get("CalendarUI_SeasonWinter", "Winter");
            case Season::kSpring: return Localization::Get("CalendarUI_SeasonSpring", "Spring");
            case Season::kSummer: return Localization::Get("CalendarUI_SeasonSummer", "Summer");
            default:              return Localization::Get("CalendarUI_SeasonAutumn", "Autumn");
        }
    }

    void Load() {
        g_events.clear();

        namespace fs = std::filesystem;
        std::error_code ec;

        if (!fs::exists(kEventsDir, ec)) {
            logger::warn("no events folder at {}; the calendar will show dates only", kEventsDir);
            return;
        }

        // Every *.json in the folder is loaded, so a mod adds events by
        // shipping its own file rather than editing anyone else's.
        //
        // Load order is by file name, deliberately: it is the only ordering a
        // player can see and control without the plugin inventing a manifest
        // format. A patch that must win names itself to sort last -- the
        // "zz_" convention the rest of the modding scene already uses.
        std::vector<fs::path> files;
        for (const auto& entry : fs::directory_iterator(kEventsDir, ec)) {
            if (ec) {
                break;
            }
            if (!entry.is_regular_file()) {
                continue;
            }
            auto ext = entry.path().extension().string();
            std::ranges::transform(ext, ext.begin(), [](unsigned char c) {
                return static_cast<char>(std::tolower(c));
            });
            if (ext == ".json") {
                files.push_back(entry.path());
            }
        }
        std::ranges::sort(files);

        int fileCount = 0;
        int added = 0;
        for (const auto& file : files) {
            LoadFile(file, fileCount, added);
        }

        // Warn about two events sharing a day *and* a name -- almost always
        // two mods shipping the same holiday, which an id would have merged.
        for (std::size_t i = 0; i < g_events.size(); ++i) {
            for (std::size_t j = i + 1; j < g_events.size(); ++j) {
                if (g_events[i].month == g_events[j].month &&
                    g_events[i].day == g_events[j].day &&
                    g_events[i].year == g_events[j].year &&
                    g_events[i].name == g_events[j].name) {
                    logger::warn("'{}' on {} {} is defined by both {} and {}; give it an \"id\" "
                                 "in both files to have one override the other",
                                 g_events[i].name, g_events[i].day,
                                 GameDate::MonthName(g_events[i].month), g_events[i].source,
                                 g_events[j].source);
                }
            }
        }

        SortEvents();
        logger::info("loaded {} calendar event(s) from {} file(s)", g_events.size(), fileCount);
    }

    std::vector<const Event*> InMonth(int year, int month) {
        std::vector<const Event*> out;
        for (const auto& event : g_events) {
            // A recurring event is in every year's copy of the month; one
            // pinned to a year appears only in that year.
            if (event.month == month && (event.RecursEveryYear() || event.year == year)) {
                out.push_back(&event);
            }
        }
        return out;
    }

    const Event* Next(const GameDate::Date& from, int* outDaysAway) {
        const Event* best = nullptr;
        int bestDistance = 0;

        for (const auto& event : g_events) {
            if (!event.RecursEveryYear()) {
                // Pinned to one year, so it happens once and does not roll
                // over. If that date is behind us it is simply never next.
                const GameDate::Date occurrence{ event.year, event.month, event.day };
                const int            distance = GameDate::DaysBetween(from, occurrence);
                if (distance >= 0 && (!best || distance < bestDistance)) {
                    best = &event;
                    bestDistance = distance;
                }
                continue;
            }

            // Try this year first, then next -- an event earlier in the
            // calendar than today has already passed and recurs next year.
            for (int yearOffset = 0; yearOffset <= 1; ++yearOffset) {
                const GameDate::Date occurrence{ from.year + yearOffset, event.month, event.day };
                const int distance = GameDate::DaysBetween(from, occurrence);
                if (distance < 0) {
                    continue;
                }
                if (!best || distance < bestDistance) {
                    best = &event;
                    bestDistance = distance;
                }
                break;
            }
        }

        if (best && outDaysAway) {
            *outDaysAway = bestDistance;
        }
        return best;
    }

}
