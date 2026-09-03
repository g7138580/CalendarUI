#pragma once

// The player's own calendar entries.
//
// Where Events are authored data shipped in JSON and never change at runtime,
// a Note is written by the player in game. The two are deliberately separate
// types: notes are per-playthrough, mutable, and saved into the SKSE co-save,
// while events are global, immutable, and reloaded from disk.
//
// They converge only at the movie boundary -- PushMonth merges notes into the
// same per-day "events" array the JSON events use, so the .swf draws both the
// same way and knows nothing about the distinction.

#include <map>

#include "GameDate.h"

namespace Notes {

    struct Note {
        std::string name;
        std::string description;
    };

    // ---- lookup ---------------------------------------------------------

    // The note on a date, or nullptr. The pointer is into the store and is
    // invalidated by any Set/Remove, so it is for immediate use only.
    [[nodiscard]] const Note* Find(int year, int month, int day);

    // Every note in a month, indexed by 1-based day. Days without one are
    // absent from the map.
    [[nodiscard]] std::map<int, Note> InMonth(int year, int month);

    [[nodiscard]] std::size_t Count();

    // ---- mutation -------------------------------------------------------
    //
    // Both are no-ops on an out-of-range date rather than an error: the date
    // arrives from ActionScript, where a Number could be anything, and a
    // corrupt one should not be able to grow the store or throw.

    // Writes (or replaces) the note on a date. An entirely blank note removes
    // instead, so clearing both fields in the editor is the same gesture as
    // deleting -- there is no way to leave an invisible empty note behind.
    void Set(int year, int month, int day, std::string name, std::string description);

    void Remove(int year, int month, int day);

    // ---- persistence ----------------------------------------------------
    //
    // Registered with SKSE's serialization interface at startup. Notes live in
    // the co-save, so they belong to one playthrough: a note written on one
    // character does not appear on another.

    inline constexpr std::uint32_t kSerializationID = 'CALU';
    inline constexpr std::uint32_t kRecordNotes = 'NOTE';
    inline constexpr std::uint32_t kVersion = 1;

    void Register();

    // Called by the SKSE callbacks. Exposed for them only.
    void OnSave(SKSE::SerializationInterface* intfc);
    void OnLoad(SKSE::SerializationInterface* intfc);

    // Empties the store.
    //
    // Registered as the revert callback, which SKSE calls before loading a
    // save AND on returning to the main menu. Without it, notes from the
    // previous character would survive into the next one loaded in the same
    // session -- the store is global, so nothing else would ever clear it.
    void Revert();
}
