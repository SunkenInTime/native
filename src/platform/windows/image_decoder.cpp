#include <windows.h>
#include <wincodec.h>

#include <climits>
#include <cstddef>
#include <cstdint>

static const GUID kNativeSdkCLSID_WICImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
static const GUID kNativeSdkIID_IWICImagingFactory = {0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
static const GUID kNativeSdkGUID_WICPixelFormat32bppRGBA = {0xf5c7ad2d, 0x6a8d, 0x43dd, {0xa7, 0xa8, 0xa2, 0x99, 0x35, 0x26, 0x1a, 0xe9}};
static const GUID kNativeSdkGUID_WICPixelFormat32bppBGRA = {0x6fddc324, 0x4e03, 0x4bfe, {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}};

static int nativeSdkWindowsDecodeImageAttempt(const uint8_t *bytes, size_t bytes_len, uint8_t *pixels, size_t pixels_len, size_t *out_width, size_t *out_height, const GUID &pixel_format, bool bgra) {
    int result = 0;
    IWICImagingFactory *factory = nullptr;
    IWICStream *stream = nullptr;
    IWICBitmapDecoder *decoder = nullptr;
    IWICBitmapFrameDecode *frame = nullptr;
    IWICFormatConverter *converter = nullptr;
    do {
        if (FAILED(CoCreateInstance(kNativeSdkCLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, kNativeSdkIID_IWICImagingFactory, reinterpret_cast<void **>(&factory)))) break;
        if (FAILED(factory->CreateStream(&stream))) break;
        if (FAILED(stream->InitializeFromMemory(const_cast<BYTE *>(bytes), static_cast<DWORD>(bytes_len)))) break;
        if (FAILED(factory->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder))) break;
        if (FAILED(decoder->GetFrame(0, &frame))) break;

        UINT frame_width = 0;
        UINT frame_height = 0;
        if (FAILED(frame->GetSize(&frame_width, &frame_height))) break;
        if (frame_width == 0 || frame_height == 0 || frame_width > 8192 || frame_height > 8192) break;
        size_t width = frame_width;
        size_t height = frame_height;
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
        size_t byte_len = width * height * 4;
        if (pixels_len < byte_len) {
            result = -1;
            break;
        }

        if (FAILED(factory->CreateFormatConverter(&converter))) break;
        if (FAILED(converter->Initialize(frame, pixel_format, WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom))) break;
        if (FAILED(converter->CopyPixels(nullptr, static_cast<UINT>(width * 4), static_cast<UINT>(byte_len), pixels))) break;
        if (bgra) {
            for (size_t offset = 0; offset < byte_len; offset += 4) {
                uint8_t red = pixels[offset];
                pixels[offset] = pixels[offset + 2];
                pixels[offset + 2] = red;
            }
        }
        result = 1;
    } while (false);

    if (converter) converter->Release();
    if (frame) frame->Release();
    if (decoder) decoder->Release();
    if (stream) stream->Release();
    if (factory) factory->Release();
    return result;
}

extern "C" int native_sdk_windows_decode_image(const uint8_t *bytes, size_t bytes_len, uint8_t *pixels, size_t pixels_len, size_t *out_width, size_t *out_height) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!bytes || bytes_len == 0 || !pixels || bytes_len > UINT32_MAX) return 0;

    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool uninitialize = SUCCEEDED(init); // S_FALSE still pairs with CoUninitialize.
    int result = nativeSdkWindowsDecodeImageAttempt(bytes, bytes_len, pixels, pixels_len, out_width, out_height, kNativeSdkGUID_WICPixelFormat32bppRGBA, false);
    if (result == 0) {
        // A new stream/decoder/converter is intentional: a failed WIC object
        // graph is not reusable, and the BGRA converter is the codec-native
        // route on Windows rather than another call on poisoned state.
        result = nativeSdkWindowsDecodeImageAttempt(bytes, bytes_len, pixels, pixels_len, out_width, out_height, kNativeSdkGUID_WICPixelFormat32bppBGRA, true);
    }
    if (uninitialize) CoUninitialize();
    return result;
}
