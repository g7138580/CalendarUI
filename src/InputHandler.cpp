// Hotkey handling: the configured key toggles the calendar, Escape closes it.

#include "InputHandler.h"

#include "CalendarMenu.h"
#include "Settings.h"

namespace {
    // True when the player is in a state where opening a window is reasonable:
    // in control, and no other menu already owns the screen. Without this the
    // calendar could be opened over a dialogue or a loading screen.
    bool CanOpen() {
        auto* ui = RE::UI::GetSingleton();
        if (!ui || ui->GameIsPaused() || ui->IsMenuOpen(RE::LoadingMenu::MENU_NAME)) {
            return false;
        }

        auto* controls = RE::ControlMap::GetSingleton();
        if (!controls) {
            return false;
        }

        // Deliberately NOT gated on IsMovementControlsEnabled().
        //
        // It was used as a proxy for "the player is in control", but it is a
        // poor one: plenty of ordinary states disable movement, and crucially
        // AllowTextInput does too. Writing a single note left it false and the
        // hotkey silently dead for the rest of the session -- and re-enabling
        // it from here was worse, because that is a plugin writing global
        // control state it does not own (the same mistake that took the mouse
        // cursor out of every menu).
        //
        // What actually needs to be true is checked directly instead.

        // Not while ANY other menu owns the screen.
        //
        // The hotkey is an ordinary letter, so without this it fired from
        // inside every menu that does not consume its keys: typing an "l" in
        // the console opened the calendar mid-command, and the same went for
        // any other menu the player could type in.
        //
        // GameIsPaused above only catches the pause menu. IsMenuOpen would
        // need every menu named one by one. The game's own question is
        // "is the player in menu mode", which is exactly this -- and it covers
        // menus from other mods too, which a hardcoded list never could.
        if (ui->IsMenuOpen(RE::Console::MENU_NAME)) {
            return false;
        }

        auto* controlMap = RE::ControlMap::GetSingleton();
        if (controlMap && controlMap->textEntryCount > 0) {
            // Something, somewhere, is taking typed text -- the console, a
            // rename prompt, another mod's search box. A letter belongs to it.
            return false;
        }

        // Any menu that pauses the game is a menu the player is "in", so a
        // world hotkey has no business firing. numPausesGame counts exactly
        // those, which catches inventory, magic, map, journal, barter,
        // containers and other mods' menus alike -- without naming any of them.
        //
        // The calendar itself pauses, so this is only consulted when it is NOT
        // already open (the caller checks that first) -- otherwise the hotkey
        // could never close it again.
        if (ui->numPausesGame > 0) {
            return false;
        }

        auto* player = RE::PlayerCharacter::GetSingleton();
        return player && player->Is3DLoaded();
    }

    class KeyListener final : public RE::BSTEventSink<RE::InputEvent*> {
    public:
        static KeyListener* GetSingleton() {
            static KeyListener instance;
            return std::addressof(instance);
        }

        RE::BSEventNotifyControl ProcessEvent(RE::InputEvent* const*     a_event,
                                              RE::BSTEventSource<RE::InputEvent*>*) override {
            if (!a_event) {
                return RE::BSEventNotifyControl::kContinue;
            }

            for (auto* event = *a_event; event; event = event->next) {
                const auto* button = event->AsButtonEvent();
                if (!button || !button->IsDown()) {
                    continue;
                }
                if (event->GetDevice() != RE::INPUT_DEVICE::kKeyboard) {
                    continue;
                }

                const auto key = button->GetIDCode();

                if (CalendarMenu::IsOpen()) {
                    // Not while the player is typing a note.
                    //
                    // The hotkey is an ordinary letter (L by default), so
                    // without this it would both type its character into the
                    // field and close the menu out from under the editor in
                    // the same keystroke. A sink cannot consume the event, so
                    // the only fix is to not act on it.
                    if (CalendarMenu::IsTextInputActive()) {
                        continue;
                    }

                    // Only the hotkey. Escape is left to the menu system,
                    // which closes the top menu the way it does for every
                    // vanilla menu.
                    if (key == Settings::hotkey) {
                        CalendarMenu::Close();
                    }
                } else if (key == Settings::hotkey && CanOpen()) {
                    CalendarMenu::Open();
                }
            }

            return RE::BSEventNotifyControl::kContinue;
        }
    };
}

namespace InputHandler {

    void Register() {
        if (auto* manager = RE::BSInputDeviceManager::GetSingleton()) {
            manager->AddEventSink(KeyListener::GetSingleton());
            logger::info("input handler registered (hotkey 0x{:02X})", Settings::hotkey);
        } else {
            logger::error("could not register input handler: no input device manager");
        }
    }

}
