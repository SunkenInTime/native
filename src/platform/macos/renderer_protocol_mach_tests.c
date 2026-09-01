#include "renderer_protocol_mach.h"

#include <assert.h>
#include <float.h>
#include <math.h>
#include <string.h>

static WeaverRendererMachPixels valid_pixels_message(void) {
    WeaverRendererMachPixels message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_size = sizeof(message);
    message.header.msgh_id = kWeaverRendererMachMsgPixels;
    message.body.msgh_descriptor_count = 1;
    message.pixels.size = 16;
    message.pixels.type = MACH_MSG_OOL_DESCRIPTOR;
    message.magic = kWeaverRendererMachMagic;
    message.version = kWeaverRendererMachVersion;
    message.struct_size = sizeof(message);
    message.pixel_len = 16;
    message.pixel_width = 2;
    message.pixel_height = 2;
    message.scale = 2;
    return message;
}

void native_sdk_renderer_protocol_mach_tests_run(void) {
    WeaverRendererMachHello hello;
    memset(&hello, 0, sizeof(hello));
    hello.header.msgh_size = sizeof(hello);
    hello.magic = kWeaverRendererMachMagic;
    hello.version = kWeaverRendererMachVersion;
    hello.struct_size = sizeof(hello);
    hello.widget_pid = 42;
    assert(weaverRendererMachHelloValid(&hello));
    hello.version = 1;
    assert(!weaverRendererMachHelloValid(&hello));

    WeaverRendererMachPixels message = valid_pixels_message();
    assert(kWeaverRendererMachVersion == 2);
    assert(weaverRendererMachPixelsValid(&message));

    message.version = 1;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.pixel_len -= 1;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.pixels.size -= 1;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.pixels.type = MACH_MSG_PORT_DESCRIPTOR;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.header.msgh_size -= 1;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.pixel_width = kWeaverRendererMachMaxPhysicalExtent + 1;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.scale = NAN;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.has_dirty_rect = 1;
    message.dirty_x = -1;
    message.dirty_y = 0;
    message.dirty_width = 2;
    message.dirty_height = 2;
    assert(weaverRendererMachPixelsValid(&message));

    message.dirty_width = INFINITY;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.has_dirty_rect = 1;
    message.dirty_x = DBL_MAX;
    message.dirty_width = DBL_MAX;
    message.dirty_height = 1;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.has_dirty_rect = 2;
    assert(!weaverRendererMachPixelsValid(&message));

    message = valid_pixels_message();
    message.reserved = 1;
    assert(!weaverRendererMachPixelsValid(&message));
}
