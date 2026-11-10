local android = require("android")

-- setup Lua paths, and ffi helper / override
require("setupkoenv")

local lfs = require("libs/libkoreader-lfs")
local ffi = require("ffi")
local dummy = require("ffi/posix_h")
local C = ffi.C

-- check uri of the intent that starts this application
local file = android.getIntent()

if file ~= nil then
    android.LOGI("intent file path " .. file)
end

-- path to primary external storage partition
local path = android.getExternalStoragePath()

-- The "split" test flavor installs next to the stock app: keep its settings, cache and
-- history in a separate folder, so it never touches the stock app's data dir.
if android.prop.flavor == "split" then
    local ko_home = path .. "/koreader-split"
    C.setenv("KO_HOME", ko_home, 1)
    -- Run a pending "Import settings from KOReader" (requested from the menu) now,
    -- before anything reads the settings. It only reads the stock app's folder.
    local ok, err = pcall(function()
        require("import_stock_settings").runPending(path, ko_home)
    end)
    if not ok then
        android.LOGE("ImportFromKOReader: " .. tostring(err))
    end
end

-- Set $FONTDIR to android.dir/fonts so MuPDF can find its fonts.
C.setenv("FONTDIR", android.dir .. "/fonts", 1)

-- create fake command-line arguments
-- luacheck: ignore 121
if android.isDebuggable() then
    arg = {"-d", file}
else
    arg = {file}
end

dofile(android.dir.."/reader.lua")
