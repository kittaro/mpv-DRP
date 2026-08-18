# mpv discord rich presence

A lightweight, zero-dependency **Discord Rich Presence** integration for the **mpv** media player on Windows.

> **About this project**  
> This mpv script serves a specific, key purpose for me: it extracts media information from the filename and looks up details on IMDb for display in Discord via Discord Rich Presence (most often, mpv is isolated and used separately to stream local torrents via the TorrServer integration script). Additionally, track/music integration was implemented via the iTunes API (medium quality library and cover art).  
>  
> *Note: The episode count displayed in the integration represents the file index within the mpv playlist.*

---

## features

- **zero dependencies:** uses native Windows named pipe IPC via LuaJIT FFI (no external DLLs or python background processes required)
- **imdb soft search:** automatically cleans filenames, extracts title, year, season, and episode, and fetches poster art from IMDb
- **itunes music integration:** fetches track artwork via the iTunes Search API
- **torrserver support:** parses streaming URLs and handles playlist titles automatically
- **native discord timer & pause support:** uses native Discord timestamps during playback and displays static time position when paused

---

## installation

1. Copy `scripts/discord_rp.lua` to your mpv `scripts/` directory (`~~/scripts/` or `portable_config/scripts/`).
2. Copy `script-opts/discord_rp.conf` to your mpv `script-opts/` directory (`~~/script-opts/` or `portable_config/script-opts/`).
3. Make sure Discord is running and open any media file in mpv.

---

## configuration (`script-opts/discord_rp.conf`)

```ini
# discord application client id
client_id=1462038267183628308

# activity types (3 = watching, 2 = listening)
activity_type_video=3
activity_type_audio=2

# enable poster artwork from imdb and itunes
fetch_cover_art=yes

# enable imdb search for video
enable_imdb=yes

# show playlist position e.g. [5/12]
show_playlist_pos=yes

# interface language: en or ru
language=en

# show imdb button in discord card
show_buttons=yes
```
