#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Minimal public libmpv node ABI. This fixture has no player or dependencies.
typedef struct node node;
typedef struct { int num; node *values; char **keys; } node_list;
typedef struct { void *data; size_t size; } byte_array;
struct node {
    union { char *string; int64_t integer; node_list *list; byte_array *bytes; } u;
    int format;
};

char *mpv_get_property_string(void *handle, const char *name) {
    int kind = (int)(intptr_t)handle;
    // Source metadata remains 90 even when the output raster is already
    // upright. Applying this angle again produces the original regression.
    if (strcmp(name, "video-out-params/rotate")) return strdup("90");
    return strdup(kind == 2 ? "90" : kind == 3 ? "270" : "0");
}
void mpv_free(void *value) { free(value); }
void mpv_free_node_contents(node *value) {}

int mpv_command_ret(void *handle, char **args, node *result) {
    if (strcmp(args[0], "screenshot-raw") || strcmp(args[1], "video")) return -1;
    int kind = (int)(intptr_t)handle;
    int width = kind == 2 || kind == 3 ? 80 : 48;
    int height = kind == 2 || kind == 3 ? 48 : 80;
    static unsigned char pixels[48 * 80 * 4];
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            // Map the returned native raster into the upright 48x80 reference.
            int upright_x = kind == 2 ? height - y - 1 : kind == 3 ? y : x;
            int upright_y = kind == 2 ? x : kind == 3 ? width - x - 1 : y;
            int right = upright_x >= 24, bottom = upright_y >= 40;
            unsigned char *p = &pixels[(y * width + x) * 4];
            p[0] = bottom && !right ? 255 : 0;
            p[1] = right ? 255 : 0;
            p[2] = !right && !bottom || right && bottom ? 255 : 0;
            p[3] = 0;
        }
    }
    static char *keys[] = {"w", "h", "stride", "data"};
    static node values[4];
    static byte_array bytes;
    bytes = (byte_array){pixels, sizeof(pixels)};
    values[0] = (node){.u.integer = width, .format = 4};
    values[1] = (node){.u.integer = height, .format = 4};
    values[2] = (node){.u.integer = width * 4, .format = 4};
    values[3] = (node){.u.bytes = &bytes, .format = 9};
    static node_list list;
    list = (node_list){4, values, keys};
    *result = (node){.u.list = &list, .format = 8};
    return 0;
}
