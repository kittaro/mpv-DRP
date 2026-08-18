/*
 * =============================================================================
 * Discord Social SDK / IPC C DLL Bridge for MPV
 * =============================================================================
 * This optional C dynamic library provides a native C interface to Discord
 * Rich Presence using Windows Named Pipes or Discord Game/Social SDK.
 * 
 * Compilation (MinGW / MSVC / GCC):
 *   gcc -shared -O2 -o discord_rp_bridge.dll discord_rp_bridge.c -lwinmm
 * =============================================================================
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __declspec(dllexport)

static HANDLE hPipe = INVALID_HANDLE_VALUE;
static int g_connected = 0;

EXPORT int discord_init(const char* client_id) {
    if (g_connected && hPipe != INVALID_HANDLE_VALUE) {
        return 1;
    }

    char pipe_name[64];
    for (int i = 0; i < 10; i++) {
        snprintf(pipe_name, sizeof(pipe_name), "\\\\.\\pipe\\discord-ipc-%d", i);
        hPipe = CreateFileA(
            pipe_name,
            GENERIC_READ | GENERIC_WRITE,
            0,
            NULL,
            OPEN_EXISTING,
            0,
            NULL
        );

        if (hPipe != INVALID_HANDLE_VALUE) {
            g_connected = 1;

            // Send Handshake Payload (Opcode 0)
            char payload[256];
            snprintf(payload, sizeof(payload), "{\"v\":1,\"client_id\":\"%s\"}", client_id);
            DWORD len = (DWORD)strlen(payload);

            DWORD header[2];
            header[0] = 0; // Opcode 0
            header[1] = len;

            DWORD written = 0;
            WriteFile(hPipe, header, sizeof(header), &written, NULL);
            WriteFile(hPipe, payload, len, &written, NULL);

            return 1;
        }
    }

    return 0;
}

EXPORT int discord_set_activity(const char* json_activity) {
    if (!g_connected || hPipe == INVALID_HANDLE_VALUE) {
        return 0;
    }

    DWORD len = (DWORD)strlen(json_activity);
    DWORD header[2];
    header[0] = 1; // Opcode 1 (FRAME)
    header[1] = len;

    DWORD written = 0;
    if (!WriteFile(hPipe, header, sizeof(header), &written, NULL) ||
        !WriteFile(hPipe, json_activity, len, &written, NULL)) {
        CloseHandle(hPipe);
        hPipe = INVALID_HANDLE_VALUE;
        g_connected = 0;
        return 0;
    }

    return 1;
}

EXPORT void discord_shutdown(void) {
    if (hPipe != INVALID_HANDLE_VALUE) {
        CloseHandle(hPipe);
        hPipe = INVALID_HANDLE_VALUE;
    }
    g_connected = 0;
}
