-- mpv discord rich presence integration with imdb & itunes support
-- zero-dependency lua jit ffi win32 named pipe rpc client

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")
local ffi = require("ffi")

-- configuration options
local o = {
    client_id = "1462038267183628308",
    enable_imdb = true,
    imdb_soft_search = true,
    fetch_cover_art = true,
    show_playlist_pos = true,
    show_time_progress = false,
    torrserver_support = true,
    update_interval = 2,
    language = "en",
    show_buttons = true,
    active_when_paused = true,
    activity_type_video = 3,
    activity_type_audio = 2,
    large_image_default = "mpv",
    large_image_audio = "music_note",
    small_image_play = "",
    small_image_pause = "pause",
    use_c_dll_bridge = false,
    dll_path = ""
}

options.read_options(o, "discord_rp")

-- win32 named pipe ffi definitions
ffi.cdef[[
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef int BOOL;

    HANDLE CreateFileA(
        const char* lpFileName,
        DWORD dwDesiredAccess,
        DWORD dwShareMode,
        void* lpSecurityAttributes,
        DWORD dwCreationDisposition,
        DWORD dwFlagsAndAttributes,
        HANDLE hTemplateFile
    );

    BOOL WriteFile(
        HANDLE hFile,
        const void* lpBuffer,
        DWORD nNumberOfBytesToWrite,
        DWORD* lpNumberOfBytesWritten,
        void* lpOverlapped
    );

    BOOL ReadFile(
        HANDLE hFile,
        void* lpBuffer,
        DWORD nNumberOfBytesToRead,
        DWORD* lpNumberOfBytesRead,
        void* lpOverlapped
    );

    BOOL CloseHandle(HANDLE hObject);

    BOOL PeekNamedPipe(
        HANDLE hNamedPipe,
        void* lpBuffer,
        DWORD nBufferSize,
        DWORD* lpBytesRead,
        DWORD* lpTotalBytesAvail,
        DWORD* lpBytesLeftThisMessage
    );

    DWORD GetCurrentProcessId();
]]

local GENERIC_READ = 0x80000000
local GENERIC_WRITE = 0x40000000
local OPEN_EXISTING = 3
local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", ffi.cast("intptr_t", -1))

-- runtime state and cache
local ipc_handle = nil
local is_connected = false
local imdb_cache = {}
local music_cover_cache = {}
local timer = nil
local start_time = os.time()
local cache_file_path = mp.command_native({"expand-path", "~~/script-opts/imdb_cache.json"})

local active_file_path = nil
local active_media_title = nil
local active_imdb_data = nil
local active_music_cover_url = nil

-- disk cache management
local function load_disk_cache()
    local file = io.open(cache_file_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        if content and #content > 0 then
            local data = utils.parse_json(content)
            if type(data) == "table" then
                imdb_cache = data
            end
        end
    end
end

local function save_disk_cache()
    local file = io.open(cache_file_path, "w")
    if file then
        local json_str = utils.format_json(imdb_cache)
        if json_str then
            file:write(json_str)
        end
        file:close()
    end
end

load_disk_cache()

-- discord ipc framing
local function pack_packet(opcode, payload)
    local len = #payload
    local buf = ffi.new("uint8_t[?]", 8 + len)
    local p32 = ffi.cast("uint32_t*", buf)
    p32[0] = opcode
    p32[1] = len
    ffi.copy(buf + 8, payload, len)
    return buf, 8 + len
end

local function send_ipc_packet(opcode, payload)
    if not ipc_handle or ipc_handle == INVALID_HANDLE_VALUE then return false end
    local buf, size = pack_packet(opcode, payload)
    local written = ffi.new("DWORD[1]")
    local res = ffi.C.WriteFile(ipc_handle, buf, size, written, nil)
    if res == 0 or written[0] ~= size then
        is_connected = false
        ffi.C.CloseHandle(ipc_handle)
        ipc_handle = nil
        return false
    end
    return true
end

local function connect_discord_ipc()
    if is_connected and ipc_handle then return true end
    
    for i = 0, 9 do
        local pipe_name = "\\\\.\\pipe\\discord-ipc-" .. i
        local handle = ffi.C.CreateFileA(
            pipe_name,
            bit.bor(GENERIC_READ, GENERIC_WRITE),
            0,
            nil,
            OPEN_EXISTING,
            0,
            nil
        )
        if handle ~= INVALID_HANDLE_VALUE then
            ipc_handle = handle
            is_connected = true
            
            local handshake_payload = string.format('{"v":1,"client_id":"%s"}', o.client_id)
            if send_ipc_packet(0, handshake_payload) then
                mp.msg.info("connected to discord ipc: " .. pipe_name)
                return true
            end
        end
    end
    
    is_connected = false
    ipc_handle = nil
    return false
end

-- time formatter
local function format_time(seconds)
    if not seconds or seconds <= 0 then return "00:00" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    else
        return string.format("%02d:%02d", m, s)
    end
end

-- video quality badge detector
local function get_video_quality_badge()
    local parts = {}
    local w = mp.get_property_number("video-out-params/w") or mp.get_property_number("width")
    local h = mp.get_property_number("video-out-params/h") or mp.get_property_number("height")
    
    if h and h > 0 then
        local res = ""
        if h >= 2160 or (w and w >= 3800) then
            res = "4k"
        elseif h >= 1400 or (w and w >= 2500) then
            res = "1440p"
        elseif h >= 1080 or (w and w >= 1900) then
            res = "1080p"
        elseif h >= 720 or (w and w >= 1200) then
            res = "720p"
        elseif h >= 480 then
            res = "480p"
        end

        local color_transfer = mp.get_property("video-out-params/color-transfer") or ""
        if color_transfer == "pq" or color_transfer == "hlg" then
            res = res .. " hdr"
        end

        if res ~= "" then
            table.insert(parts, res)
        end
    end

    local channels = mp.get_property_number("audio-params/channel-count")
    if channels and channels >= 6 then
        if channels >= 8 then
            table.insert(parts, "7.1")
        else
            table.insert(parts, "5.1")
        end
    end

    if #parts > 0 then
        return table.concat(parts, " ")
    end
    return nil
end

-- audio detector
local function is_audio_file(path)
    if path then
        local ext = path:match("%.([a-zA-Z0-9]+)$")
        if ext then
            ext = ext:lower()
            local audio_extensions = {
                mp3 = true, flac = true, m4a = true, aac = true, ogg = true,
                opus = true, wav = true, wma = true, alac = true, aiff = true,
                ape = true, mp2 = true, m4b = true, mka = true, mid = true,
                midi = true, ac3 = true, dts = true
            }
            if audio_extensions[ext] then
                return true
            end
        end
    end

    local track_list = mp.get_property_native("track-list", {})
    local has_real_video = false
    local has_audio = false

    if track_list then
        for _, track in ipairs(track_list) do
            if track.type == "video" then
                if not track.albumart and not track["image-only"] then
                    has_real_video = true
                end
            elseif track.type == "audio" then
                has_audio = true
            end
        end
    end

    if has_audio and not has_real_video then
        return true
    end

    local vid = mp.get_property("vid")
    if vid == "no" then
        return true
    end

    return false
end

-- url encoding and filename cleaner
local function url_encode(str)
    if str then
        str = string.gsub(str, "\n", "\r\n")
        str = string.gsub(str, "([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = string.gsub(str, " ", "%%20")
    end
    return str
end

local function clean_media_title(path, media_title)
    local raw = media_title or ""
    if raw == "" and path then
        raw = path:match("([^/\\]+)$") or path
    end

    if raw:find("^http") or raw:find("torrserver") or raw:find("stream") or (path and path:find("http")) then
        local target = (path and path:find("http")) and path or raw
        local url_title = target:match("[?&]title=([^&]+)") or target:match("[?&]name=([^&]+)") or target:match("/stream/([^?]+)")
        if url_title then
            raw = url_title
        end
        raw = raw:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end

    raw = raw:gsub("%.[a-zA-Z0-9]+$", "")

    local season, episode = nil, nil
    local s, e = raw:match("[Ss](%d+)[Ee](%d+)")
    if not s then s, e = raw:match("(%d+)x(%d+)") end
    if not s then s, e = raw:match("[Ss]eason%s*(%d+)%s*[Ee]pisode%s*(%d+)") end
    
    if not s then s, e = raw:match("(%d+)%s*сезон%s*(%d+)%s*серия") end
    if not s then s, e = raw:match("(%d+)%s*Сезон%s*(%d+)%s*Серия") end
    if not s then s, e = raw:match("сезон%s*(%d+)%s*серия%s*(%d+)") end
    if not s then s, e = raw:match("Сезон%s*(%d+)%s*Серия%s*(%d+)") end
    
    if not s then
        s = raw:match("[Ss]eason%s*(%d+)") or raw:match("(%d+)%s*сезон") or raw:match("сезон%s*(%d+)") or raw:match("Сезон%s*(%d+)")
    end
    if not e then
        e = raw:match("[Ee]pisode%s*(%d+)") or raw:match("(%d+)%s*серия") or raw:match("серия%s*(%d+)") or raw:match("Серия%s*(%d+)") or raw:match("%f[%d](%d+)%s*из%s*%d+") or raw:match("%f[%d](%d+)%s*of%s*%d+")
    end
    if not s and not e then
        e = raw:match("%f[%d][Ee][Pp]?(%d+)%f[%D]")
    end

    season = tonumber(s)
    episode = tonumber(e)

    local year = raw:match("%f[%d](19%d%d)%f[%D]") or raw:match("%f[%d](20%d%d)%f[%D]")

    local cleaned = raw:gsub("%[[^%]]+%]", " "):gsub("%([^%)]+%)", " ")
    cleaned = cleaned:gsub("%.", " "):gsub("_", " "):gsub("%-", " ")

    local work = " " .. cleaned:lower() .. " "

    local tech_words = {
        "1080p", "2160p", "720p", "480p", "4k", "2k", "hdr", "hdr10", "dovi", "dv",
        "webdl", "webrip", "bluray", "hdtv", "h264", "x264", "h265", "x265",
        "hevc", "av1", "10bit", "8bit", "aac", "ac3", "eac3", "ddp", "dd",
        "dts", "atmos", "remux", "repack", "proper", "rus", "eng", "sub", "multi",
        "lostfilm", "alexfilm", "coldfilm", "hdrezka", "kinopub", "mkv", "mp4", "avi",
        "season", "episode", "сезон", "серия"
    }

    for _, tw in ipairs(tech_words) do
        work = work:gsub("%f[%w]" .. tw .. "%f[%W]", " ")
    end

    work = work:gsub("[ss]%d+[ee]%d+", " "):gsub("%d+x%d+", " ")
    if year then work = work:gsub(year, " ") end

    work = work:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

    local clean_title = work:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end)

    if clean_title == "" then
        clean_title = raw
    end

    return {
        clean_title = clean_title,
        raw_title = raw,
        year = year,
        season = season,
        episode = episode
    }
end

-- itunes search api provider
local function search_music_cover_soft(artist, track_title, callback)
    if not o.fetch_cover_art then
        callback(nil)
        return
    end

    local query = (artist and (artist .. " ") or "") .. (track_title or "")
    query = query:gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then
        callback(nil)
        return
    end

    if music_cover_cache[query] ~= nil then
        callback(music_cover_cache[query])
        return
    end

    local url = "https://itunes.apple.com/search?term=" .. url_encode(query) .. "&entity=song&limit=1"

    mp.command_native_async({
        name = "subprocess",
        capture_stdout = true,
        capture_stderr = false,
        playback_only = false,
        args = {"curl", "-s", "-H", "User-Agent: Mozilla/5.0", url}
    }, function(success, res, err)
        if success and res and res.status == 0 and res.stdout and #res.stdout > 0 then
            local data = utils.parse_json(res.stdout)
            if data and type(data.results) == "table" and #data.results > 0 then
                local item = data.results[1]
                if item.artworkUrl100 then
                    local cover_url = item.artworkUrl100:gsub("100x100bb", "600x600bb")
                    music_cover_cache[query] = cover_url
                    save_disk_cache()
                    callback(cover_url)
                    return
                end
            end
        end
        music_cover_cache[query] = false
        save_disk_cache()
        callback(nil)
    end)
end

-- imdb search provider
local function search_imdb_soft(info, callback)
    if not o.enable_imdb then
        callback(nil)
        return
    end

    local query = info.clean_title
    local cache_key = query .. (info.year and ("_" .. info.year) or "")

    if imdb_cache[cache_key] ~= nil then
        callback(imdb_cache[cache_key])
        return
    end

    local search_queries = {}
    if info.year then
        table.insert(search_queries, query .. " " .. info.year)
    end
    table.insert(search_queries, query)

    local words = {}
    for word in query:gmatch("%S+") do
        table.insert(words, word)
    end
    if #words > 2 then
        table.insert(search_queries, words[1] .. " " .. words[2])
    end

    local current_query_index = 1

    local function execute_next_query()
        if current_query_index > #search_queries then
            imdb_cache[cache_key] = false
            save_disk_cache()
            callback(nil)
            return
        end

        local q = search_queries[current_query_index]
        current_query_index = current_query_index + 1
        local url = "https://v3.sg.media-imdb.com/suggestion/x/" .. url_encode(q) .. ".json"

        mp.command_native_async({
            name = "subprocess",
            capture_stdout = true,
            capture_stderr = false,
            playback_only = false,
            args = {"curl", "-s", "-H", "User-Agent: Mozilla/5.0", url}
        }, function(success, res, err)
            if success and res and res.status == 0 and res.stdout and #res.stdout > 0 then
                local data = utils.parse_json(res.stdout)
                if data and type(data.d) == "table" and #data.d > 0 then
                    for _, item in ipairs(data.d) do
                        if item.l and item.i and item.i.imageUrl then
                            local result = {
                                id = item.id,
                                title = item.l,
                                year = item.y,
                                type = item.q,
                                poster_url = item.i.imageUrl,
                                stars = item.s
                            }
                            imdb_cache[cache_key] = result
                            save_disk_cache()
                            callback(result)
                            return
                        end
                    end
                end
            end
            execute_next_query()
        end)
    end

    execute_next_query()
end

-- presence payload updater
local function update_discord_presence_payload()
    if not connect_discord_ipc() then return end

    local path = mp.get_property("path")
    if not path then
        local pid = ffi.C.GetCurrentProcessId()
        local idle_json = string.format([[{
            "cmd": "SET_ACTIVITY",
            "args": {
                "pid": %d,
                "activity": {
                    "type": 0,
                    "name": "MPV Media Player",
                    "details": "%s",
                    "state": "%s",
                    "assets": {
                        "large_image": "%s",
                        "large_text": "mpv media player"
                    }
                }
            },
            "nonce": "%d"
        }]], pid, (o.language == "ru" and "в ожидании файла" or "idle"), (o.language == "ru" and "mpv плеер" or "mpv player"), o.large_image_default, os.time())
        send_ipc_packet(1, idle_json)
        return
    end

    local paused = mp.get_property_bool("pause", false)
    if paused and not o.active_when_paused then
        send_ipc_packet(1, string.format('{"cmd":"SET_ACTIVITY","args":{"pid":%d},"nonce":"%d"}', ffi.C.GetCurrentProcessId(), os.time()))
        return
    end

    local media_title = mp.get_property("media-title")
    local is_audio = is_audio_file(path)
    
    local playlist_pos = mp.get_property_number("playlist-pos-1", 1)
    local playlist_count = mp.get_property_number("playlist-count", 1)

    local info = clean_media_title(path, media_title)

    local time_pos = mp.get_property_number("time-pos", 0)
    local duration = mp.get_property_number("duration", 0)
    local now = os.time()
    local start_timestamp = math.floor(now - time_pos)
    local end_timestamp = (duration > 0) and math.floor(start_timestamp + duration) or nil

    local pause_time_str = ""
    if paused and time_pos > 0 then
        if duration > 0 then
            pause_time_str = string.format("%s / %s", format_time(time_pos), format_time(duration))
        else
            pause_time_str = format_time(time_pos)
        end
    end

    local name_str = ""
    local details_str = ""
    local state_str = ""
    local large_image = o.large_image_default
    local large_text = "mpv media player"

    -- Show small icon ONLY on pause (omit during playback)
    local small_image = nil
    local small_text = nil
    if paused then
        if o.small_image_pause and o.small_image_pause ~= "" then
            small_image = o.small_image_pause
        end
        small_text = (o.language == "ru" and "пауза" or "paused")
    end
    
    local act_type = is_audio and o.activity_type_audio or o.activity_type_video

    if is_audio then
        local track_title = mp.get_property("metadata/by-key/Title") or mp.get_property("metadata/by-key/title") or info.clean_title
        local artist = mp.get_property("metadata/by-key/Artist") or mp.get_property("metadata/by-key/artist") or mp.get_property("metadata/by-key/Album_Artist")
        local album = mp.get_property("metadata/by-key/Album") or mp.get_property("metadata/by-key/album")

        if artist and artist ~= "" then
            name_str = artist
        else
            name_str = track_title
        end

        details_str = track_title
        large_text = (artist and (artist .. " - ") or "") .. track_title

        if paused and pause_time_str ~= "" then
            if album and album ~= "" then
                state_str = album .. " • " .. pause_time_str
            else
                state_str = pause_time_str
            end
        else
            if album and album ~= "" then
                state_str = album
            elseif artist and artist ~= "" then
                state_str = artist
            else
                state_str = (o.language == "ru" and "аудиозапись" or "audio track")
            end
        end
        
        if active_music_cover_url then
            large_image = active_music_cover_url
        else
            large_image = o.large_image_audio
        end
    else
        local quality_badge = get_video_quality_badge()
        
        if active_imdb_data then
            name_str = active_imdb_data.title
            details_str = active_imdb_data.title .. (active_imdb_data.year and (" (" .. active_imdb_data.year .. ")") or "")
            
            if active_imdb_data.poster_url and o.fetch_cover_art then
                large_image = active_imdb_data.poster_url
            end
            
            large_text = active_imdb_data.title .. (active_imdb_data.stars and (" • " .. active_imdb_data.stars) or "")
        else
            name_str = info.clean_title
            details_str = info.clean_title .. (info.year and (" (" .. info.year .. ")") or "")
            large_text = info.clean_title
        end

        local ep_parts = {}
        if info.season and info.episode then
            table.insert(ep_parts, string.format("S%02dE%02d", info.season, info.episode))
        elseif info.episode then
            table.insert(ep_parts, string.format(o.language == "ru" and "серия %d" or "episode %d", info.episode))
        end

        if o.show_playlist_pos and playlist_count > 1 then
            table.insert(ep_parts, string.format("[%d/%d]", playlist_pos, playlist_count))
        end

        if quality_badge then
            table.insert(ep_parts, quality_badge)
        end

        if paused and pause_time_str ~= "" then
            table.insert(ep_parts, pause_time_str)
        end

        if #ep_parts > 0 then
            state_str = table.concat(ep_parts, " • ")
        else
            state_str = paused and (o.language == "ru" and "на паузе" or "paused") or (o.language == "ru" and "видео" or "video")
        end
    end

    local assets_tbl = {
        large_image = large_image,
        large_text = large_text
    }
    if small_image then
        assets_tbl.small_image = small_image
        assets_tbl.small_text = small_text
    end

    local pid = ffi.C.GetCurrentProcessId()
    local activity = {
        name = name_str,
        type = act_type,
        details = details_str,
        state = state_str,
        assets = assets_tbl
    }

    if not paused then
        activity.timestamps = {
            start = math.floor(start_timestamp * 1000)
        }
        if duration > 0 then
            activity.timestamps["end"] = math.floor(end_timestamp * 1000)
        end
    end

    if o.show_buttons and (not is_audio) and active_imdb_data and active_imdb_data.id then
        activity.buttons = {
            { label = (o.language == "ru" and "открыть на imdb" or "view on imdb"), url = "https://www.imdb.com/title/" .. active_imdb_data.id .. "/" }
        }
    end

    local payload = {
        cmd = "SET_ACTIVITY",
        args = {
            pid = pid,
            activity = activity
        },
        nonce = tostring(now)
    }

    local json_payload = utils.format_json(payload)
    send_ipc_packet(1, json_payload)
end

-- event lifecycle management
local function on_media_file_changed()
    local path = mp.get_property("path")
    local media_title = mp.get_property("media-title")

    if not path then
        active_file_path = nil
        active_media_title = nil
        active_imdb_data = nil
        active_music_cover_url = nil
        update_discord_presence_payload()
        return
    end

    if path ~= active_file_path or media_title ~= active_media_title then
        active_file_path = path
        active_media_title = media_title
        active_imdb_data = nil
        active_music_cover_url = nil

        local is_audio = is_audio_file(path)
        local info = clean_media_title(path, media_title)

        update_discord_presence_payload()

        if is_audio then
            local track_title = mp.get_property("metadata/by-key/Title") or mp.get_property("metadata/by-key/title") or info.clean_title
            local artist = mp.get_property("metadata/by-key/Artist") or mp.get_property("metadata/by-key/artist") or mp.get_property("metadata/by-key/Album_Artist")
            
            search_music_cover_soft(artist, track_title, function(cover_url)
                if cover_url and path == active_file_path then
                    active_music_cover_url = cover_url
                    update_discord_presence_payload()
                end
            end)
        else
            if o.enable_imdb then
                search_imdb_soft(info, function(imdb_data)
                    if imdb_data and path == active_file_path then
                        active_imdb_data = imdb_data
                        update_discord_presence_payload()
                    end
                end)
            end
        end
    else
        update_discord_presence_payload()
    end
end

mp.register_event("start-file", function()
    start_time = os.time()
    on_media_file_changed()
end)

mp.register_event("file-loaded", function()
    start_time = os.time()
    on_media_file_changed()
end)

mp.observe_property("pause", "bool", function()
    update_discord_presence_payload()
end)

mp.observe_property("playlist-pos", "number", function()
    on_media_file_changed()
end)

mp.observe_property("media-title", "string", function()
    on_media_file_changed()
end)

mp.observe_property("metadata", "native", function()
    on_media_file_changed()
end)

timer = mp.add_periodic_timer(o.update_interval, update_discord_presence_payload)

mp.register_event("shutdown", function()
    if ipc_handle and ipc_handle ~= INVALID_HANDLE_VALUE then
        ffi.C.CloseHandle(ipc_handle)
        ipc_handle = nil
    end
end)

mp.msg.info("discord rich presence script loaded successfully")
