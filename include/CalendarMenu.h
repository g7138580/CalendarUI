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

    // Releases the text-input hold if the menu is destroyed mid-edit.
    //
    // Closing the calendar with the note editor open (Esc twice quickly, or
    // any other plugin hiding the menu) would otherwise never run the movie's
    // EndTextInput, and the refcount would be left raised: the player's
    // movement keys stay dead with no menu on screen and nothing to reopen.
    ~CalendarMenu() override;

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

    // The player's own entries, written from the note editor in the movie.
    //
    // Both re-push the month afterwards rather than letting the movie patch
    // its own copy of the data: the grid then redraws from the same path as
    // every other change, so a note appears in its cell by exactly the
    // mechanism a JSON event does and there is no second rendering path to
    // keep in step.
    static void OnSaveNote(const RE::FxDelegateArgs& a_args);
    static void OnDeleteNote(const RE::FxDelegateArgs& a_args);

    // Hands the keyboard to Flash for the note editor, and takes it back.
    //
    // This MUST be done here, in C++, via RE::ControlMap::AllowTextInput.
    // ActionScript's fscommand("AllowTextInput", ...) does nothing in Skyrim:
    // the game never routes that fscommand to the control map, so the movie
    // asks and nothing happens -- the field takes focus, the caret blinks, and
    // not one character arrives because the game is still consuming every key
    // as gameplay input. That is precisely what "typing does nothing" looked
    // like.
    //
    // AllowTextInput is a REFCOUNT, not a flag. Every true must be matched by
    // exactly one false or the game stays in text mode after the menu closes
    // and the player cannot move. textInputHeld tracks whether this menu is
    // currently holding it, so a double-begin or a double-end cannot unbalance
    // the count.
    static void OnBeginTextInput(const RE::FxDelegateArgs& a_args);
    static void OnEndTextInput(const RE::FxDelegateArgs& a_args);

    static void SetTextInput(bool a_allow);

    // Lets the movie write to the plugin's log. See OnLog.
    static void OnLog(const RE::FxDelegateArgs& a_args);

    // Released if the menu is torn down mid-edit -- closing the calendar while
    // the editor is open must not strand the refcount.
    static inline bool textInputHeld = false;

public:
    // Whether the player is currently typing into the note editor.
    //
    // InputHandler reads this to skip its own hotkey: that key is an ordinary
    // letter, so acting on it while a field is focused would type the
    // character AND close the menu in one keystroke.
    [[nodiscard]] static bool IsTextInputActive() { return textInputHeld; }

    // Undoes global menu-control state an earlier build could leave disabled.
    // Called on load; see the definition.
    static void RepairMenuControls();

private:

    // The month currently displayed. Held here rather than in the movie so a
    // reopen starts on today again.
    GameDate::Date view{};

    // Set by a note callback, acted on in AdvanceMovie.
    //
    // A month re-push rebuilds the entire grid in the movie, so it must not
    // run while ActionScript is still on the stack -- doing so tore down the
    // popup and cells underneath the very function that asked for it.
    bool refreshPending = false;
};
