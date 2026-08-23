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
        if (!controls || !controls->IsMovementControlsEnabled()) {
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
