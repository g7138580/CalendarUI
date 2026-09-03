cmake_minimum_required(VERSION 3.21)

project(CalendarUI VERSION 0.1.0 LANGUAGES CXX)

# Where the built .dll gets copied. Set SKYRIM_MODS_FOLDER to your MO2 "mods"
# directory and the plugin lands in <mods>/Calendar/SKSE/Plugins.
if(DEFINED ENV{SKYRIM_FOLDER} AND IS_DIRECTORY "$ENV{SKYRIM_FOLDER}/Data")
    set(OUTPUT_FOLDER "$ENV{SKYRIM_FOLDER}/Data")
endif()

if(DEFINED ENV{SKYRIM_MODS_FOLDER} AND IS_DIRECTORY "$ENV{SKYRIM_MODS_FOLDER}")
    # The mod's folder name defaults to the project name, but a modlist may
    # install it under another -- Winds of the North uses the Wabbajack
    # "[NoDelete] CalendarUI". Deploying to a guessed name there would create a
    # folder MO2 does not know about: the build reports success while the game
    # goes on loading the old .dll.
    set(MOD_FOLDER_NAME "${PROJECT_NAME}")
    if(DEFINED ENV{CALENDARUI_MOD_FOLDER})
        set(MOD_FOLDER_NAME "$ENV{CALENDARUI_MOD_FOLDER}")
    endif()
    set(OUTPUT_FOLDER "$ENV{SKYRIM_MODS_FOLDER}/${MOD_FOLDER_NAME}")
endif()

# CommonLibSSE-NG is built from source (alandtse fork) rather than pulled from
# the colorglass vcpkg registry, which pins 3.7.0.
#
# 3.7.0 classifies the runtime with an exact minor-version match (4=VR, 6=AE,
# else SE). Skyrim 1.7 bumped the *minor* version, so 1.7.x read as SE and the
# address-library loader looked for version-1-7-104-0.bin (format 1) instead of
# versionlib-1-7-104-0.bin (format 5). That throws before SKSEPlugin_Load runs,
# so the game died with no log at all.
#
# The alandtse fork uses a floor (minor >= 6 = AE), which covers 1.6 AND 1.7
# from a single binary -- verified on 1.6.1170 and 1.7.104 with the same .dll.
set(BUILD_TESTS OFF CACHE BOOL "Disable CommonLibSSE unit tests" FORCE)
set(ENABLE_SKYRIM_VR OFF CACHE BOOL "CalendarUI does not target VR" FORCE)
add_subdirectory(lib/commonlibsse-ng CommonLibSSE EXCLUDE_FROM_ALL)

# The subdirectory only includes this helper on its prebuilt path; on a source
# build add_commonlibsse_plugin() would otherwise be undefined here.
include("${CMAKE_CURRENT_SOURCE_DIR}/lib/commonlibsse-ng/cmake/CommonLibSSE.cmake")
find_package(nlohmann_json CONFIG REQUIRED)

add_commonlibsse_plugin(${PROJECT_NAME} MINIMUM_SKSE_VERSION 2.0.17 SOURCES
    src/plugin.cpp
    src/Settings.cpp
    src/Localization.cpp
    src/GameDate.cpp
    src/Events.cpp
    src/InputHandler.cpp
    src/CalendarMenu.cpp
    src/Notes.cpp
    src/Moons.cpp
)

target_compile_features(${PROJECT_NAME} PRIVATE cxx_std_23)
target_precompile_headers(${PROJECT_NAME} PRIVATE include/PCH.h)

target_include_directories(${PROJECT_NAME} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")

# Always emit a matching PDB, even on Release, so crash-log offsets stay
# resolvable. The PDB is archived below, not shipped with the mod.
target_compile_options(${PROJECT_NAME} PRIVATE /Zi)
target_link_options(${PROJECT_NAME} PRIVATE /DEBUG /OPT:REF /OPT:ICF)

target_link_libraries(
    ${PROJECT_NAME}
    PRIVATE
        nlohmann_json::nlohmann_json
)

# The pinned fmt uses stdext::checked_array_iterator, deprecated in this STL.
target_compile_definitions(${PROJECT_NAME} PRIVATE _SILENCE_STDEXT_ARR_ITERS_DEPRECATION_WARNING)

# Copy the .dll, the INI, the event data, the translations and the .swf into
# the mods folder.
if(DEFINED OUTPUT_FOLDER)
    set(DLL_FOLDER "${OUTPUT_FOLDER}/SKSE/Plugins")
    message(STATUS "SKSE plugin output folder: ${DLL_FOLDER}")

    # A separate always-out-of-date target, NOT just POST_BUILD on the plugin.
    #
    # POST_BUILD runs only when the .dll is actually relinked, so editing a
    # data file alone -- a translation, an event JSON, the INI -- deployed
    # nothing and the build reported success ("ninja: no work to do"). That is
    # exactly the case a translator hits: they change only the .txt, see no
    # change in game, and have no way to tell that the file never left the
    # source tree.
    add_custom_target(deploy_data ALL
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${DLL_FOLDER}"
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/dist/${PROJECT_NAME}/SKSE/Plugins" "${DLL_FOLDER}"
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/dist/${PROJECT_NAME}/Interface" "${OUTPUT_FOLDER}/Interface"
        COMMENT "Deploying data files (translations, events, INI, movie)"
        VERBATIM
    )
    add_dependencies(deploy_data "${PROJECT_NAME}")

    add_custom_command(
        TARGET "${PROJECT_NAME}"
        POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory "${DLL_FOLDER}"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:${PROJECT_NAME}>" "${DLL_FOLDER}/$<TARGET_FILE_NAME:${PROJECT_NAME}>"
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/dist/${PROJECT_NAME}/SKSE/Plugins" "${DLL_FOLDER}"
        # The movie: Data/Interface/. This is the file a UI replacer would
        # override, which is the whole reason this version exists.
        COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/dist/${PROJECT_NAME}/Interface" "${OUTPUT_FOLDER}/Interface"
        VERBATIM
    )
endif()

# Archive symbols per version so old crash logs stay decodable.
set(PDB_ARCHIVE "${CMAKE_SOURCE_DIR}/pdb-archive/${PROJECT_VERSION}")
add_custom_command(
    TARGET "${PROJECT_NAME}"
    POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${PDB_ARCHIVE}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_PDB_FILE:${PROJECT_NAME}>" "${PDB_ARCHIVE}/$<TARGET_PDB_FILE_NAME:${PROJECT_NAME}>"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:${PROJECT_NAME}>" "${PDB_ARCHIVE}/$<TARGET_FILE_NAME:${PROJECT_NAME}>"
    VERBATIM
)
