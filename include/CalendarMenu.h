#pragma once

// The calendar as a real Scaleform menu.
//
// A Scaleform menu *is* the game's UI: it lives on the menu stack, takes input
// the way every other menu does, and a UI replacer such as NORDIC UI or SkyUI
// reskins it for free. Nothing about the look is imitated by hand.
//
// The split of responsibilities:
//
//   C++ (this file)   owns the data. Reads the date from RE::Calendar, the
//                     events from JSON, and pushes a plain object into the
//                     movie. It draws nothing.
//   ActionScript 2    owns the look. Receives that object and lays out the
//                     grid. See flash/CalendarMenu.as.
//
// That boundary is deliberate: everything about the appearance is then in the
// .swf, which is the file a UI replacer would override.

#include "GameDate.h"

namespace RE {
    class GFxValue;
    class FxDelegateArgs;
}

class CalendarMenu final : public RE::IMenu {
public:
    // The name this menu is registered under, and the name anything else uses
    // to open it -- Tween Menu Overhaul's "skseName", a Papyrus UI call, or
    // another plugin.
    //
    // Deliberately the same string as MOVIE_NAME. They are separate
    // namespaces: this one is a key in the UI registry, MOVIE_NAME is a file
    // under Data/Interface, and vanilla pairs unrelated names freely
    // (StatsMenu loads stats.swf). Keeping them identical means there is one
    // name to know instead of two, and no "CalendarUI vs CalendarUIMenu"
    // trap for anyone integrating with this menu.
    constexpr static std::string_view MENU_NAME = "CalendarUI";

    // The movie, relative to Data/Interface, without the extension.
    constexpr static std::string_view MOVIE_NAME = "CalendarUI";

    CalendarMenu();

    // The factory the UI registry calls. Registered once at kDataLoaded.
    static RE::IMenu* Creator() { return new CalendarMenu(); }
    static void       Register();

    // Pays the movie's one-time load cost up front.
    //
    // The first open was visibly slow while every later one was instant. The
    // cost is not our 20KB .swf: it is the font. The movie names
    // "$EverywhereMediumFont", imported from gfxfontlib.swf (347KB) inside
    // Skyrim - Interface.bsa (106MB), and the glyphs have to be found,
    // decompressed and rasterized before anything can be drawn. The game
    // caches all of that, which is why only the first open pays.
    //
    // Constructing one menu during load moves that cost into a moment where a
    // pause is expected and unnoticed, instead of onto the player's first
    // keypress. The instance is thrown away immediately; the caches it warmed
    // are what we keep.
    static void Preload();

    // Open and close by pushing/popping a UI message, which is how the game
    // itself opens menus -- not by constructing one directly.
    static void Open();
    static void Close();
    [[nodiscard]] static bool IsOpen();

    // IMenu
    void                   PostCreate() override;
    RE::UI_MESSAGE_RESULTS ProcessMessage(RE::UIMessage& a_message) override;
    void                   AdvanceMovie(float a_interval, std::uint32_t a_currentTime) override;

    // FxDelegateHandler -- registers the callbacks AS2 can invoke on us.
    void Accept(RE::FxDelegateHandler::CallbackProcessor* a_processor) override;

private:
    // Hands the movie everything it needs to draw a month: the month's own
    // details, the day cells, and which day is today.
    void PushMonth(int year, int month);

    // Called from AS2.
    static void OnRequestMonth(const RE::FxDelegateArgs& a_args);
    static void OnClose(const RE::FxDelegateArgs& a_args);
    static void OnPlaySound(const RE::FxDelegateArgs& a_args);

    // The month currently displayed. Held here rather than in the movie so a
    // reopen starts on today again.
    GameDate::Date view{};
};
