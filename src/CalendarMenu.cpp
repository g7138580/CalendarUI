// The Scaleform menu. See CalendarMenu.h for the C++/ActionScript split.

#include "CalendarMenu.h"

#include <RE/F/FxDelegate.h>
#include <RE/F/FxResponseArgs.h>

#include "Events.h"
#include "Localization.h"
#include "Moons.h"
#include "Notes.h"
#include "Settings.h"

namespace {
    // ButtonArt's gamepad block (frames 266+), SkyUI's numbering. Taken from
    // Character Menu SE, which pairs keyboard 15/28 with gamepad 277/276 for
    // cancel/accept and uses 274/275 as the shoulder pair.
    constexpr int kGamepadPrev = 274;   // LB
    constexpr int kGamepadNext = 275;   // RB
    constexpr int kGamepadToday = 279;  // Y
    constexpr int kGamepadClose = 277;  // B
    constexpr int kKeyboardClose = 1;   // Esc

    // Backing store for strings pushed into the movie.
    //
    // A deque, NOT a vector: GFxValue holds the char* it is given without
    // copying, so every pointer handed to it must stay valid until the data
    // is pushed. A vector reallocating on growth would invalidate every
    // pointer already handed out -- a deque never moves an existing element.
    using StringStore = std::deque<std::string>;

    // Builds a GFxValue array of the day cells for one month.
    //
    // Every cell is a small object rather than a bare number, because the
    // movie needs more than the date to draw it: whether it is today, which
    // weekday column it falls in, and what (if anything) happens on it. Doing
    // that here keeps all the calendar rules in C++ and leaves AS2 purely
    // presentational.
    void BuildDays(RE::GFxMovieView* a_movie, const GameDate::Date& a_view,
                   const GameDate::Date& a_today, RE::GFxValue& a_out,
                   StringStore& a_strings) {
        a_movie->CreateArray(std::addressof(a_out));

        const int daysInMonth = GameDate::DaysInMonth(a_view.month);

        // The weekday is worked out once for the 1st and then stepped.
        // WeekdayOf reads the Calendar singleton and walks a day difference,
        // so calling it per cell repeated that work up to 31 times for an
        // answer that only ever advances by one.
        const int firstWeekday = GameDate::WeekdayOf({ a_view.year, a_view.month, 1 });

        // The month's events, bucketed by day. Events::OnDay scans the whole
        // list and allocates a vector every call, which per cell made drawing
        // a month O(days * events) with 31 allocations to match. One pass
        // fills this instead.
        std::array<std::vector<const Events::Event*>, 32> byDay{};
        for (const auto* event : Events::InMonth(a_view.year, a_view.month)) {
            if (event->day >= 1 && event->day < static_cast<int>(byDay.size())) {
                byDay[static_cast<std::size_t>(event->day)].push_back(event);
            }
        }

        // The lunar cycle, read once for the whole month rather than per cell.
        // See Moons::Cycle -- the anchor is several game reads, and it cannot
        // change while one month is being pushed.
        //
        // Taken even when the moons are switched off: it is four reads, and
        // hoisting the settings test into the loop instead would mean the
        // disabled path still branched per cell.
        const auto moonCycle = Moons::Cycle::Current();

        for (int day = 1; day <= daysInMonth; ++day) {
            RE::GFxValue cell;
            a_movie->CreateObject(std::addressof(cell));

            const int weekday = (firstWeekday + day - 1) % GameDate::kDaysPerWeek;

            cell.SetMember("day", RE::GFxValue{ static_cast<double>(day) });
            cell.SetMember("weekday", RE::GFxValue{ static_cast<double>(weekday) });
            cell.SetMember("isToday",
                           RE::GFxValue{ a_view.year == a_today.year &&
                                         a_view.month == a_today.month && day == a_today.day });

            // The moon, on the days worth marking.
            //
            // Moons::IsMarked picks those: the day a phase BEGINS, for all
            // eight phases -- nine to eleven days a month, one every three.
            // Testing which phase a day falls in would mark every cell, since
            // a phase lasts three days; only the day it changes is news.
            //
            // "moon" is left ABSENT on an unmarked day rather than sent as -1,
            // so the movie tests for the member instead of for a sentinel and
            // an older .swf paired with a newer DLL simply draws nothing.
            if (Settings::showMoonPhases) {
                const GameDate::Date cellDate{ a_view.year, a_view.month, day };
                if (moonCycle.IsMarked(cellDate)) {
                    const auto phase = moonCycle.PhaseOf(cellDate);
                    cell.SetMember("moon",
                                   RE::GFxValue{ static_cast<double>(static_cast<int>(phase)) });

                    // The name travels with it for the detail line, so the
                    // movie never has to map a phase number onto a word --
                    // that mapping is translated, and translation lives here.
                    //
                    // Not copied into a_strings: PhaseName returns a
                    // reference to a cache that outlives this push, so the
                    // pointer GFxValue borrows stays good without a per-cell
                    // string.
                    cell.SetMember("moonName",
                                   RE::GFxValue{ Moons::PhaseName(phase).c_str() });
                }
            }

            // The day's events, so a cell can be marked and given a tooltip
            // without a second round trip.
            //
            // Name and description are resolved through Localization: an event
            // may be authored either as literal text or as a "$MyMod_Event"
            // key, so a mod that wants to be translatable can be, without
            // every mod being forced to.
            //
            // The resolved strings are kept alive in a_strings until the data
            // has been pushed -- GFxValue borrows the pointer rather than
            // copying it, so a temporary here would dangle.
            RE::GFxValue events;
            a_movie->CreateArray(std::addressof(events));
            for (const auto* event : byDay[static_cast<std::size_t>(day)]) {
                RE::GFxValue entry;
                a_movie->CreateObject(std::addressof(entry));

                a_strings.push_back(Localization::Resolve(event->name));
                entry.SetMember("name", RE::GFxValue{ a_strings.back().c_str() });

                a_strings.push_back(Localization::Resolve(event->description));
                entry.SetMember("description", RE::GFxValue{ a_strings.back().c_str() });

                entry.SetMember("kind", RE::GFxValue{ Events::KindName(event->kind) });
                entry.SetMember("isNote", RE::GFxValue{ false });
                events.PushBack(entry);
            }

            // The player's own note for this day, appended to the same array.
            //
            // Merged here rather than sent as a separate member so the movie
            // has ONE list to draw per day: a note is just another entry that
            // happens to be editable. "isNote" is what the editor keys off to
            // know a day already has one -- the kind string is not enough,
            // since an authored JSON event may legitimately use kNote too.
            //
            // Appended last so an authored holiday keeps the cell's first
            // line, which is the one the grid shows when space is tight.
            if (const auto* note = Notes::Find(a_view.year, a_view.month, day)) {
                RE::GFxValue entry;
                a_movie->CreateObject(std::addressof(entry));

                // Stored verbatim, NOT run through Localization::Resolve. The
                // player typed these: text starting with '$' is theirs and
                // must not be looked up as a translation key.
                a_strings.push_back(note->name);
                entry.SetMember("name", RE::GFxValue{ a_strings.back().c_str() });

                a_strings.push_back(note->description);
                entry.SetMember("description", RE::GFxValue{ a_strings.back().c_str() });

                entry.SetMember("kind", RE::GFxValue{ Events::KindName(Events::Kind::kNote) });
                entry.SetMember("isNote", RE::GFxValue{ true });
                events.PushBack(entry);
            }

            cell.SetMember("events", events);

            a_out.PushBack(cell);
        }
    }
}

CalendarMenu::CalendarMenu() {
    auto* scaleform = RE::BSScaleformManager::GetSingleton();
    if (!scaleform) {
        logger::error("no scaleform manager; the menu cannot load");
        return;
    }

    // The cursor flags are copied from JournalMenu, deliberately, rather than
    // reasoned about from the flag names.
    //
    // What this menu used to set was kUsesCursor + kAssignCursorToRenderer +
    // kUpdateUsesCursor. That works when the menu is opened by hotkey with
    // nothing else on the stack, but opening it from Tween Menu Overhaul
    // handed the pointer back to Windows: the cursor left the game entirely
    // rather than merely disappearing.
    //
    // kAssignCursorToRenderer is the wrong flag for a stacked menu. Checking
    // every vanilla menu, only HUDMenu and KinectMenu set it -- both
    // kAlwaysOpen overlays that own the screen, never something pushed on top
    // of another menu. Meanwhile EVERY stacked menu that works from the tween
    // wheel (Inventory, Magic, Container, Barter, Gift, Favorites, Journal)
    // uses kUpdateUsesCursor and sets NEITHER kUsesCursor NOR
    // kAssignCursorToRenderer.
    //
    // JournalMenu is the closest match to this one -- it is the only vanilla
    // menu that also sets kTopmostRenderedMenu -- so its recipe is the one
    // followed here:
    //
    //   kPausesGame | kUsesMenuContext | kFreezeFrameBackground |
    //   kRequiresUpdate | kTopmostRenderedMenu | kUpdateUsesCursor |
    //   kAllowSaving
    //
    // kDisablePauseMenu is kept from before (Esc should close this menu, not
    // open the system menu); kFreezeFrameBackground and kAllowSaving are
    // Journal-specific and deliberately not taken.
    menuFlags.set(RE::UI_MENU_FLAGS::kPausesGame, RE::UI_MENU_FLAGS::kUpdateUsesCursor,
                  RE::UI_MENU_FLAGS::kDisablePauseMenu, RE::UI_MENU_FLAGS::kUsesMenuContext,
                  RE::UI_MENU_FLAGS::kTopmostRenderedMenu,
                  RE::UI_MENU_FLAGS::kRequiresUpdate);
    depthPriority = 3;
    inputContext = Context::kMenuMode;

    // LoadMovie, not LoadMovieEx.
    //
    // The Ex form took a callback that installed a GFxLog state. That
    // callback built the log with make_gptr and passed .get() -- a temporary,
    // destroyed at the end of the expression, leaving the movie holding a
    // dangling pointer. It crashed inside GFxMovieDef::CreateInstance with a
    // null dereference the moment the menu opened. GFxLog is also abstract
    // (LogMessageVarg is pure virtual), so it could not have been
    // instantiated that way in any case.
    //
    // Nothing here needs a custom log state, so the plain form is correct.
    const std::string movie(MOVIE_NAME);
    if (!scaleform->LoadMovie(this, uiMovie, movie.c_str()) || !uiMovie) {
        logger::error("failed to load Interface/{}.swf -- the menu will not open", movie);
        return;
    }

    // Tell the movie a mouse exists. Without this Scaleform tracks no cursor
    // at all, so rollOver/press on the day cells never fire however the
    // cursor is drawn.
    uiMovie->SetMouseCursorCount(1);

    logger::info("loaded Interface/{}.swf", movie);
}

void CalendarMenu::Register() {
    auto* ui = RE::UI::GetSingleton();
    if (!ui) {
        logger::error("no UI singleton; menu not registered");
        return;
    }
    ui->Register(MENU_NAME, Creator);
    logger::info("registered menu '{}'", MENU_NAME);
}

void CalendarMenu::Preload() {
    // Deliberately NOT pushed onto the menu stack -- nothing is shown. This
    // just runs the constructor, which calls LoadMovie, which is what forces
    // the .swf and its imported font out of the BSA and into the game's
    // caches. See the note in CalendarMenu.h.
    //
    // The movie is released as soon as this scope ends. What survives is the
    // font rasterization and the BSA read, both of which are global.
    auto* scaleform = RE::BSScaleformManager::GetSingleton();
    if (!scaleform) {
        // Not an error worth failing over: the menu still works, the first
        // open is just slow again.
        logger::warn("preload skipped: no scaleform manager yet");
        return;
    }

    // LoadMovie needs an IMenu for its delegate, so a short-lived menu
    // instance is the least surprising way to give it one -- and it exercises
    // exactly the same path a real open takes.
    const std::string name(MOVIE_NAME);
    const auto        start = std::chrono::steady_clock::now();

    {
        CalendarMenu warm;
        // The constructor already did the work; `warm` going out of scope
        // here releases the movie it loaded.
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - start)
                             .count();

    logger::info("preloaded Interface/{}.swf in {}ms -- the first open should now be "
                 "as fast as any later one",
                 name, elapsed);
}

void CalendarMenu::Open() {
    if (IsOpen()) {
        return;
    }
    if (auto* queue = RE::UIMessageQueue::GetSingleton()) {
        queue->AddMessage(MENU_NAME, RE::UI_MESSAGE_TYPE::kShow, nullptr);
    }
}

CalendarMenu::~CalendarMenu() {
    // The menu is going away with an edit still open (closed mid-note, or
    // hidden by something else), so the movie's EndEdit will never run and its
    // AllowTextInput(true) would be stranded -- leaving the player unable to
    // move with no menu on screen.
    //
    // This is the ONLY place the plugin touches the count, and only to undo
    // what the movie can no longer undo itself.
    if (textInputHeld) {
        if (auto* controls = RE::ControlMap::GetSingleton()) {
            controls->AllowTextInput(false);
            logger::warn("menu closed mid-edit; released the text-input hold");
        }
    }
    textInputHeld = false;
}

void CalendarMenu::RepairMenuControls() {
    // Deliberately does nothing.
    //
    // This used to call ToggleControls(kMenu, true) at kPostLoadGame to undo
    // global control state an earlier build had disabled. It crashed the game:
    // an access violation inside the control map on an indexed lookup with a
    // garbage (negative) index, every time, at the exact millisecond this
    // function logged.
    //
    // kPostLoadGame is too early -- the game is still rebuilding its own input
    // state, and writing control flags from underneath that walks structures
    // which are not yet consistent.
    //
    // The lesson generalises past the timing: this plugin has now broken the
    // player's game twice by writing global control state it does not own
    // (once taking the mouse cursor out of every menu, once crashing on load).
    // ControlMap::AllowTextInput is the ONLY control-state call this mod makes,
    // it is refcounted for exactly this purpose, and it is enough.
    //
    // Kept as a no-op rather than deleted so the call site stays documented.
}

void CalendarMenu::Close() {
    if (!IsOpen()) {
        return;
    }
    if (auto* queue = RE::UIMessageQueue::GetSingleton()) {
        queue->AddMessage(MENU_NAME, RE::UI_MESSAGE_TYPE::kHide, nullptr);
    }
}

bool CalendarMenu::IsOpen() {
    auto* ui = RE::UI::GetSingleton();
    return ui && ui->IsMenuOpen(MENU_NAME);
}

void CalendarMenu::PostCreate() {
    // Open on the current month.
    view = GameDate::Today();
    PushMonth(view.year, view.month);
}

void CalendarMenu::PushMonth(int year, int month) {
    if (!uiMovie) {
        logger::error("PushMonth called with no movie loaded");
        return;
    }

    const GameDate::Date today = GameDate::Today();
    view = { year, month, 1 };

    RE::GFxValue data;
    uiMovie->CreateObject(std::addressof(data));

    // The names are read from the game (see GameDate::MonthName), so they are
    // std::strings rather than literals. GFxValue borrows the char* it is
    // given without copying, so these must outlive the Invoke at the end of
    // the function -- holding them in named locals is what guarantees that.
    // Building them inline would push a pointer into a temporary that dies at
    // the end of the statement.
    const std::string monthName = GameDate::MonthName(month);
    const std::string todayMonthName = GameDate::MonthName(today.month);
    const std::string todayDayName = GameDate::DayName(GameDate::WeekdayOf(today));
    const std::string seasonName = Events::SeasonName(Events::SeasonOf(month));

    data.SetMember("year", RE::GFxValue{ static_cast<double>(year) });
    data.SetMember("month", RE::GFxValue{ static_cast<double>(month) });
    data.SetMember("monthName", RE::GFxValue{ monthName.c_str() });
    data.SetMember("season", RE::GFxValue{ seasonName.c_str() });
    data.SetMember("daysInMonth",
                   RE::GFxValue{ static_cast<double>(GameDate::DaysInMonth(month)) });

    // Today's full date, for the line under the heading.
    RE::GFxValue todayValue;
    uiMovie->CreateObject(std::addressof(todayValue));
    todayValue.SetMember("year", RE::GFxValue{ static_cast<double>(today.year) });
    todayValue.SetMember("month", RE::GFxValue{ static_cast<double>(today.month) });
    todayValue.SetMember("monthName", RE::GFxValue{ todayMonthName.c_str() });
    todayValue.SetMember("day", RE::GFxValue{ static_cast<double>(today.day) });
    todayValue.SetMember("dayName", RE::GFxValue{ todayDayName.c_str() });
    const float hour = GameDate::CurrentHour();
    todayValue.SetMember("hour", RE::GFxValue{ static_cast<double>(static_cast<int>(hour)) });
    todayValue.SetMember(
        "minute",
        RE::GFxValue{ static_cast<double>(
            static_cast<int>((hour - static_cast<float>(static_cast<int>(hour))) * 60.0f)) });
    data.SetMember("today", todayValue);

    // The weekday column headings, so the names live in one place (C++) rather
    // than being duplicated in the movie. Held in a local array for the same
    // borrowed-pointer reason as the month name above.
    std::array<std::string, GameDate::kDaysPerWeek> dayAbbrev{};
    RE::GFxValue                                    dayNames;
    uiMovie->CreateArray(std::addressof(dayNames));
    for (int i = 0; i < GameDate::kDaysPerWeek; ++i) {
        dayAbbrev[i] = GameDate::DayAbbrev(i);
        dayNames.PushBack(RE::GFxValue{ dayAbbrev[i].c_str() });
    }
    data.SetMember("dayNames", dayNames);

    // Lives until the end of the function, which is after the Invoke below.
    StringStore strings;

    // Every fixed caption the movie draws.
    //
    // Sent as data rather than being written in the .swf, because the .swf is
    // the file a UI replacer overrides: a caption baked into ActionScript
    // would be lost the moment someone reskins the menu, and a translator
    // would have to rebuild the movie with FFDec instead of editing a text
    // file. Keeping them here means one translation file covers the whole
    // mod and a replacer only ever has to deal with the look.
    //
    // "era" is the "4E" prefix. It is a label, not a number: a total
    // conversion set outside the Fourth Era needs to change it, and it should
    // not require a code change to do so.
    {
        struct Label {
            const char* member;
            const char* key;
            const char* fallback;
        };

        // The nav captions match the prompt bar; the relative-day words are
        // the "Next: X (tomorrow)" tail of the sub-line.
        static constexpr Label kLabels[] = {
            { "prevMonth", "CalendarUI_PrevMonth", "Prev Month" },
            { "nextMonth", "CalendarUI_NextMonth", "Next Month" },
            { "today", "CalendarUI_Today", "Today" },
            { "close", "CalendarUI_Close", "Close" },
            { "era", "CalendarUI_Era", "4E" },
            { "next", "CalendarUI_Next", "Next:" },
            { "onToday", "CalendarUI_OnToday", "today" },
            { "tomorrow", "CalendarUI_Tomorrow", "tomorrow" },
            // "{}" is replaced by the number of days. Kept as a pattern rather
            // than glued together in AS2 so a language that puts the count
            // elsewhere in the phrase can still be written naturally.
            { "inDays", "CalendarUI_InDays", "in {} days" },
            // What an event is, shown next to its name. The values sent with
            // each event stay the lowercase slugs ("holiday"), because those
            // are a data contract with the JSON; these are the display forms
            // and are the ones a translator edits.
            { "kindHoliday", "CalendarUI_KindHoliday", "Holiday" },
            { "kindFestival", "CalendarUI_KindFestival", "Festival" },
            { "kindHistory", "CalendarUI_KindHistory", "History" },
            { "kindNote", "CalendarUI_KindNote", "Note" },
        };

        RE::GFxValue labels;
        uiMovie->CreateObject(std::addressof(labels));
        for (const auto& label : kLabels) {
            strings.push_back(Localization::Get(label.key, label.fallback));
            labels.SetMember(label.member, RE::GFxValue{ strings.back().c_str() });
        }
        data.SetMember("labels", labels);
    }

    RE::GFxValue days;
    BuildDays(uiMovie.get(), view, today, days, strings);
    data.SetMember("days", days);

    // Which button hints to draw.
    //
    // Sent with the month rather than through Scaleform's own setPlatform
    // callback: that is pushed by the game only when the input device
    // changes, so a menu opened after a switch would never receive it and
    // would show the wrong hints. Reading it per push costs nothing and is
    // always current.
    bool usingGamepad = false;
    if (auto* input = RE::BSInputDeviceManager::GetSingleton()) {
        usingGamepad = input->IsGamepadEnabled();
    }
    data.SetMember("usingGamepad", RE::GFxValue{ usingGamepad });

    // The prompt bar's key icons.
    //
    // Sent as DX scan codes because that is how ButtonArt is indexed: the
    // movie draws an icon with gotoAndStop(scanCode), so the binding and its
    // picture come from the same number and cannot disagree. Keyboard and
    // gamepad codes are sent together and the movie picks a set.
    //
    // Gamepad values are SkyUI's convention (the >= 266 block of ButtonArt),
    // taken from Character Menu SE: LB 274, RB 275, A 276, B 277, Y 279.
    //
    // FxDelegate::Invoke again, NOT GFxMovieView::Invoke -- SetKeys is
    // registered with GameDelegate.addCallBack like setCalendarData, and a
    // delegate callback is not reachable by movie path. See the note below.
    {
        RE::FxResponseArgs<9> keyArgs;
        keyArgs.Add(RE::GFxValue{ usingGamepad });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(Settings::PrevMonthKey()) });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(Settings::NextMonthKey()) });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(Settings::TodayKey()) });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(kGamepadPrev) });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(kGamepadNext) });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(kGamepadToday) });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(kKeyboardClose) });
        keyArgs.Add(RE::GFxValue{ static_cast<double>(kGamepadClose) });
        RE::FxDelegate::Invoke(uiMovie.get(), "setKeys", keyArgs);
    }

    // The note editor's keys, sent separately rather than appended to setKeys.
    //
    // A second call keeps both argument lists short and positional-safe: adding
    // five more slots to a nine-argument call means every index in the movie
    // shifts, and a mismatched order there fails silently (the movie would bind
    // whatever number landed in that position).
    {
        RE::FxResponseArgs<6> noteArgs;
        noteArgs.Add(RE::GFxValue{ static_cast<double>(Settings::noteKey) });
        noteArgs.Add(RE::GFxValue{ static_cast<double>(Settings::noteSaveKey) });
        noteArgs.Add(RE::GFxValue{ static_cast<double>(Settings::noteCancelKey) });
        noteArgs.Add(RE::GFxValue{ static_cast<double>(Settings::noteSwitchKey) });
        noteArgs.Add(RE::GFxValue{ static_cast<double>(Settings::noteDeleteKey) });
        noteArgs.Add(RE::GFxValue{ Settings::noteDeleteNeedsCtrl });
        RE::FxDelegate::Invoke(uiMovie.get(), "setNoteKeys", noteArgs);
    }

    // The next event, for the footer.
    int         daysAway = 0;
    const auto* next = Events::Next(today, std::addressof(daysAway));
    if (next) {
        RE::GFxValue nextValue;
        uiMovie->CreateObject(std::addressof(nextValue));
        strings.push_back(Localization::Resolve(next->name));
        nextValue.SetMember("name", RE::GFxValue{ strings.back().c_str() });
        nextValue.SetMember("daysAway", RE::GFxValue{ static_cast<double>(daysAway) });
        data.SetMember("next", nextValue);
    }

    // FxDelegate::Invoke, not GFxMovieView::Invoke.
    //
    // The AS2 side registers this with GameDelegate.addCallBack, and a
    // delegate callback is not reachable by movie path -- an earlier attempt
    // guessed at "root1.Menu_mc.setCalendarData", which would simply have
    // found nothing. FxDelegate::Invoke is the counterpart to addCallBack.
    RE::FxResponseArgs<1> args;
    args.Add(data);
    RE::FxDelegate::Invoke(uiMovie.get(), "setCalendarData", args);

    logger::info("pushed {} 4E {} ({} day(s))", GameDate::MonthName(month), year,
                 GameDate::DaysInMonth(month));
}

RE::UI_MESSAGE_RESULTS CalendarMenu::ProcessMessage(RE::UIMessage& a_message) {
    switch (*a_message.type) {
        case RE::UI_MESSAGE_TYPE::kShow:
            // NOT PostCreate() -- the menu system already calls that when the
            // menu is constructed, and doing it here pushed the month twice
            // (visible as a doubled "pushed ..." pair in the log).

            // Nothing is done to the cursor here on purpose.
            //
            // An earlier attempt forced MenuCursor::SetCursorVisibility(true)
            // on show, to paper over the pointer vanishing when the menu was
            // opened from the tween wheel. That was treating the symptom: the
            // real cause was kAssignCursorToRenderer in the flags above. With
            // the flags corrected the menu system manages the cursor by
            // itself, exactly as it does for every vanilla menu, and forcing
            // it from here would only risk fighting that.
            return RE::UI_MESSAGE_RESULTS::kHandled;

        case RE::UI_MESSAGE_TYPE::kHide:
            return RE::UI_MESSAGE_RESULTS::kHandled;

        default:
            return RE::IMenu::ProcessMessage(a_message);
    }
}

void CalendarMenu::AdvanceMovie(float a_interval, std::uint32_t a_currentTime) {
    // A month re-push requested from inside an ActionScript callback happens
    // HERE, on the next frame, rather than during the callback itself.
    //
    // PushMonth invokes setCalendarData, which makes the movie rebuild the
    // whole grid -- destroying and recreating every cell, and tearing down the
    // day popup. Doing that from within a GFx callback re-enters ActionScript
    // while the calling function is still on the stack: EndEdit was mid-way
    // through, having just focused a cell that PushMonth then deleted. That is
    // the crash after saving or clearing a note.
    if (refreshPending) {
        refreshPending = false;
        PushMonth(view.year, view.month);
    }

    RE::IMenu::AdvanceMovie(a_interval, a_currentTime);
}

void CalendarMenu::Accept(RE::FxDelegateHandler::CallbackProcessor* a_processor) {
    // The methods AS2 may call on us. Paging is a round trip rather than the
    // movie doing its own date maths: the calendar rules (month lengths, the
    // weekday anchor) live in C++ and must not be reimplemented in AS2 where
    // they would drift.
    a_processor->Process("RequestMonth", OnRequestMonth);
    a_processor->Process("CloseMenu", OnClose);

    // The movie asks for vanilla menu sounds by name, the way every stock
    // menu does. Playing them is what makes navigation *feel* like the game
    // rather than like an overlay.
    a_processor->Process("PlaySound", OnPlaySound);

    a_processor->Process("SaveNote", OnSaveNote);
    a_processor->Process("DeleteNote", OnDeleteNote);

    a_processor->Process("BeginTextInput", OnBeginTextInput);
    a_processor->Process("EndTextInput", OnEndTextInput);

    // A diagnostic channel for the movie. Not used by the menu itself -- it is
    // here so ActionScript problems can be seen in the log rather than
    // guessed at, since a .swf has nowhere else to report.
    a_processor->Process("Log", OnLog);
}

void CalendarMenu::OnLog(const RE::FxDelegateArgs& a_args) {
    if (a_args.GetArgCount() < 1) {
        return;
    }
    const auto* text = a_args[0].GetString();
    if (text) {
        logger::info("[as2] {}", text);
    }
}

void CalendarMenu::SetTextInput(bool a_allow) {
    // Guarded against repeats. AllowTextInput keeps a count, so an unmatched
    // call leaves the game in text mode for good -- the player closes the
    // calendar and their movement keys are dead.
    if (a_allow == textInputHeld) {
        return;
    }

    auto* controls = RE::ControlMap::GetSingleton();
    if (!controls) {
        logger::error("no control map; text input cannot be {}",
                      a_allow ? "enabled" : "disabled");
        return;
    }

    // AllowTextInput is NOT called here.
    //
    // The movie already calls skse.AllowTextInput itself, the way SkyUI's
    // search box does. Calling it here as well raised the count TWICE for one
    // edit while only ever lowering it once, so it never returned to zero:
    // the game stayed in text mode after the calendar closed and the player
    // could not move.
    //
    // ONE owner. The movie owns the refcount because that is where the field's
    // lifetime is known; this flag only records that an edit is in progress,
    // so InputHandler can skip its own hotkey.

    // ToggleControls(kMenu, ...) is deliberately NOT called here.
    //
    // It looked like the way to stop menu hotkeys firing mid-word, but the
    // flags it writes are GLOBAL GAME STATE, not something scoped to this
    // menu: disabling kMenu took the mouse cursor out in every menu in the
    // game, and it stayed out after the calendar closed. It is not a refcount
    // either, so restoring it by writing true back would clobber whatever
    // another mod had set.
    //
    // SkyUI's search box -- the reference implementation this editor follows
    // -- calls AllowTextInput and nothing else. If a stray menu hotkey does
    // turn out to fire while typing, the fix belongs in that specific hotkey's
    // own handler (as InputHandler already does for ours), not in a global
    // control-state flag.

    textInputHeld = a_allow;

    logger::debug("text input {}", a_allow ? "enabled" : "disabled");
}

void CalendarMenu::OnBeginTextInput(const RE::FxDelegateArgs&) { SetTextInput(true); }

void CalendarMenu::OnEndTextInput(const RE::FxDelegateArgs&) { SetTextInput(false); }

void CalendarMenu::OnSaveNote(const RE::FxDelegateArgs& a_args) {
    if (a_args.GetArgCount() < 5) {
        logger::warn("SaveNote called with {} args, expected 5", a_args.GetArgCount());
        return;
    }

    auto* menu = static_cast<CalendarMenu*>(a_args.GetHandler());
    if (!menu) {
        return;
    }

    const int year = static_cast<int>(a_args[0].GetNumber());
    const int month = static_cast<int>(a_args[1].GetNumber());
    const int day = static_cast<int>(a_args[2].GetNumber());

    // GetString returns nullptr for a non-string arg, and ActionScript sends
    // an empty field as "" rather than omitting it -- so both are normalised
    // to an empty std::string instead of being trusted.
    const auto* rawName = a_args[3].GetString();
    const auto* rawDesc = a_args[4].GetString();

    Notes::Set(year, month, day, rawName ? rawName : "", rawDesc ? rawDesc : "");

    // Deferred to the next frame -- see AdvanceMovie. Re-pushing from inside
    // this callback rebuilds the grid underneath the ActionScript that is
    // still running and crashes the game.
    menu->refreshPending = true;
}

void CalendarMenu::OnDeleteNote(const RE::FxDelegateArgs& a_args) {
    if (a_args.GetArgCount() < 3) {
        return;
    }

    auto* menu = static_cast<CalendarMenu*>(a_args.GetHandler());
    if (!menu) {
        return;
    }

    Notes::Remove(static_cast<int>(a_args[0].GetNumber()),
                  static_cast<int>(a_args[1].GetNumber()),
                  static_cast<int>(a_args[2].GetNumber()));

    menu->refreshPending = true;
}

void CalendarMenu::OnRequestMonth(const RE::FxDelegateArgs& a_args) {
    if (a_args.GetArgCount() < 1) {
        return;
    }

    auto* menu = static_cast<CalendarMenu*>(a_args.GetHandler());
    if (!menu) {
        return;
    }

    // A signed month delta from the movie: -1 for the left arrow, +1 for the
    // right, 0 to snap back to today.
    const int delta = static_cast<int>(a_args[0].GetNumber());

    if (delta == 0) {
        const auto today = GameDate::Today();
        menu->PushMonth(today.year, today.month);
        return;
    }

    const auto stepped = GameDate::AddMonths(menu->view, delta);
    menu->PushMonth(stepped.year, stepped.month);
}

void CalendarMenu::OnClose(const RE::FxDelegateArgs&) { CalendarMenu::Close(); }

void CalendarMenu::OnPlaySound(const RE::FxDelegateArgs& a_args) {
    if (a_args.GetArgCount() < 1) {
        return;
    }
    const auto* name = a_args[0].GetString();
    if (name && *name) {
        RE::PlaySound(name);
    }
}
