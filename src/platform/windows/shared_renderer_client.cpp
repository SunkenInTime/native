#include "shared_renderer_client.h"
#include "renderer_protocol.h"

#include <dcomp.h>
#include <d2d1.h>
#include <wrl/client.h>

#include <string>
#include <algorithm>
#include <cmath>
#include <cwchar>
#include <cstdio>

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
    uint64_t visual_geometry_generation = 0;
    uint32_t visual_width_px = 0;
    uint32_t visual_height_px = 0;
    std::string last_failure;
};

static void appendDpiLine(const char *line, size_t length) {
    wchar_t path[32768] = {};
    const DWORD path_length = GetEnvironmentVariableW(L"WEAVER_DPI_LOG", path,
        ARRAYSIZE(path));
    if (!line || length == 0 || path_length == 0 ||
        path_length >= ARRAYSIZE(path)) return;
    HANDLE file = CreateFileW(path, FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line, static_cast<DWORD>(length), &written, nullptr);
    CloseHandle(file);
}

static void logSharedFailure(NativeSdkSharedRendererClient *client,
    const char *stage, double logical_width = 0, double logical_height = 0,
    double scale = 0, const NativeSdkSharedRendererGeometry *geometry = nullptr) {
    if (!client || !stage || client->last_failure == stage) return;
    client->last_failure = stage;
    char line[512] = {};
    const int length = snprintf(line, sizeof(line),
        "%llu shared-visual-failure pid=%lu child_hwnd=0x%llx stage=%s "
        "logical_surface_dip=%.6fx%.6f scale=%.6f texture_px=%ux%u "
        "destination_edges_px=(%ld,%ld,%ld,%ld) generation=%llu error=%lu\r\n",
        (unsigned long long)GetTickCount64(),
        (unsigned long)GetCurrentProcessId(),
        (unsigned long long)(uintptr_t)client->window, stage, logical_width,
        logical_height, scale,
        geometry ? geometry->source_texture_width_px : 0,
        geometry ? geometry->source_texture_height_px : 0,
        geometry ? geometry->destination_left_px : 0,
        geometry ? geometry->destination_top_px : 0,
        geometry ? geometry->destination_right_px : 0,
        geometry ? geometry->destination_bottom_px : 0,
        (unsigned long long)(geometry ? geometry->generation : 0),
        (unsigned long)GetLastError());
    if (length > 0) appendDpiLine(line, static_cast<size_t>(length));
}

static void logDpiGeometry(const NativeSdkSharedRendererClient *client,
    const NativeSdkSharedRendererGeometry &geometry, double logical_width,
    double logical_height, double scale, const char *action) {
    if (!client) return;
    // gpu_surface HWNDs are direct children of the owning Weaver window.
    // Desktop-layer windows themselves become WorkerW children, so GA_ROOT
    // would report WorkerW rather than the actual geometry owner.
    HWND root = GetParent(client->window);
    if (!root) root = GetAncestor(client->window, GA_ROOT);
    RECT root_client = {}, child_client = {};
    if (root) GetClientRect(root, &root_client);
    GetClientRect(client->window, &child_client);
    char line[768] = {};
    const int length = snprintf(line, sizeof(line),
        "%llu shared-visual pid=%lu root_hwnd=0x%llx child_hwnd=0x%llx "
        "root_client_px=%ldx%ld child_client_px=%ldx%ld dpi=%u scale=%.6f "
        "logical_surface_dip=%.6fx%.6f destination_dip=(%.6f,%.6f %.6fx%.6f) "
        "destination_edges_px=(%ld,%ld,%ld,%ld) texture_px=%ux%u generation=%llu action=%s\r\n",
        (unsigned long long)GetTickCount64(), (unsigned long)GetCurrentProcessId(),
        (unsigned long long)(uintptr_t)root,
        (unsigned long long)(uintptr_t)client->window,
        root_client.right - root_client.left, root_client.bottom - root_client.top,
        child_client.right - child_client.left, child_client.bottom - child_client.top,
        (unsigned int)std::round(scale * 96.0), scale, logical_width,
        logical_height, geometry.destination_x_dip, geometry.destination_y_dip,
        geometry.destination_width_dip, geometry.destination_height_dip,
        geometry.destination_left_px, geometry.destination_top_px,
        geometry.destination_right_px, geometry.destination_bottom_px,
        geometry.source_texture_width_px, geometry.source_texture_height_px,
        (unsigned long long)geometry.generation, action);
    if (length <= 0) return;
    appendDpiLine(line, static_cast<size_t>(length));
}

static void disconnectRenderer(NativeSdkSharedRendererClient *client) {
    if (!client) return;
    if (client->pipe != INVALID_HANDLE_VALUE) CloseHandle(client->pipe);
    client->pipe = INVALID_HANDLE_VALUE;
    client->connected = false;
    // A dead renderer leaves its last composition surface valid in DWM.
    // Release that visual tree before the host switches the HWND back to a
    // layered bitmap; otherwise UpdateLayeredWindow fails and the widget
    // appears frozen until a replacement renderer publishes another handle.
    if (client->target) {
        client->target->SetRoot(nullptr);
        if (client->composition) client->composition->Commit();
    }
    client->surface.Reset();
    client->visual.Reset();
    client->target.Reset();
    client->composition.Reset();
    if (client->surface_handle) CloseHandle(client->surface_handle);
    client->surface_handle = nullptr;
    client->visual_geometry_generation = 0;
    client->visual_width_px = 0;
    client->visual_height_px = 0;
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
    // weaverd launches the shared renderer immediately before the first GPU
    // widget. Creating the process and publishing its first pipe instance is
    // asynchronous, so the first surface establishment gets one bounded
    // lifecycle wait. Connected frames never take this path, and later
    // recovery attempts use the same bound without introducing frame churn.
    const uint64_t deadline = GetTickCount64() + 2000;
    bool pipe_ready = false;
    do {
        pipe_ready = WaitNamedPipeW(client->pipe_name.c_str(), 100) != FALSE;
        if (pipe_ready) break;
        if (GetTickCount64() < deadline) Sleep(10);
    } while (GetTickCount64() < deadline);
    if (!pipe_ready) {
        logSharedFailure(client, "wait-pipe");
        return false;
    }
    client->pipe = CreateFileW(client->pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE,
        0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (client->pipe == INVALID_HANDLE_VALUE) {
        logSharedFailure(client, "open-pipe");
        return false;
    }
    DWORD mode = PIPE_READMODE_BYTE;
    if (!SetNamedPipeHandleState(client->pipe, &mode, nullptr, nullptr)) {
        disconnectRenderer(client);
        logSharedFailure(client, "pipe-mode");
        return false;
    }
    WeaverRendererHello hello = {};
    hello.magic = kWeaverRendererMagic;
    hello.version = kWeaverRendererVersion;
    hello.struct_size = sizeof(hello);
    hello.widget_pid = GetCurrentProcessId();
    WeaverRendererHelloReply reply = {};
    if (!writeExact(client->pipe, &hello, sizeof(hello)) ||
        !readExact(client->pipe, &reply, sizeof(reply)) ||
        reply.magic != kWeaverRendererMagic ||
        reply.version != kWeaverRendererVersion ||
        reply.struct_size != sizeof(reply) ||
        reply.status != kWeaverRendererStatusOk) {
        disconnectRenderer(client);
        logSharedFailure(client, "protocol-hello");
        return false;
    }
    client->last_failure.clear();
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
            const WeaverPhysicalBoxU box = weaverLogicalDirtyRectToPhysicalBox(
                { rect[0], rect[1], rect[2], rect[3] }, scale,
                static_cast<uint32_t>(width), static_cast<uint32_t>(height));
            left = static_cast<int>(box.left);
            top = static_cast<int>(box.top);
            right = static_cast<int>(box.right);
            bottom = static_cast<int>(box.bottom);
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
    const NativeSdkSharedRendererGeometry *geometry,
    uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a,
    const uint8_t *packet, size_t packet_len, int retained_composite,
    uint64_t retained_generation,
    size_t retained_width, size_t retained_height, const float *retained_dirty_rects,
    size_t retained_dirty_rect_count, const uint8_t *retained_rgba8,
    size_t retained_rgba8_len) {
    if (!client) return false;
    if (!geometry) {
        logSharedFailure(client, "missing-geometry", logical_width,
            logical_height, scale);
        return false;
    }
    if (!packet || packet_len == 0 || packet_len > kWeaverRendererMaxPacket ||
        (retained_composite != 0 && retained_composite != 1)) {
        logSharedFailure(client, "invalid-packet", logical_width,
            logical_height, scale, geometry);
        return false;
    }
    if (!weaverValidDeviceScale(scale) ||
        !weaverValidLogicalRect({ 0, 0, logical_width, logical_height }) ||
        geometry->generation == 0 ||
        !weaverValidSurfaceExtent(geometry->source_texture_width_px,
            geometry->source_texture_height_px)) {
        logSharedFailure(client, "invalid-geometry", logical_width,
            logical_height, scale, geometry);
        return false;
    }
    if (!connectRenderer(client)) return false;
    WeaverRendererFrame frame = {};
    frame.magic = kWeaverRendererMagic;
    frame.version = kWeaverRendererVersion;
    frame.struct_size = sizeof(frame);
    frame.widget_pid = GetCurrentProcessId();
    frame.packet_len = (uint32_t)packet_len;
    frame.logical_surface_width_dip = logical_width;
    frame.logical_surface_height_dip = logical_height;
    frame.device_scale = scale;
    frame.destination_x_dip = geometry->destination_x_dip;
    frame.destination_y_dip = geometry->destination_y_dip;
    frame.destination_width_dip = geometry->destination_width_dip;
    frame.destination_height_dip = geometry->destination_height_dip;
    frame.destination_left_px = geometry->destination_left_px;
    frame.destination_top_px = geometry->destination_top_px;
    frame.destination_right_px = geometry->destination_right_px;
    frame.destination_bottom_px = geometry->destination_bottom_px;
    frame.source_texture_width_px = geometry->source_texture_width_px;
    frame.source_texture_height_px = geometry->source_texture_height_px;
    frame.geometry_generation = geometry->generation;
    frame.clear_r = clear_r;
    frame.clear_g = clear_g;
    frame.clear_b = clear_b;
    frame.clear_a = clear_a;
    frame.retained_above_packet = static_cast<uint32_t>(retained_composite);
    if (retained_generation != 0) {
        if (retained_width != geometry->source_texture_width_px ||
            retained_height != geometry->source_texture_height_px ||
            retained_width > SIZE_MAX / retained_height ||
            retained_width * retained_height > SIZE_MAX / 4) return false;
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
        reply.version != kWeaverRendererVersion ||
        reply.status != kWeaverRendererStatusOk) {
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
        const D2D_MATRIX_3X2_F identity = { 1, 0, 0, 1, 0, 0 };
        const D2D_RECT_F clip = { 0, 0,
            static_cast<float>(geometry->source_texture_width_px),
            static_cast<float>(geometry->source_texture_height_px) };
        if (FAILED(client->composition->CreateSurfaceFromHandle(replacement, &surface)) ||
            FAILED(client->visual->SetContent(surface.Get())) ||
            FAILED(client->visual->SetOffsetX(0.0f)) ||
            FAILED(client->visual->SetOffsetY(0.0f)) ||
            FAILED(client->visual->SetTransform(identity)) ||
            FAILED(client->visual->SetClip(clip)) ||
            FAILED(client->target->SetRoot(client->visual.Get())) ||
            FAILED(client->composition->Commit())) {
            CloseHandle(replacement);
            disconnectRenderer(client);
            return false;
        }
        client->surface = surface;
        if (client->surface_handle) CloseHandle(client->surface_handle);
        client->surface_handle = replacement;
        const char *action = client->visual_geometry_generation == 0 ? "created-rebound" : "resized-rebound";
        client->visual_geometry_generation = geometry->generation;
        client->visual_width_px = geometry->source_texture_width_px;
        client->visual_height_px = geometry->source_texture_height_px;
        logDpiGeometry(client, *geometry, logical_width, logical_height, scale, action);
    } else if (geometry->generation != client->visual_geometry_generation) {
        if (!client->composition || !client->visual) {
            disconnectRenderer(client);
            return false;
        }
        const D2D_MATRIX_3X2_F identity = { 1, 0, 0, 1, 0, 0 };
        const D2D_RECT_F clip = { 0, 0,
            static_cast<float>(geometry->source_texture_width_px),
            static_cast<float>(geometry->source_texture_height_px) };
        if (FAILED(client->visual->SetOffsetX(0.0f)) ||
            FAILED(client->visual->SetOffsetY(0.0f)) ||
            FAILED(client->visual->SetTransform(identity)) ||
            FAILED(client->visual->SetClip(clip)) ||
            FAILED(client->composition->Commit())) {
            disconnectRenderer(client);
            return false;
        }
        const bool extent_changed = weaverSurfaceExtentChanged(
            client->visual_width_px, client->visual_height_px,
            geometry->source_texture_width_px,
            geometry->source_texture_height_px);
        client->visual_geometry_generation = geometry->generation;
        client->visual_width_px = geometry->source_texture_width_px;
        client->visual_height_px = geometry->source_texture_height_px;
        logDpiGeometry(client, *geometry, logical_width, logical_height, scale,
            extent_changed ? "resized-reused" : "moved-reused");
    }
    client->connected = true;
    client->last_failure.clear();
    return true;
}

bool nativeSdkSharedRendererClientConnected(const NativeSdkSharedRendererClient *client) {
    return client && client->connected;
}
