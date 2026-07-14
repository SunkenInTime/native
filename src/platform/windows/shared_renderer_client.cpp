#include "shared_renderer_client.h"
#include "renderer_protocol.h"

#include <dcomp.h>
#include <wrl/client.h>

#include <string>
#include <algorithm>
#include <cmath>
#include <cwchar>

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
    HANDLE retained_mapping = nullptr;
    uint8_t *retained_pixels = nullptr;
    size_t retained_capacity = 0;
    std::wstring retained_name;
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
    if (client->retained_pixels) UnmapViewOfFile(client->retained_pixels);
    if (client->retained_mapping) CloseHandle(client->retained_mapping);
    delete client;
}

static bool ensureRetainedMapping(NativeSdkSharedRendererClient *client, size_t bytes) {
    if (client->retained_mapping && client->retained_capacity == bytes) return true;
    if (client->retained_pixels) UnmapViewOfFile(client->retained_pixels);
    if (client->retained_mapping) CloseHandle(client->retained_mapping);
    client->retained_pixels = nullptr;
    client->retained_mapping = nullptr;
    client->retained_capacity = 0;
    wchar_t name[kWeaverRendererSectionNameChars] = {};
    swprintf_s(name, L"Local\\WeaverRetained-%lu-%llu", (unsigned long)GetCurrentProcessId(),
        (unsigned long long)GetTickCount64());
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
        (DWORD)(bytes >> 32), (DWORD)bytes, name);
    if (!mapping) return false;
    uint8_t *pixels = static_cast<uint8_t *>(MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, bytes));
    if (!pixels) { CloseHandle(mapping); return false; }
    client->retained_mapping = mapping;
    client->retained_pixels = pixels;
    client->retained_capacity = bytes;
    client->retained_name = name;
    return true;
}

static void premultiplyRetained(NativeSdkSharedRendererClient *client, size_t width,
    size_t height, double scale, const float *rects, size_t rect_count,
    const uint8_t *rgba) {
    const size_t count = rect_count == 0 ? 1 : std::min<size_t>(rect_count, kWeaverRendererMaxDirtyRects);
    for (size_t rect_index = 0; rect_index < count; ++rect_index) {
        int left = 0, top = 0, right = (int)width, bottom = (int)height;
        if (rect_count > 0) {
            const float *rect = rects + rect_index * 4;
            left = std::max(0, std::min((int)width, (int)floor(rect[0] * scale)));
            top = std::max(0, std::min((int)height, (int)floor(rect[1] * scale)));
            right = std::max(left, std::min((int)width, (int)ceil((rect[0] + rect[2]) * scale)));
            bottom = std::max(top, std::min((int)height, (int)ceil((rect[1] + rect[3]) * scale)));
        }
        for (int y = top; y < bottom; ++y) for (int x = left; x < right; ++x) {
            const size_t offset = ((size_t)y * width + (size_t)x) * 4;
            const uint8_t alpha = rgba[offset + 3];
            client->retained_pixels[offset + 0] = (uint8_t)(((uint32_t)rgba[offset + 2] * alpha + 127) / 255);
            client->retained_pixels[offset + 1] = (uint8_t)(((uint32_t)rgba[offset + 1] * alpha + 127) / 255);
            client->retained_pixels[offset + 2] = (uint8_t)(((uint32_t)rgba[offset + 0] * alpha + 127) / 255);
            client->retained_pixels[offset + 3] = alpha;
        }
    }
}

bool nativeSdkSharedRendererClientPresent(NativeSdkSharedRendererClient *client,
    double logical_width, double logical_height, double scale,
    uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a,
    const uint8_t *packet, size_t packet_len, uint64_t retained_generation,
    size_t retained_width, size_t retained_height, const float *retained_dirty_rects,
    size_t retained_dirty_rect_count, const uint8_t *retained_rgba8,
    size_t retained_rgba8_len) {
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
    if (retained_generation != 0) {
        const size_t expected = retained_width * retained_height * 4;
        if (!retained_rgba8 || retained_rgba8_len != expected ||
            retained_width > UINT32_MAX || retained_height > UINT32_MAX ||
            retained_dirty_rect_count > kWeaverRendererMaxDirtyRects ||
            !ensureRetainedMapping(client, expected)) return false;
        premultiplyRetained(client, retained_width, retained_height, scale,
            retained_dirty_rects, retained_dirty_rect_count, retained_rgba8);
        frame.retained_generation = retained_generation;
        frame.retained_width = (uint32_t)retained_width;
        frame.retained_height = (uint32_t)retained_height;
        frame.retained_dirty_rect_count = (uint32_t)retained_dirty_rect_count;
        frame.retained_section_name_len = (uint32_t)std::min<size_t>(client->retained_name.size(), kWeaverRendererSectionNameChars - 1);
        memcpy(frame.retained_section_name, client->retained_name.data(), frame.retained_section_name_len * sizeof(wchar_t));
        for (size_t i = 0; i < retained_dirty_rect_count; ++i) {
            const float *rect = retained_dirty_rects + i * 4;
            frame.retained_dirty_rects[i] = { rect[0], rect[1], rect[2], rect[3] };
        }
    }
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
