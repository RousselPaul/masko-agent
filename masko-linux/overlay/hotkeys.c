#include "hotkeys.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <X11/keysym.h>

void hotkeys_init(Hotkeys *hk, Display *dpy)
{
    memset(hk, 0, sizeof(*hk));
    hk->dpy      = dpy;
    hk->root     = DefaultRootWindow(dpy);
    hk->modifier = Mod4Mask;

    hk->key_toggle   = XKeysymToKeycode(dpy, XK_m);
    hk->key_approve  = XKeysymToKeycode(dpy, XK_Return);
    hk->key_deny     = XKeysymToKeycode(dpy, XK_Escape);
    hk->key_collapse = XKeysymToKeycode(dpy, XK_l);
    hk->key_escape   = XKeysymToKeycode(dpy, XK_Escape);

    hk->key_1 = XKeysymToKeycode(dpy, XK_1);
    hk->key_2 = XKeysymToKeycode(dpy, XK_2);
    hk->key_3 = XKeysymToKeycode(dpy, XK_3);
    hk->key_4 = XKeysymToKeycode(dpy, XK_4);
    hk->key_5 = XKeysymToKeycode(dpy, XK_5);
    hk->key_6 = XKeysymToKeycode(dpy, XK_6);
    hk->key_7 = XKeysymToKeycode(dpy, XK_7);
    hk->key_8 = XKeysymToKeycode(dpy, XK_8);
    hk->key_9 = XKeysymToKeycode(dpy, XK_9);

    hk->key_up   = XKeysymToKeycode(dpy, XK_Up);
    hk->key_down = XKeysymToKeycode(dpy, XK_Down);
    hk->key_tab  = XKeysymToKeycode(dpy, XK_Tab);
}

/* Suppress BadAccess errors from XGrabKey when another app owns the combo */
static int grab_error_occurred = 0;
static int grab_error_handler(Display *dpy, XErrorEvent *ev)
{
    (void)dpy;
    if (ev->error_code == BadAccess)
        grab_error_occurred = 1;
    return 0;
}

/* Grab a single key with all NumLock/CapsLock combos */
static void grab_key(Display *dpy, Window root, KeyCode key, unsigned int mod)
{
    unsigned int lock_masks[] = { 0, LockMask, Mod2Mask, LockMask | Mod2Mask };
    XErrorHandler old = XSetErrorHandler(grab_error_handler);
    for (int i = 0; i < 4; i++) {
        grab_error_occurred = 0;
        XGrabKey(dpy, key, mod | lock_masks[i], root, True,
                 GrabModeAsync, GrabModeAsync);
        XSync(dpy, False);
        if (grab_error_occurred)
            fprintf(stderr, "masko-overlay: could not grab key (already taken), skipping\n");
    }
    XSetErrorHandler(old);
}

static void ungrab_key(Display *dpy, Window root, KeyCode key, unsigned int mod)
{
    unsigned int lock_masks[] = { 0, LockMask, Mod2Mask, LockMask | Mod2Mask };
    for (int i = 0; i < 4; i++) {
        XUngrabKey(dpy, key, mod | lock_masks[i], root);
    }
}

void hotkeys_grab(Hotkeys *hk)
{
    unsigned int mod = hk->modifier;

    grab_key(hk->dpy, hk->root, hk->key_toggle,   mod);
    grab_key(hk->dpy, hk->root, hk->key_approve,  mod);
    grab_key(hk->dpy, hk->root, hk->key_deny,     mod);
    grab_key(hk->dpy, hk->root, hk->key_collapse, mod);

    /* Skip grabbing bare Escape — DEs use it, and the overlay receives
       Escape via its own window's KeyPress events anyway */

    /* Super+1 through Super+9 */
    KeyCode numkeys[] = {
        hk->key_1, hk->key_2, hk->key_3, hk->key_4, hk->key_5,
        hk->key_6, hk->key_7, hk->key_8, hk->key_9,
    };
    for (int i = 0; i < 9; i++)
        grab_key(hk->dpy, hk->root, numkeys[i], mod);

    /* Super+Up/Down/Tab, Super+Shift+Tab */
    grab_key(hk->dpy, hk->root, hk->key_up,  mod);
    grab_key(hk->dpy, hk->root, hk->key_down, mod);
    grab_key(hk->dpy, hk->root, hk->key_tab, mod);
    grab_key(hk->dpy, hk->root, hk->key_tab, mod | ShiftMask);

    XFlush(hk->dpy);
}

void hotkeys_ungrab(Hotkeys *hk)
{
    unsigned int mod = hk->modifier;

    ungrab_key(hk->dpy, hk->root, hk->key_toggle,   mod);
    ungrab_key(hk->dpy, hk->root, hk->key_approve,  mod);
    ungrab_key(hk->dpy, hk->root, hk->key_deny,     mod);
    ungrab_key(hk->dpy, hk->root, hk->key_collapse, mod);
    /* bare Escape not grabbed, nothing to ungrab */

    KeyCode numkeys[] = {
        hk->key_1, hk->key_2, hk->key_3, hk->key_4, hk->key_5,
        hk->key_6, hk->key_7, hk->key_8, hk->key_9,
    };
    for (int i = 0; i < 9; i++)
        ungrab_key(hk->dpy, hk->root, numkeys[i], mod);

    ungrab_key(hk->dpy, hk->root, hk->key_up,  mod);
    ungrab_key(hk->dpy, hk->root, hk->key_down, mod);
    ungrab_key(hk->dpy, hk->root, hk->key_tab, mod);
    ungrab_key(hk->dpy, hk->root, hk->key_tab, mod | ShiftMask);

    XFlush(hk->dpy);
}

/* Strip NumLock and CapsLock from state for clean comparison */
static unsigned int clean_mods(unsigned int state)
{
    return state & ~(LockMask | Mod2Mask);
}

char *hotkeys_handle(Hotkeys *hk, XKeyEvent *ev)
{
    KeyCode kc = ev->keycode;
    unsigned int mods = clean_mods(ev->state);
    unsigned int super = hk->modifier;

    /* Escape without modifier -> dismiss */
    if (kc == hk->key_escape && mods == 0)
        return strdup("dismiss");

    /* Super + key bindings */
    if (mods == super) {
        if (kc == hk->key_toggle)   return strdup("toggle");
        if (kc == hk->key_approve)  return strdup("approve");
        if (kc == hk->key_collapse) return strdup("collapse");
        if (kc == hk->key_up)       return strdup("session_nav_prev");
        if (kc == hk->key_down)     return strdup("session_nav_next");
        if (kc == hk->key_tab)      return strdup("session_nav_next");

        /* Super+Escape -> deny (key_deny and key_escape share the same keycode) */
        if (kc == hk->key_deny)     return strdup("deny");

        /* Session number keys */
        KeyCode numkeys[] = {
            hk->key_1, hk->key_2, hk->key_3, hk->key_4, hk->key_5,
            hk->key_6, hk->key_7, hk->key_8, hk->key_9,
        };
        for (int i = 0; i < 9; i++) {
            if (kc == numkeys[i]) {
                char buf[16];
                snprintf(buf, sizeof(buf), "session_%d", i + 1);
                return strdup(buf);
            }
        }
    }

    /* Super+Shift+Tab -> prev */
    if (mods == (super | ShiftMask) && kc == hk->key_tab)
        return strdup("session_nav_prev");

    return NULL;
}
