#include "shared_renderer_client.h"
#include "renderer_protocol.h"

#include <dcomp.h>
#include <wrl/client.h>

#include <string>

using Microsoft::WRL::ComPtr;

struct NativeSdkSharedRendererClient {
    HWND window = nullptr;
    std::wstring pipe_name;
    HANDLE pipe = INVALID_HANDLE_VALUE;
    HANDLE surface_handle = nullptr;
    bool connected = false;
    ComPtr<IDCompositionDesktopDevice> composition;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual2> visual;
    ComPtr<IUnknown> surface;
};

static void disconnectRenderer(NativeSdkSharedRendererClient *client) {
    if (!client) return;
    if (client->pipe != INVALID_HANDLE_VALUE) CloseHandle(client->pipe);
    client->pipe = INVALID_HANDLE_VALUE;
    client->connected = false;
}

static bool writeExact(HANDLE file, const void *bytes, size_t length) {
    const uint8_t *cursor = static_cast<const uint8_t *>(bytes);
    while (length > 0) {
        DWORD written = 0;
        if (!WriteFile(file, cursor, (DWORD)length, &written, nullptr) || written == 0) return false;
        cursor += written;
        length -= written;
    }
    return true;
}

static bool readExact(HANDLE file, void *bytes, size_t length) {
    uint8_t *cursor = static_cast<uint8_t *>(bytes);
    while (length > 0) {
        DWORD read = 0;
        if (!ReadFile(file, cursor, (DWORD)length, &read, nullptr) || read == 0) return false;
        cursor += read;
        length -= read;
    }
    return true;
}

static bool connectRenderer(NativeSdkSharedRendererClient *client) {
    if (client->pipe != INVALID_HANDLE_VALUE) return true;
    if (!WaitNamedPipeW(client->pipe_name.c_str(), 100)) return false;
    client->pipe = CreateFileW(client->pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE,
        0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (client->pipe == INVALID_HANDLE_VALUE) return false;
    DWORD mode = PIPE_READMODE_BYTE;
    if (!SetNamedPipeHandleState(client->pipe, &mode, nullptr, nullptr)) {
        disconnectRenderer(client);
        return false;
    }
    return true;
}

NativeSdkSharedRendererClient *nativeSdkSharedRendererClientCreate(HWND window) {
    if (!window) return nullptr;
    wchar_t pipe_name[512] = {};
    const DWORD length = GetEnvironmentVariableW(L"WEAVER_RENDERER_PIPE",
        pipe_name, ARRAYSIZE(pipe_name));
    if (length == 0 || length >= ARRAYSIZE(pipe_name)) return nullptr;
    wchar_t forced[8] = {};
    if (GetEnvironmentVariableW(L"WEAVER_FORCE_SOFTWARE", forced, ARRAYSIZE(forced)) > 0 &&
        wcscmp(forced, L"1") == 0) return nullptr;
    NativeSdkSharedRendererClient *client = new NativeSdkSharedRendererClient();
    client->window = window;
    client->pipe_name.assign(pipe_name, length);
    return client;
}

void nativeSdkSharedRendererClientDestroy(NativeSdkSharedRendererClient *client) {
    if (!client) return;
    disconnectRenderer(client);
    if (client->surface_handle) CloseHandle(client->surface_handle);
    delete client;
}

bool nativeSdkSharedRendererClientPresent(NativeSdkSharedRendererClient *client,
    double logical_width, double logical_height, double scale,
    uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a,
    const uint8_t *packet, size_t packet_len) {
    if (!client || !packet || packet_len == 0 || packet_len > kWeaverRendererMaxPacket ||
        !connectRenderer(client)) return false;
    WeaverRendererFrame frame = {};
    frame.magic = kWeaverRendererMagic;
    frame.version = kWeaverRendererVersion;
    frame.widget_pid = GetCurrentProcessId();
    frame.packet_len = (uint32_t)packet_len;
    frame.logical_width = logical_width;
    frame.logical_height = logical_height;
    frame.scale = scale;
    frame.clear_r = clear_r;
    frame.clear_g = clear_g;
    frame.clear_b = clear_b;
    frame.clear_a = clear_a;
    WeaverRendererReply reply = {};
    if (!writeExact(client->pipe, &frame, sizeof(frame)) ||
        !writeExact(client->pipe, packet, packet_len) ||
        !readExact(client->pipe, &reply, sizeof(reply)) ||
        reply.magic != kWeaverRendererMagic ||
        reply.version != kWeaverRendererVersion || reply.status != 1) {
        disconnectRenderer(client);
        return false;
    }
    if (reply.surface_handle != 0) {
        HANDLE replacement = reinterpret_cast<HANDLE>(reply.surface_handle);
        if (!client->composition &&
            (FAILED(DCompositionCreateDevice2(nullptr, IID_PPV_ARGS(&client->composition))) ||
             FAILED(client->composition->CreateTargetForHwnd(client->window, TRUE, &client->target)) ||
             FAILED(client->composition->CreateVisual(&client->visual)))) {
            client->composition.Reset();
            client->target.Reset();
            client->visual.Reset();
            CloseHandle(replacement);
            disconnectRenderer(client);
            return false;
        }
        ComPtr<IUnknown> surface;
        if (FAILED(client->composition->CreateSurfaceFromHandle(replacement, &surface)) ||
            FAILED(client->visual->SetContent(surface.Get())) ||
            FAILED(client->target->SetRoot(client->visual.Get())) ||
            FAILED(client->composition->Commit())) {
            CloseHandle(replacement);
            disconnectRenderer(client);
            return false;
        }
        client->surface = surface;
        if (client->surface_handle) CloseHandle(client->surface_handle);
        client->surface_handle = replacement;
    }
    client->connected = true;
    return true;
}

bool nativeSdkSharedRendererClientConnected(const NativeSdkSharedRendererClient *client) {
    return client && client->connected;
}
