/*
 * Copyright 2025 Andres Riofrio
 * SPDX-License-Identifier: MIT
 *
 * Tests for the macOS IOKit device backend.
 *
 * For now, just a smoke test to verify Asahi headers compile correctly in C++
 * on non-macOS platforms.
 */

#include <gtest/gtest.h>

#include "agx_device.h"

TEST(AsahiCppCompat, HeadersCompile)
{
   SUCCEED();
}
