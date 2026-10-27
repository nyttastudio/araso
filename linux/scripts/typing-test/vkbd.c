// Types on Wayland as a real keyboard does: the US keymap and each key's evdev code (wtype makes up
// a keymap of its own, which Araso, reading keys by where they are, can't take for a keyboard).
//   vkbd 'text'   characters as on a US keyboard; {Hangul} {Return} {AltR} {CtrlR} keys by name
#define _GNU_SOURCE
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (!strcmp(interface, wl_seat_interface.name)) seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    if (!strcmp(interface, zwp_virtual_keyboard_manager_v1_interface.name))
        manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener listener = {global, global_remove};

static struct wl_display *display;
static struct zwp_virtual_keyboard_v1 *keyboard;
static uint32_t ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000 + t.tv_nsec / 1000000; }

static void key(int code, int shift) {
    if (shift) zwp_virtual_keyboard_v1_modifiers(keyboard, 1, 0, 0, 0);
    zwp_virtual_keyboard_v1_key(keyboard, ms(), code, 1);
    wl_display_roundtrip(display);
    usleep(20000);
    zwp_virtual_keyboard_v1_key(keyboard, ms(), code, 0);
    if (shift) zwp_virtual_keyboard_v1_modifiers(keyboard, 0, 0, 0, 0);
    wl_display_roundtrip(display);
    usleep(60000);
}

static int us(char c, int *shift) {
    static const char *rows[] = {"1234567890-=", "qwertyuiop[]", "asdfghjkl;'`", "zxcvbnm,./"};
    static const char *shifted[] = {"!@#$%^&*()_+", "QWERTYUIOP{}", "ASDFGHJKL:\"~", "ZXCVBNM<>?"};
    static const int first[] = {2, 16, 30, 44};
    *shift = 0;
    if (c == ' ') return 57;
    for (int r = 0; r < 4; r++)
        for (int i = 0; rows[r][i]; i++) {
            if (rows[r][i] == c) return first[r] + i;
            if (shifted[r][i] == c) { *shift = 1; return first[r] + i; }
        }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "no Wayland display\n"); return 1; }
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &listener, NULL);
    wl_display_roundtrip(display);
    if (!seat || !manager) { fprintf(stderr, "no virtual keyboard support\n"); return 1; }
    keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_rule_names names = {"evdev", "pc105", "us", "", ""};
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(text) + 1;
    int fd = memfd_create("keymap", 0);
    ftruncate(fd, size);
    char *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    memcpy(map, text, size);
    zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
    wl_display_roundtrip(display);
    usleep(200000);
    for (const char *p = argv[1]; *p; p++) {
        if (*p == '{') {
            const char *end = strchr(p, '}');
            if (!end) break;
            int code = !strncmp(p, "{Hangul}", 8) ? 122 : !strncmp(p, "{Return}", 8) ? 28
                     : !strncmp(p, "{AltR}", 6) ? 100 : !strncmp(p, "{CtrlR}", 7) ? 97 : 0;
            if (code) key(code, 0);
            p = end;
            continue;
        }
        int shift, code = us(*p, &shift);
        if (code) key(code, shift);
    }
    wl_display_roundtrip(display);
    return 0;
}
