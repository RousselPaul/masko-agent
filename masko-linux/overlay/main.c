#include "window.h"
#include "ipc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/select.h>
#include <X11/Xlib.h>
#include <cairo/cairo.h>
#include <cjson/cJSON.h>

static volatile sig_atomic_t running = 1;

static void on_signal(int sig)
{
    (void)sig;
    running = 0;
}

static void draw_placeholder(MaskoWindow *w)
{
    cairo_t *cr = masko_window_back_cr(w);

    /* Clear to fully transparent */
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);

    /* Blue circle as placeholder content */
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    double cx = w->width  / 2.0;
    double cy = w->height / 2.0;
    double r  = (w->width < w->height ? w->width : w->height) / 2.0 - 4.0;
    cairo_arc(cr, cx, cy, r, 0, 2 * 3.14159265);
    cairo_set_source_rgba(cr, 0.2, 0.4, 0.9, 0.85);
    cairo_fill(cr);

    masko_window_flip(w);
}

static void handle_ipc_message(MaskoWindow *w, cJSON *msg)
{
    cJSON *cmd = cJSON_GetObjectItem(msg, "cmd");
    if (!cmd || !cJSON_IsString(cmd)) return;

    const char *c = cmd->valuestring;

    if (strcmp(c, "show") == 0) {
        masko_window_show(w);
    } else if (strcmp(c, "hide") == 0) {
        masko_window_hide(w);
    } else if (strcmp(c, "move") == 0) {
        cJSON *jx = cJSON_GetObjectItem(msg, "x");
        cJSON *jy = cJSON_GetObjectItem(msg, "y");
        if (jx && jy)
            masko_window_move(w, jx->valueint, jy->valueint);
    } else if (strcmp(c, "resize") == 0) {
        cJSON *jw = cJSON_GetObjectItem(msg, "width");
        cJSON *jh = cJSON_GetObjectItem(msg, "height");
        if (jw && jh) {
            masko_window_resize(w, jw->valueint, jh->valueint);
            draw_placeholder(w);
        }
    }
}

static void send_position_event(MaskoIPC *ipc, int x, int y)
{
    cJSON *msg = cJSON_CreateObject();
    cJSON_AddStringToObject(msg, "event", "position");
    cJSON_AddNumberToObject(msg, "x", x);
    cJSON_AddNumberToObject(msg, "y", y);
    masko_ipc_send(ipc, msg);
    cJSON_Delete(msg);
}

typedef struct {
    int active;
    int start_mouse_x, start_mouse_y;
    int start_win_x, start_win_y;
} DragState;

int main(int argc, char **argv)
{
    int test_mode = 0;
    const char *sock_path = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test-mode") == 0) {
            test_mode = 1;
        } else if (strcmp(argv[i], "--sock") == 0 && i + 1 < argc) {
            sock_path = argv[++i];
        }
    }

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);

    MaskoWindow win;
    if (masko_window_init(&win, 100, 100, 200, 200) < 0)
        return 1;

    masko_window_show(&win);
    draw_placeholder(&win);

    MaskoIPC ipc;
    int ipc_connected = 0;

    if (!test_mode && sock_path) {
        if (masko_ipc_connect(&ipc, sock_path) == 0) {
            ipc_connected = 1;
            cJSON *ready = cJSON_CreateObject();
            cJSON_AddStringToObject(ready, "event", "ready");
            masko_ipc_send(&ipc, ready);
            cJSON_Delete(ready);
        } else {
            fprintf(stderr, "masko-overlay: IPC connect failed, running without IPC\n");
        }
    }

    DragState drag = {0};
    int iterations = 0;

    while (running) {
        if (test_mode && ++iterations > 50)
            break;

        fd_set rfds;
        FD_ZERO(&rfds);

        int x11_fd = masko_window_fd(&win);
        FD_SET(x11_fd, &rfds);
        int maxfd = x11_fd;

        if (ipc_connected) {
            int ipc_fd = masko_ipc_fd(&ipc);
            FD_SET(ipc_fd, &rfds);
            if (ipc_fd > maxfd) maxfd = ipc_fd;
        }

        struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
        select(maxfd + 1, &rfds, NULL, NULL, &tv);

        /* Process all pending X11 events */
        while (XPending(win.dpy)) {
            XEvent ev;
            XNextEvent(win.dpy, &ev);

            switch (ev.type) {
            case Expose:
                draw_placeholder(&win);
                break;

            case ButtonPress:
                if (ev.xbutton.button == 1) {
                    drag.active = 1;
                    drag.start_mouse_x = ev.xbutton.x_root;
                    drag.start_mouse_y = ev.xbutton.y_root;
                    drag.start_win_x   = win.x;
                    drag.start_win_y   = win.y;
                }
                break;

            case MotionNotify:
                if (drag.active) {
                    int nx = drag.start_win_x + (ev.xmotion.x_root - drag.start_mouse_x);
                    int ny = drag.start_win_y + (ev.xmotion.y_root - drag.start_mouse_y);
                    masko_window_move(&win, nx, ny);
                }
                break;

            case ButtonRelease:
                if (ev.xbutton.button == 1 && drag.active) {
                    drag.active = 0;
                    if (ipc_connected)
                        send_position_event(&ipc, win.x, win.y);
                }
                break;
            }
        }

        /* Process IPC messages */
        if (ipc_connected) {
            cJSON *msg;
            while ((msg = masko_ipc_recv(&ipc)) != NULL) {
                handle_ipc_message(&win, msg);
                cJSON_Delete(msg);
            }
        }
    }

    if (ipc_connected)
        masko_ipc_disconnect(&ipc);
    masko_window_destroy(&win);
    return 0;
}
