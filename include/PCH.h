#pragma once

// Precompiled headers.

// ===========================================================
// Core Skyrim / SKSE Includes for CommonLibSSE-NG
// ===========================================================

#include <RE/Skyrim.h>
#include <REL/Relocation.h>
#include <SKSE/API.h>
#include <SKSE/SKSE.h>
using namespace std::literals;

// ===========================================================
// Standard Library
// ===========================================================

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <deque>
#include <exception>
#include <filesystem>
#include <format>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// ===========================================================
// spdlog Logging
// ===========================================================

#include <spdlog/spdlog.h>
#include <spdlog/sinks/basic_file_sink.h>

namespace logger = SKSE::log;

// ===========================================================
// Convenience Macros
// ===========================================================

#define DLLEXPORT __declspec(dllexport)
