#include "Notes.h"

namespace {

    // Keyed by a packed date rather than a struct, so the map has a total
    // order for free and the key is a single value to serialize.
    //
    // Day and month are small and bounded; the year is the game's era year
    // (201 in vanilla) but a total conversion could use anything, so it gets
    // the remaining bits rather than a tight field.
    [[nodiscard]] constexpr std::uint64_t PackDate(int year, int month, int day) {
        return (static_cast<std::uint64_t>(static_cast<std::uint32_t>(year)) << 32) |
               (static_cast<std::uint64_t>(static_cast<std::uint32_t>(month)) << 8) |
               static_cast<std::uint64_t>(static_cast<std::uint32_t>(day));
    }

    // Rejects a date that could not exist, INCLUDING the day-of-month limit
    // for that specific month -- Sun's Dawn has 28 days, and a note on its
    // 31st could never be seen or deleted from the UI.
    [[nodiscard]] bool ValidDate(int year, int month, int day) {
        if (month < 0 || month >= GameDate::kMonthsPerYear) {
            return false;
        }
        if (day < 1 || day > GameDate::kDaysInMonth[month]) {
            return false;
        }
        // A sanity bound, not a lore one. This exists to stop a garbage value
        // from ActionScript becoming a permanent entry in the co-save.
        return year > 0 && year < 100000;
    }

    std::map<std::uint64_t, Notes::Note>& Store() {
        static std::map<std::uint64_t, Notes::Note> store;
        return store;
    }

    // ---- string IO ------------------------------------------------------
    //
    // SKSE's serialization interface handles fixed-size records only, so a
    // string goes out as a length followed by its bytes.
    //
    // The length is written as std::uint16_t and the value is CLAMPED to what
    // that can hold on the way in (see kMaxLen), so a long description cannot
    // silently truncate to a wrong length and desynchronise every record that
    // follows it in the stream.

    constexpr std::uint16_t kMaxLen = 1024;

    bool WriteString(SKSE::SerializationInterface* intfc, const std::string& value) {
        const auto len = static_cast<std::uint16_t>(std::min<std::size_t>(value.size(), kMaxLen));
        if (!intfc->WriteRecordData(len)) {
            return false;
        }
        return len == 0 || intfc->WriteRecordData(value.data(), len);
    }

    bool ReadString(SKSE::SerializationInterface* intfc, std::string& out) {
        std::uint16_t len = 0;
        if (!intfc->ReadRecordData(len)) {
            return false;
        }
        if (len > kMaxLen) {
            // A corrupt or newer record. Refusing here rather than resizing to
            // it keeps a bad length from allocating wildly.
            logger::error("note string length {} exceeds the {} byte maximum", len, kMaxLen);
            return false;
        }
        out.resize(len);
        return len == 0 || intfc->ReadRecordData(out.data(), len);
    }
}

namespace Notes {

    const Note* Find(int year, int month, int day) {
        const auto& store = Store();
        const auto  it = store.find(PackDate(year, month, day));
        return it == store.end() ? nullptr : std::addressof(it->second);
    }

    std::map<int, Note> InMonth(int year, int month) {
        std::map<int, Note> result;
        if (month < 0 || month >= GameDate::kMonthsPerYear) {
            return result;
        }

        // Walked by day rather than by scanning the whole store: a month has
        // at most 31 lookups, where the store could hold years of notes.
        for (int day = 1; day <= GameDate::kDaysInMonth[month]; ++day) {
            if (const auto* note = Find(year, month, day)) {
                result[day] = *note;
            }
        }
        return result;
    }

    std::size_t Count() { return Store().size(); }

    void Set(int year, int month, int day, std::string name, std::string description) {
        if (!ValidDate(year, month, day)) {
            logger::warn("ignoring a note on an impossible date: {}-{}-{}", year, month, day);
            return;
        }

        if (name.size() > kMaxLen) {
            name.resize(kMaxLen);
        }
        if (description.size() > kMaxLen) {
            description.resize(kMaxLen);
        }

        // Clearing both fields deletes. Otherwise an empty note would occupy a
        // day, render as a blank entry, and there would be no way to get rid
        // of it from the editor.
        if (name.empty() && description.empty()) {
            Remove(year, month, day);
            return;
        }

        Store()[PackDate(year, month, day)] = Note{ std::move(name), std::move(description) };
    }

    void Remove(int year, int month, int day) { Store().erase(PackDate(year, month, day)); }

    // ---- persistence ----------------------------------------------------

    void Revert() {
        const auto count = Store().size();
        Store().clear();
        if (count > 0) {
            logger::info("cleared {} note(s) on revert", count);
        }
    }

    void OnSave(SKSE::SerializationInterface* intfc) {
        if (!intfc->OpenRecord(kRecordNotes, kVersion)) {
            logger::error("could not open the notes record; notes were NOT saved");
            return;
        }

        const auto& store = Store();
        const auto  count = static_cast<std::uint32_t>(store.size());
        if (!intfc->WriteRecordData(count)) {
            logger::error("could not write the note count; notes were NOT saved");
            return;
        }

        for (const auto& [key, note] : store) {
            if (!intfc->WriteRecordData(key) || !WriteString(intfc, note.name) ||
                !WriteString(intfc, note.description)) {
                logger::error("writing notes failed partway; the co-save record is truncated");
                return;
            }
        }

        logger::info("saved {} note(s)", count);
    }

    void OnLoad(SKSE::SerializationInterface* intfc) {
        std::uint32_t type = 0;
        std::uint32_t version = 0;
        std::uint32_t length = 0;

        while (intfc->GetNextRecordInfo(type, version, length)) {
            if (type != kRecordNotes) {
                logger::warn("skipping an unknown co-save record: {:08X}", type);
                continue;
            }

            if (version > kVersion) {
                logger::warn("notes record is version {}, this build understands {} -- skipped",
                             version, kVersion);
                continue;
            }

            std::uint32_t count = 0;
            if (!intfc->ReadRecordData(count)) {
                logger::error("could not read the note count; no notes were loaded");
                return;
            }

            // The store is NOT cleared here. SKSE calls the revert callback
            // before load, which is what empties it -- clearing again would be
            // redundant, and doing it here instead would leave stale notes
            // behind whenever a save carries no notes record at all.
            for (std::uint32_t i = 0; i < count; ++i) {
                std::uint64_t key = 0;
                Note          note;
                if (!intfc->ReadRecordData(key) || !ReadString(intfc, note.name) ||
                    !ReadString(intfc, note.description)) {
                    logger::error("notes record ended early after {} of {}; the rest are lost", i,
                                  count);
                    return;
                }
                Store()[key] = std::move(note);
            }

            logger::info("loaded {} note(s)", count);
        }
    }

    void Register() {
        auto* serialization = SKSE::GetSerializationInterface();
        if (!serialization) {
            logger::error("no serialization interface; notes will NOT persist");
            return;
        }

        serialization->SetUniqueID(kSerializationID);
        serialization->SetSaveCallback([](SKSE::SerializationInterface* intfc) { OnSave(intfc); });
        serialization->SetLoadCallback([](SKSE::SerializationInterface* intfc) { OnLoad(intfc); });
        serialization->SetRevertCallback([](SKSE::SerializationInterface*) { Revert(); });

        logger::info("notes serialization registered");
    }
}
