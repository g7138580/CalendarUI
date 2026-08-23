#pragma once

// $KEY lookup, the way every other Interface mod does it.
//
// Skyrim's own translation mechanism is a file of "$KEY<TAB>Value" lines under
// Data/Interface/Translations, named <Name>_<LANGUAGE>.txt and encoded
// UTF-16LE. The engine loads the one matching sLanguage and substitutes any
// $KEY it finds in a Scaleform text field.
//
// We cannot rely on that substitution here. Every field this menu writes sets
// noTranslate = true (it has to: the text is HTML built by hand, and the
// engine's pass would mangle the font tags), and strings that never reach a
// text field at all -- log lines, month names used for JSON matching -- are
// never offered to the engine in the first place.
//
// So the plugin reads the same file itself and resolves keys in C++, then
// pushes finished text into the movie. The file format and naming are
// deliberately unchanged, because that is what a translator already knows how
// to work with: dropping in CalendarUI_GERMAN.txt is the whole job, with no
// tools and nothing to recompile.

namespace Localization {

    // Reads Data/Interface/Translations/CalendarUI_<LANGUAGE>.txt.
    //
    // The language comes from the sLanguage INI setting, as the engine does.
    // ENGLISH is loaded first as a base so a partial translation falls back
    // key by key rather than showing raw $KEYs -- an incomplete file is the
    // normal state of a translation, not an error.
    void Load();

    // The value for `key`, which may be given with or without the leading '$'.
    // Returns `fallback` when the key is not translated, so every call site
    // carries a readable English default and a missing file is survivable.
    [[nodiscard]] std::string Get(std::string_view key, std::string_view fallback);

    // Resolves a string that *may* be a key. Text not starting with '$' is
    // returned unchanged. This is what authored data (event names from JSON)
    // goes through, so a mod can ship either literal text or a $KEY.
    [[nodiscard]] std::string Resolve(std::string_view text);

}
