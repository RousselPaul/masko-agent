#ifndef MASKO_HOTKEYS_H
#define MASKO_HOTKEYS_H

#include <X11/Xlib.h>

typedef struct {
    Display *dpy;
    Window root;
    unsigned int modifier; /* Mod4Mask (Super) */

    KeyCode key_toggle;    /* Super+M */
    KeyCode key_approve;   /* Super+Return */
    KeyCode key_deny;      /* Super+Escape */
    KeyCode key_collapse;  /* Super+L */
    KeyCode key_escape;    /* Escape (no modifier) */
    KeyCode key_1, key_2, key_3, key_4, key_5;
    KeyCode key_6, key_7, key_8, key_9;
    KeyCode key_up, key_down, key_tab;
} Hotkeys;

void  hotkeys_init(Hotkeys *hk, Display *dpy);
void  hotkeys_grab(Hotkeys *hk);
void  hotkeys_ungrab(Hotkeys *hk);

/* Returns action string or NULL. Caller must free().
   Actions: "toggle", "approve", "deny", "collapse", "dismiss",
            "session_1" through "session_9",
            "session_nav_next", "session_nav_prev" */
char *hotkeys_handle(Hotkeys *hk, XKeyEvent *ev);

#endif
