--[[--
Fork-only (KOReader Split, Android "split" flavor): import the data folder of the
stock KOReader app (<storage>/koreader) into this app's data folder
(<storage>/koreader-split, i.e. $KO_HOME).

The stock folder is only ever read. Every write, rename or delete below goes through
checkWritable(), which raises an error for any path that is not inside the
destination folder, both as a string and after resolving symlinks.

The import runs in two steps (spec 002, FR-1):

1. the menu entry checks the folders, asks for confirmation, writes a request marker
   in the destination folder and exits the app (Android cannot restart KOReader);
2. at the next start, llapp_main.lua calls runPending() before anything reads the
   settings. It renames the request marker to a "running" marker, copies the files,
   rewrites the data folder paths inside the copied settings, clears the cache and
   only then removes the "running" marker. If a "running" marker is found at start,
   the previous import was interrupted (crash, killed app): it is logged and NOT
   retried, so a crashing import can never loop; the user can run it again.

This module is loaded before reader.lua, so it may only use android, ffi and lfs
(ffi/util is optional, for the free space check and fsync).
]]

local android = require("android")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
require("ffi/posix_h")
local C = ffi.C

local ImportStock = {
    STOCK_NAME = "koreader",
    SPLIT_NAME = "koreader-split",
    REQUEST_MARKER = "import-from-koreader.request",
    RUNNING_MARKER = "import-from-koreader.running",
    LOG_FILE = "import-from-koreader.log",
}

-- Top level entries of the stock folder that are not copied.
local SKIP_TOP = {
    ["cache"] = true, -- caches only, rebuilt on demand
    ["crash.log"] = true, -- the stock app's log
    ["ota"] = true, -- OTA update downloads, the split build has no OTA updates
    [ImportStock.REQUEST_MARKER] = true,
    [ImportStock.RUNNING_MARKER] = true,
    [ImportStock.LOG_FILE] = true,
}

local TMP_SUFFIX = ".import-tmp"
local CHUNK_SIZE = 256 * 1024
-- Settings files bigger than this are copied as is, without the path rewrite.
local REWRITE_MAX_SIZE = 16 * 1024 * 1024
-- Free space kept on top of what the copy needs.
local SPACE_MARGIN = 20 * 1024 * 1024
-- Only the first errors are logged one by one, the rest are only counted.
local MAX_LOGGED_ERRORS = 50

--- Returns the stock (source) and split (destination) data folders.
function ImportStock.getPaths(storage)
    return storage .. "/" .. ImportStock.STOCK_NAME, storage .. "/" .. ImportStock.SPLIT_NAME
end

local function realpath(path)
    local buf = ffi.new("char[?]", C.PATH_MAX)
    if C.realpath(path, buf) ~= nil then
        return ffi.string(buf)
    end
end

-- true if path is root or below root
local function isInside(path, root)
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function parentOf(path)
    return path:match("^(.*)/[^/]+$")
end

local function toMB(bytes)
    return math.ceil(bytes / (1024 * 1024))
end

--- Raises an error unless path is strictly inside the destination folder, as a
-- string and with its parent folder resolved, and nowhere near the stock folder.
local function checkWritable(ctx, path)
    if path == ctx.dst or not isInside(path, ctx.dst) or isInside(path, ctx.src) then
        error("refusing to modify " .. path)
    end
    local real_parent = realpath(parentOf(path))
    if not real_parent or not isInside(real_parent, ctx.real_dst) or isInside(real_parent, ctx.real_src) then
        error("refusing to modify " .. path .. " (resolves to " .. tostring(real_parent) .. ")")
    end
end

--- Checks that both folders are what we expect and cannot overlap.
-- Fills ctx.real_src and ctx.real_dst. Returns true, or nil and a message.
local function checkRoots(ctx)
    local storage = ctx.storage
    if type(storage) ~= "string" or storage:sub(1, 1) ~= "/" or storage:find("/$") then
        return nil, "invalid storage path " .. tostring(storage)
    end
    local src, dst = ImportStock.getPaths(storage)
    if ctx.src ~= src or ctx.dst ~= dst or src == dst then
        return nil, "unexpected folders " .. tostring(ctx.src) .. " / " .. tostring(ctx.dst)
    end
    if lfs.attributes(src, "mode") ~= "directory" then
        return nil, "folder not found: " .. src
    end
    -- The destination itself must be a real folder, not a symlink to somewhere else.
    if lfs.symlinkattributes(dst, "mode") ~= "directory" then
        return nil, "not a folder: " .. dst
    end
    local real_src, real_dst = realpath(src), realpath(dst)
    if not real_src or not real_dst then
        return nil, "cannot resolve " .. src .. " or " .. dst
    end
    if isInside(real_src, real_dst) or isInside(real_dst, real_src) then
        return nil, "folders overlap: " .. real_src .. " / " .. real_dst
    end
    local src_attr, dst_attr = lfs.attributes(src), lfs.attributes(dst)
    if src_attr and dst_attr and src_attr.ino and src_attr.ino ~= 0
            and src_attr.dev == dst_attr.dev and src_attr.ino == dst_attr.ino then
        return nil, "same folder: " .. src .. " / " .. dst
    end
    ctx.real_src, ctx.real_dst = real_src, real_dst
    return true
end

--- Lists everything to copy from the stock folder, parents before children.
-- Symlinks and special files are skipped (counted in stats.skipped).
-- Returns the list and stats, or nil and a message if a folder cannot be read.
local function scan(ctx)
    local list = {}
    local stats = { files = 0, dirs = 0, bytes = 0, skipped = 0, skipped_names = {} }
    local function walk(rel_dir)
        local dir_path = rel_dir and (ctx.src .. "/" .. rel_dir) or ctx.src
        local ok, iter, dir_obj = pcall(lfs.dir, dir_path)
        if not ok then
            return nil, "cannot read " .. dir_path .. ": " .. tostring(iter)
        end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." and not (rel_dir == nil and SKIP_TOP[name]) then
                local rel = rel_dir and (rel_dir .. "/" .. name) or name
                local attr = lfs.symlinkattributes(ctx.src .. "/" .. rel)
                local mode = attr and attr.mode
                if mode == "directory" then
                    table.insert(list, { rel = rel, dir = true })
                    stats.dirs = stats.dirs + 1
                    local sub_ok, sub_err = walk(rel)
                    if not sub_ok then
                        return nil, sub_err
                    end
                elseif mode == "file" then
                    table.insert(list, { rel = rel, size = attr.size, mtime = attr.modification })
                    stats.files = stats.files + 1
                    stats.bytes = stats.bytes + attr.size
                else
                    stats.skipped = stats.skipped + 1
                    if #stats.skipped_names < MAX_LOGGED_ERRORS then
                        table.insert(stats.skipped_names, rel .. " (" .. tostring(mode) .. ")")
                    end
                end
            end
        end
        return true
    end
    local ok, err = walk(nil)
    if not ok then
        return nil, err
    end
    return list, stats
end

--- Checks the free space in the destination folder.
-- Returns true (and a message when it could not be checked), or nil and a message.
local function checkFreeSpace(ctx, list)
    local need, largest = 0, 0
    for _, entry in ipairs(list) do
        if not entry.dir then
            -- Overwritten files free their old size; each file is written to a temporary
            -- file first, hence the extra room for the largest one.
            local existing = lfs.attributes(ctx.dst .. "/" .. entry.rel, "size") or 0
            if entry.size > existing then
                need = need + entry.size - existing
            end
            if entry.size > largest then
                largest = entry.size
            end
        end
    end
    need = need + largest + SPACE_MARGIN
    local ok_util, ffiUtil = pcall(require, "ffi/util")
    if not ok_util or not ffiUtil.df then
        return true, "free space not checked (ffi/util unavailable)"
    end
    local total, free_or_err, available = ffiUtil.df(ctx.dst)
    if not total or not available then
        return true, "free space not checked (" .. tostring(free_or_err) .. ")"
    end
    if available < need then
        return nil, string.format("not enough free space: %d MB needed, %d MB available", toMB(need), toMB(available)), need, available
    end
    return true, string.format("free space ok: %d MB needed, %d MB available", toMB(need), toMB(available))
end

--- Only top level *.lua and settings/*.lua (plus their .old backups) are rewritten.
local function isRewriteCandidate(entry)
    local rel = entry.rel
    if entry.size > REWRITE_MAX_SIZE then
        return false
    end
    if not (rel:find("/", 1, true) == nil or rel:match("^settings/[^/]+$")) then
        return false
    end
    return rel:match("%.lua$") ~= nil or rel:match("%.lua%.old$") ~= nil
end

--- The storage roots under which the stock folder may have been recorded.
local function rewriteRoots(storage)
    local roots, seen = {}, {}
    for _, root in ipairs({ storage, "/storage/emulated/0", "/sdcard", "/mnt/sdcard", "/storage/self/primary" }) do
        if not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end
    return roots
end

--- Replaces <root>/koreader by <root>/koreader-split where it is a whole path:
-- not preceded by a path character (so /x/sdcard/koreader is left alone) and
-- followed by "/", or by the end of a quoted string. So koreader-split,
-- koreader-backup or koreaderX never match, and a repeated import changes nothing.
-- Plain string search only, no Lua patterns built from paths.
local function rewritePaths(text, roots)
    local total = 0
    for _, root in ipairs(roots) do
        local old = root .. "/" .. ImportStock.STOCK_NAME
        local new = root .. "/" .. ImportStock.SPLIT_NAME
        local out = {}
        local pos = 1
        while true do
            local s, e = text:find(old, pos, true)
            if not s then break end
            local before = s > 1 and text:sub(s - 1, s - 1) or ""
            local after = text:sub(e + 1, e + 1)
            if not before:match("[%w%-_%.~/]")
                    and (after == "/" or after == '"' or after == "'" or after == "]") then
                table.insert(out, text:sub(pos, s - 1))
                table.insert(out, new)
                total = total + 1
            else
                table.insert(out, text:sub(pos, e))
            end
            pos = e + 1
        end
        table.insert(out, text:sub(pos))
        text = table.concat(out)
    end
    return text, total
end

local function log(ctx, level, msg)
    local line = "ImportFromKOReader: " .. msg
    if level == "error" then
        android.LOGE(line)
    elseif level == "warn" then
        android.LOGW(line)
    else
        android.LOGI(line)
    end
    if ctx.log_fh then
        ctx.log_fh:write(os.date("%Y-%m-%d %H:%M:%S "), level, ": ", msg, "\n")
        ctx.log_fh:flush()
    end
end

local function logError(ctx, msg)
    ctx.errors = ctx.errors + 1
    if ctx.errors <= MAX_LOGGED_ERRORS then
        log(ctx, "error", msg)
    elseif ctx.errors == MAX_LOGGED_ERRORS + 1 then
        log(ctx, "error", "too many errors, only counting them from now on")
    end
end

local function toast(msg)
    pcall(android.notification, msg, true)
end

--- Copies one file through a temporary file, then renames it in place.
-- Returns true and the number of paths rewritten, or nil and a message.
local function copyFile(ctx, entry, rewrite)
    local src_path = ctx.src .. "/" .. entry.rel
    local dst_path = ctx.dst .. "/" .. entry.rel
    local tmp_path = dst_path .. TMP_SUFFIX
    checkWritable(ctx, dst_path)
    checkWritable(ctx, tmp_path)
    if lfs.symlinkattributes(dst_path, "mode") == "directory" then
        return nil, "a folder is in the way: " .. dst_path
    end

    local fin, err = io.open(src_path, "rb")
    if not fin then
        return nil, "cannot open " .. src_path .. ": " .. tostring(err)
    end
    local fout
    fout, err = io.open(tmp_path, "wb")
    if not fout then
        fin:close()
        return nil, "cannot create " .. tmp_path .. ": " .. tostring(err)
    end

    local ok, count, read_bytes = true, 0, 0
    if rewrite then
        local data, rerr = fin:read("*a")
        if not data then
            ok, err = false, "read error: " .. tostring(rerr)
        else
            read_bytes = #data
            data, count = rewritePaths(data, ctx.roots)
            local wok, werr = fout:write(data)
            if not wok then
                ok, err = false, "write error: " .. tostring(werr)
            end
        end
    else
        while true do
            local chunk, rerr = fin:read(CHUNK_SIZE)
            if not chunk then
                if rerr then
                    ok, err = false, "read error: " .. tostring(rerr)
                end
                break
            end
            read_bytes = read_bytes + #chunk
            local wok, werr = fout:write(chunk)
            if not wok then
                ok, err = false, "write error: " .. tostring(werr)
                break
            end
        end
    end
    fin:close()
    if ok and read_bytes ~= entry.size then
        ok, err = false, string.format("size changed while copying (%d, expected %d)", read_bytes, entry.size)
    end
    if ok and rewrite and ctx.ffiUtil then
        -- settings files are small and matter most: make sure they hit the disk
        pcall(ctx.ffiUtil.fsyncOpenedFile, fout)
    end
    local cok, cerr = fout:close()
    if ok and not cok then
        ok, err = false, "close error: " .. tostring(cerr)
    end
    if not ok then
        os.remove(tmp_path)
        return nil, src_path .. ": " .. tostring(err)
    end
    local rok, rerr = os.rename(tmp_path, dst_path)
    if not rok then
        os.remove(tmp_path)
        return nil, "cannot rename to " .. dst_path .. ": " .. tostring(rerr)
    end
    if entry.mtime then
        lfs.touch(dst_path, entry.mtime, entry.mtime)
    end
    return true, count
end

local function isBlocked(blocked, rel)
    local parent = parentOf(rel)
    while parent do
        if blocked[parent] then
            return true
        end
        parent = parentOf(parent)
    end
    return false
end

local function copyAll(ctx, list)
    local blocked = {}
    local copied, rewritten_files, rewrites = 0, 0, 0
    for _, entry in ipairs(list) do
        local dst_path = ctx.dst .. "/" .. entry.rel
        if isBlocked(blocked, entry.rel) then
            if entry.dir then
                blocked[entry.rel] = true
            end
        elseif entry.dir then
            local mode = lfs.symlinkattributes(dst_path, "mode")
            if mode == nil then
                checkWritable(ctx, dst_path)
                local ok, err = lfs.mkdir(dst_path)
                if not ok then
                    blocked[entry.rel] = true
                    logError(ctx, "cannot create folder " .. dst_path .. ": " .. tostring(err))
                end
            elseif mode ~= "directory" then
                -- also covers a symlink in the destination: never write through it
                blocked[entry.rel] = true
                logError(ctx, "skipping " .. entry.rel .. ": destination is a " .. tostring(mode) .. ", not a folder")
            end
        else
            local rewrite = isRewriteCandidate(entry)
            local pok, ok, res = pcall(copyFile, ctx, entry, rewrite)
            if not pok then
                ok, res = nil, tostring(ok)
            end
            if ok then
                copied = copied + 1
                if res > 0 then
                    rewritten_files = rewritten_files + 1
                    rewrites = rewrites + res
                    log(ctx, "info", string.format("rewrote %d path(s) in %s", res, entry.rel))
                end
            else
                logError(ctx, res)
            end
        end
    end
    return copied, rewritten_files, rewrites
end

--- Empties the destination cache folder (the folder itself is kept).
local function clearCache(ctx)
    local cache = ctx.dst .. "/cache"
    if lfs.symlinkattributes(cache, "mode") ~= "directory" then
        return 0
    end
    local removed = 0
    local function empty(dir)
        local names = {}
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                table.insert(names, name)
            end
        end
        for _, name in ipairs(names) do
            local path = dir .. "/" .. name
            checkWritable(ctx, path)
            if lfs.symlinkattributes(path, "mode") == "directory" then
                empty(path)
                lfs.rmdir(path)
            else
                -- removes a symlink itself, never its target
                os.remove(path)
            end
            removed = removed + 1
        end
    end
    empty(cache)
    return removed
end

local function openLog(ctx, mode)
    local path = ctx.dst .. "/" .. ImportStock.LOG_FILE
    if lfs.symlinkattributes(path, "mode") == "link" then
        return
    end
    if not isInside(path, ctx.dst) or isInside(path, ctx.src) then
        return
    end
    ctx.log_fh = io.open(path, mode)
end

local function closeLog(ctx)
    if ctx.log_fh then
        ctx.log_fh:close()
        ctx.log_fh = nil
    end
end

local function doImport(ctx, running)
    local ok, err = checkRoots(ctx)
    if not ok then
        return nil, err
    end
    local list, stats = scan(ctx)
    if not list then
        return nil, stats
    end
    log(ctx, "info", string.format("found %d files (%d MB) in %d folders to copy",
        stats.files, toMB(stats.bytes), stats.dirs))
    if stats.skipped > 0 then
        log(ctx, "warn", string.format("skipping %d symlinks or special files: %s",
            stats.skipped, table.concat(stats.skipped_names, ", ")))
    end
    local space_ok, space_msg = checkFreeSpace(ctx, list)
    if not space_ok then
        return nil, space_msg
    end
    log(ctx, "info", space_msg)

    -- From here on the destination is being changed.
    local copied, rewritten_files, rewrites = copyAll(ctx, list)
    log(ctx, "info", string.format("copied %d of %d files, %d errors", copied, stats.files, ctx.errors))
    log(ctx, "info", string.format("rewrote %d paths in %d settings files", rewrites, rewritten_files))
    local cleared = clearCache(ctx)
    log(ctx, "info", string.format("cleared %d entries from the cache", cleared))
    checkWritable(ctx, running)
    os.remove(running)
    return true
end

--- Called by llapp_main.lua at startup, before anything reads the settings.
-- storage is android.getExternalStoragePath(), ko_home is the value given to $KO_HOME.
function ImportStock.runPending(storage, ko_home)
    local src, dst = ImportStock.getPaths(storage)
    local request = dst .. "/" .. ImportStock.REQUEST_MARKER
    local running = dst .. "/" .. ImportStock.RUNNING_MARKER
    local has_request = lfs.attributes(request, "mode") ~= nil
    local has_running = lfs.attributes(running, "mode") ~= nil
    if not has_request and not has_running then
        return
    end
    local ctx = { storage = storage, src = src, dst = dst, errors = 0, roots = rewriteRoots(storage) }
    if ko_home ~= dst then
        android.LOGE("ImportFromKOReader: KO_HOME " .. tostring(ko_home) .. " is not " .. dst .. ", not importing")
        return
    end
    local roots_ok, roots_err = checkRoots(ctx)
    if not roots_ok then
        android.LOGE("ImportFromKOReader: " .. tostring(roots_err) .. ", not importing")
        -- Drop the markers so this does not repeat at every start, but only when the
        -- destination is a real folder (not a symlink): os.remove() then deletes the
        -- marker inside it, or a symlink itself, never anything else.
        if lfs.symlinkattributes(dst, "mode") == "directory" then
            os.remove(request)
            os.remove(running)
        end
        toast("KOReader Split: import from KOReader failed: " .. tostring(roots_err))
        return
    end

    if has_running then
        openLog(ctx, "a")
        log(ctx, "error", "the previous import was interrupted; it is not retried automatically. "
            .. "Run \"Import settings from KOReader\" again from the menu.")
        checkWritable(ctx, running)
        os.remove(running)
        if has_request then
            checkWritable(ctx, request)
            os.remove(request)
        end
        closeLog(ctx)
        toast("KOReader Split: the previous import from KOReader was interrupted. Please run it again from the menu.")
        return
    end

    openLog(ctx, "w")
    log(ctx, "info", "start: importing " .. src .. " into " .. dst)
    checkWritable(ctx, request)
    checkWritable(ctx, running)
    local rok, rerr = os.rename(request, running)
    if not rok then
        log(ctx, "error", "cannot rename the request marker: " .. tostring(rerr) .. ", not importing")
        os.remove(request)
        closeLog(ctx)
        return
    end
    local ok_util, ffiUtil = pcall(require, "ffi/util")
    if ok_util then
        ctx.ffiUtil = ffiUtil
    end

    local pok, ok, err = pcall(doImport, ctx, running)
    if pok and ok then
        log(ctx, "info", string.format("done, %d errors", ctx.errors))
        toast(ctx.errors == 0 and "KOReader Split: settings imported from KOReader."
            or string.format("KOReader Split: settings imported from KOReader with %d errors, see %s/%s.",
                ctx.errors, dst, ImportStock.LOG_FILE))
    else
        local msg = pok and err or ("unexpected error: " .. tostring(ok))
        log(ctx, "error", "aborted: " .. tostring(msg))
        -- The failure was handled: drop the marker so the next start is a normal one.
        pcall(function()
            checkWritable(ctx, running)
            os.remove(running)
        end)
        toast("KOReader Split: import from KOReader failed: " .. tostring(msg))
    end
    closeLog(ctx)
end

--- Menu side checks: returns a summary table, or nil and a message.
function ImportStock.check(storage)
    local src, dst = ImportStock.getPaths(storage)
    local ctx = { storage = storage, src = src, dst = dst, errors = 0 }
    local ok, err = checkRoots(ctx)
    if not ok then
        return nil, err
    end
    local list, stats = scan(ctx)
    if not list then
        return nil, stats
    end
    local space_ok, space_msg = checkFreeSpace(ctx, list)
    if not space_ok then
        return nil, space_msg
    end
    return { src = src, dst = dst, files = stats.files, bytes = stats.bytes }
end

--- Writes the request marker. Returns true, or nil and a message.
function ImportStock.writeRequest(storage)
    local src, dst = ImportStock.getPaths(storage)
    local ctx = { storage = storage, src = src, dst = dst, errors = 0 }
    local ok, err = checkRoots(ctx)
    if not ok then
        return nil, err
    end
    local request = dst .. "/" .. ImportStock.REQUEST_MARKER
    checkWritable(ctx, request)
    local fh
    fh, err = io.open(request, "w")
    if not fh then
        return nil, tostring(err)
    end
    fh:write("import ", src, " into ", dst, " at next start\n")
    local cok, cerr = fh:close()
    if not cok then
        return nil, tostring(cerr)
    end
    return true
end

--- The menu entry, or nil when it does not apply (not the split flavor, no stock folder,
-- or not running from the split data folder).
function ImportStock.genMenuItem()
    if android.prop.flavor ~= "split" then return end
    local storage = android.getExternalStoragePath()
    local src, dst = ImportStock.getPaths(storage)
    if lfs.attributes(src, "mode") ~= "directory" then return end
    if require("datastorage"):getDataDir() ~= dst then return end
    local _ = require("gettext")
    return {
        text = _("Import settings from KOReader"),
        keep_menu_open = true,
        callback = function()
            ImportStock.showDialog(storage)
        end,
    }
end

function ImportStock.showDialog(storage)
    local BD = require("ui/bidi")
    local ConfirmBox = require("ui/widget/confirmbox")
    local Event = require("ui/event")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local T = require("ffi/util").template
    local _ = require("gettext")

    local info, err = ImportStock.check(storage)
    if not info then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot import settings from KOReader:\n%1\n\nNothing was changed."), err),
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Import settings from KOReader?\n\nThe settings, history, plugins, patches and dictionaries of KOReader Split will be replaced by those in:\n%1\n\nThat folder is only read, never changed: KOReader keeps working as before.\n\n%2 files (about %3 MB) will be copied. Close KOReader first if it is open.\n\nKOReader Split will now close. Open it again to run the import; this start can take a while, do not close the app."),
            BD.dirpath(info.src), info.files, toMB(info.bytes)),
        ok_text = _("Import and close"),
        ok_callback = function()
            local pok, ok, werr = pcall(ImportStock.writeRequest, storage)
            if not pok then
                ok, werr = nil, tostring(ok)
            end
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = T(_("Cannot import settings from KOReader:\n%1\n\nNothing was changed."), werr),
                })
                return
            end
            UIManager:broadcastEvent(Event:new("Exit"))
        end,
    })
end

return ImportStock
