// CalendarUI - the Tamriel calendar as a real Scaleform menu.
//
// The menu lives on the game's own menu stack, so it inherits the game's input
// handling, pause behaviour and whatever UI replacer the player has installed.
// See README.md.

#include <ShlObj_core.h>

#include "CalendarMenu.h"
#include "Events.h"
#include "GameDate.h"
#include "InputHandler.h"
#include "Localization.h"
#include "Moons.h"
#include "Notes.h"
#include "Settings.h"

namespace {
    void InitializeLog() {
        wchar_t* documentsPath = nullptr;
        if (FAILED(SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &documentsPath))) {
            return;
        }
        auto path = std::filesystem::path(documentsPath);
        CoTaskMemFree(documentsPath);

        path /= "My Games/Skyrim Special Edition/SKSE/CalendarUI.log";
        std::error_code ec;
        std::filesystem::create_directories(path.parent_path(), ec);

        // Read the level before the logger exists, so nothing is written at a
        // level the player asked not to see -- including this function's own
        // startup lines.
        const auto configured = Settings::ReadLogLevel();

        spdlog::level::level_enum level = spdlog::level::warn;
        switch (configured) {
            case Settings::LogLevel::kOff:   level = spdlog::level::off;   break;
            case Settings::LogLevel::kError: level = spdlog::level::err;   break;
            case Settings::LogLevel::kWarn:  level = spdlog::level::warn;  break;
            case Settings::LogLevel::kInfo:  level = spdlog::level::info;  break;
            case Settings::LogLevel::kDebug: level = spdlog::level::debug; break;
        }

        auto sink = std::make_shared<spdlog::sinks::basic_file_sink_mt>(path.string(), true);
        auto log = std::make_shared<spdlog::logger>("global log", std::move(sink));
        log->set_level(level);

        // Flush at the level being recorded, not unconditionally at info: with
        // LogLevel=off there is nothing to flush, and flushing every warn is
        // what makes the log useful after a crash.
        log->flush_on(level);
        spdlog::set_default_logger(std::move(log));
        spdlog::set_pattern("[%H:%M:%S.%e] [%l] %v");
    }

    void OnMessage(SKSE::MessagingInterface::Message* message) {
        if (!message) {
            return;
        }
        switch (message->type) {
            case SKSE::MessagingInterface::kInputLoaded:
                InputHandler::Register();
                break;

            case SKSE::MessagingInterface::kDataLoaded:
                // The UI registry exists by now, and the event data is plain
                // JSON that does not depend on a save.
                CalendarMenu::Register();

                // Order matters here.
                //
                // Localization first: Events::Load resolves month names, and
                // the season and abbreviation lookups both read the strings it
                // loads. Loading it second would leave the first month view
                // showing English until something forced a reload.
                Localization::Load();

                // Then drop any month/day names cached before the game
                // settings were up. At kDataLoaded every plugin has been
                // applied, so a mod that renames the months has already
                // written its GMSTs and the next read gets its values rather
                // than our built-in fallbacks.
                GameDate::RefreshNames();

                // Same reasoning for the moon phase names, which are read
                // from the translation file Localization::Load just refreshed.
                Moons::RefreshNames();

                Events::Load();

                // Log what the names actually resolved to.
                //
                // This is the first thing to look at when a translation or a
                // month-renaming mod does not appear to work: it shows what
                // the game reported, so "my mod's names are not showing" can
                // be told apart from "the calendar is ignoring them" without
                // guessing.
                {
                    std::string months;
                    for (int i = 0; i < GameDate::kMonthsPerYear; ++i) {
                        months += (i ? ", " : "") + GameDate::MonthName(i);
                    }
                    logger::info("months (from game settings): {}", months);

                    std::string days;
                    for (int i = 0; i < GameDate::kDaysPerWeek; ++i) {
                        days += (i ? ", " : "") + GameDate::DayName(i);
                    }
                    logger::info("days (from game settings): {}", days);
                }

                // Last, and only after everything it might read is loaded.
                //
                // This builds the movie once and throws it away, purely to
                // pull the .swf and its font out of the BSA now rather than
                // when the player first presses the hotkey. See
                // CalendarMenu::Preload.
                CalendarMenu::Preload();
                break;

            case SKSE::MessagingInterface::kPostLoadGame:
            case SKSE::MessagingInterface::kNewGame:
                // Never leave the menu up across a load.
                CalendarMenu::Close();

                // Give the cursor back if an earlier build took it away. The
                // flag lives in the save, so this has to run per load rather
                // than once at startup.
                CalendarMenu::RepairMenuControls();
                break;

            default:
                break;
        }
    }
}

extern "C" DLLEXPORT bool SKSEPlugin_Load(const SKSE::LoadInterface* a_skse) {
    InitializeLog();

    const auto* plugin = SKSE::PluginDeclaration::GetSingleton();
    logger::info("{} v{} loading (Scaleform)", plugin->GetName(), plugin->GetVersion());

    SKSE::Init(a_skse);

    Settings::Load();

    // At load, NOT at kDataLoaded.
    //
    // SKSE dispatches the load callback for a save that was already being
    // loaded when the game started (a save picked from the main menu), so a
    // handler registered later would miss it and the player's notes would
    // silently be absent until the next load.
    Notes::Register();

    if (auto* messaging = SKSE::GetMessagingInterface()) {
        messaging->RegisterListener(OnMessage);
    } else {
        logger::error("no messaging interface; plugin will not function");
        return false;
    }

    return true;
}
