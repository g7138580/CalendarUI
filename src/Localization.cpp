// Reads Skyrim's own Interface/Translations format. See Localization.h for
// why the plugin does this itself rather than letting the engine substitute.

#include "Localization.h"

#include <fstream>
#include <unordered_map>

#include <Windows.h>

namespace {
    constexpr auto kTranslationsDir = "Data/Interface/Translations";
    constexpr auto kBaseName = "CalendarUI";

    // The fallback language. Loaded first so a partial translation shows
    // English for anything it has not covered yet, rather than a raw $KEY.
    constexpr auto kBaseLanguage = "ENGLISH";

    std::unordered_map<std::string, std::string> g_strings;
    std::string                                  g_language;

    // The game's own sLanguage setting, upper-cased. This is the same source
    // the engine uses to pick a Translations file, so we load the same one.
    std::string CurrentLanguage() {
        std::string language;

        if (auto* ini = RE::INISettingCollection::GetSingleton()) {
            if (auto* setting = ini->GetSetting("sLanguage:General")) {
                if (setting->GetType() == RE::Setting::Type::kString) {
                    const char* value = setting->GetString();
                    if (value && *value) {
                        language = value;
                    }
                }
            }
        }

        if (language.empty()) {
            language = kBaseLanguage;
        }

        std::ranges::transform(language, language.begin(), [](unsigned char c) {
            return static_cast<char>(std::toupper(c));
        });
        return language;
    }

    std::string NarrowFromWide(const std::wstring& wide) {
        if (wide.empty()) {
            return {};
        }
        const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                                             nullptr, 0, nullptr, nullptr);
        if (size <= 0) {
            return {};
        }
        std::string out(static_cast<std::size_t>(size), '\0');
        WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), out.data(),
                            size, nullptr, nullptr);
        return out;
    }

    void Trim(std::string& text) {
        const auto notSpace = [](unsigned char c) { return !std::isspace(c); };
        text.erase(text.begin(), std::ranges::find_if(text, notSpace));
        text.erase(std::find_if(text.rbegin(), text.rend(), notSpace).base(), text.end());
    }

    // Parses one <Name>_<LANGUAGE>.txt.
    //
    // The format is fixed by the game, not by us: UTF-16LE with a BOM, CRLF
    // line endings, and "$KEY<TAB>Value" per line. Written by hand in a text
    // editor by translators, so this is forgiving about blank lines, comment
    // lines and stray whitespace -- but NOT about the encoding, which is what
    // a translator's editor is most likely to get wrong. A file saved as UTF-8
    // is detected and reported rather than being read as mojibake.
    bool LoadFile(const std::filesystem::path& path, int& outCount) {
        std::ifstream stream(path, std::ios::binary);
        if (!stream) {
            return false;
        }

        std::string raw((std::istreambuf_iterator<char>(stream)),
                        std::istreambuf_iterator<char>());
        if (raw.empty()) {
            logger::warn("{}: file is empty", path.filename().string());
            return false;
        }

        std::wstring wide;

        // UTF-16LE BOM (FF FE) is what the game writes and what every shipped
        // translation uses.
        if (raw.size() >= 2 && static_cast<unsigned char>(raw[0]) == 0xFF &&
            static_cast<unsigned char>(raw[1]) == 0xFE) {
            const std::size_t chars = (raw.size() - 2) / sizeof(wchar_t);
            wide.assign(reinterpret_cast<const wchar_t*>(raw.data() + 2), chars);
        } else {
            // No UTF-16 BOM. Almost always a translator whose editor saved as
            // UTF-8; read it as such so their work still loads, but say so,
            // because the *engine* would not have accepted this file.
            std::size_t offset = 0;
            if (raw.size() >= 3 && static_cast<unsigned char>(raw[0]) == 0xEF &&
                static_cast<unsigned char>(raw[1]) == 0xBB &&
                static_cast<unsigned char>(raw[2]) == 0xBF) {
                offset = 3;
            }
            logger::warn("{}: not UTF-16LE. Reading it as UTF-8, but Skyrim's own translation "
                         "loader requires UTF-16LE -- re-save it as 'Unicode' / UTF-16 LE.",
                         path.filename().string());

            const int size = MultiByteToWideChar(CP_UTF8, 0, raw.data() + offset,
                                                 static_cast<int>(raw.size() - offset), nullptr, 0);
            if (size <= 0) {
                logger::error("{}: could not decode the file as UTF-8 either; skipped",
                              path.filename().string());
                return false;
            }
            wide.resize(static_cast<std::size_t>(size));
            MultiByteToWideChar(CP_UTF8, 0, raw.data() + offset,
                                static_cast<int>(raw.size() - offset), wide.data(), size);
        }

        const std::string text = NarrowFromWide(wide);

        int count = 0;
        std::size_t start = 0;
        while (start <= text.size()) {
            std::size_t end = text.find('\n', start);
            if (end == std::string::npos) {
                end = text.size();
            }

            std::string line = text.substr(start, end - start);
            start = end + 1;

            // CRLF, and any stray whitespace a hand edit left behind.
            Trim(line);
            if (line.empty()) {
                continue;
            }

            // Not part of the game's format, but translators annotate anyway
            // and a stray note should not become a bogus entry.
            if (line[0] == ';' || line.starts_with("//")) {
                continue;
            }

            if (line[0] != '$') {
                logger::warn("{}: line does not start with '$', ignored: {}",
                             path.filename().string(), line);
                continue;
            }

            // Key and value are TAB-separated. Several tabs are common, since
            // translators align the columns by eye.
            const auto tab = line.find('\t');
            if (tab == std::string::npos) {
                logger::warn("{}: no TAB between key and value, ignored: {}",
                             path.filename().string(), line);
                continue;
            }

            std::string key = line.substr(0, tab);
            std::string value = line.substr(tab + 1);
            Trim(key);
            Trim(value);

            if (key.size() <= 1) {
                continue;
            }

            // Stored without the '$' so Get() can be called either way.
            key.erase(0, 1);

            // The player's language is loaded after English, so this
            // deliberately overwrites: a translated line wins over the base.
            g_strings[key] = std::move(value);
            ++count;
        }

        outCount = count;
        return true;
    }
}

namespace Localization {

    void Load() {
        g_strings.clear();
        g_language = CurrentLanguage();

        namespace fs = std::filesystem;
        std::error_code ec;

        if (!fs::exists(kTranslationsDir, ec)) {
            logger::warn("no {} folder; every string falls back to its built-in English",
                         kTranslationsDir);
            return;
        }

        // English first as the base, then the player's language over the top.
        // A translator who has done half the file still gets a complete menu.
        const auto load = [&](const std::string& language) -> int {
            const auto path = fs::path(kTranslationsDir) /
                              (std::string(kBaseName) + "_" + language + ".txt");
            if (!fs::exists(path, ec)) {
                return -1;
            }
            int count = 0;
            if (!LoadFile(path, count)) {
                return -1;
            }
            logger::info("{}: {} string(s)", path.filename().string(), count);
            return count;
        };

        load(kBaseLanguage);

        if (g_language != kBaseLanguage) {
            if (load(g_language) < 0) {
                logger::info("no translation for {}; using {}", g_language, kBaseLanguage);
            }
        }

        logger::info("localization: {} string(s) for language {}", g_strings.size(), g_language);
    }

    std::string Get(std::string_view key, std::string_view fallback) {
        std::string_view lookup = key;
        if (lookup.starts_with('$')) {
            lookup.remove_prefix(1);
        }

        const auto it = g_strings.find(std::string(lookup));
        if (it != g_strings.end() && !it->second.empty()) {
            return it->second;
        }
        return std::string(fallback);
    }

    std::string Resolve(std::string_view text) {
        if (text.empty() || text.front() != '$') {
            return std::string(text);
        }
        // Its own text is the fallback: an unresolved key shows as authored,
        // which is more use to a mod author than a blank.
        return Get(text, text);
    }

}
