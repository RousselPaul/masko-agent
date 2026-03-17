#include "window.h"
#include "ipc.h"
#include "video.h"
#include "card_stack.h"
#include "render.h"
#include "permission_ui.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/time.h>
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

typedef struct {
    int active;
    int start_mouse_x, start_mouse_y;
    int start_win_x, start_win_y;
} DragState;

typedef struct {
    MaskoVideo video;
    int is_playing;
    int is_looping;
    double fps;
    struct timeval last_frame_time;
} PlaybackState;

static double elapsed_ms(struct timeval *from, struct timeval *to)
{
    return (to->tv_sec - from->tv_sec) * 1000.0
         + (to->tv_usec - from->tv_usec) / 1000.0;
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

static void render_video_frame(MaskoWindow *w, PlaybackState *ps)
{
    cairo_surface_t *frame = masko_video_next_frame(&ps->video);
    if (!frame) {
        if (ps->is_looping) {
            masko_video_rewind(&ps->video);
            frame = masko_video_next_frame(&ps->video);
        }
        if (!frame) {
            ps->is_playing = 0;
            return;
        }
    }

    cairo_t *cr = masko_window_back_cr(w);

    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);

    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    double sx = (double)w->width  / ps->video.width;
    double sy = (double)w->height / ps->video.height;
    cairo_scale(cr, sx, sy);
    cairo_set_source_surface(cr, frame, 0, 0);
    cairo_paint(cr);

    /* Reset transform so future draws aren't scaled */
    cairo_identity_matrix(cr);

    masko_window_flip(w);
    gettimeofday(&ps->last_frame_time, NULL);
}

static void stop_playback(PlaybackState *ps)
{
    if (ps->is_playing) {
        ps->is_playing = 0;
        masko_video_close(&ps->video);
    }
}

static void handle_ipc_message(MaskoWindow *w, PlaybackState *ps,
                               CardStack *cards, PermissionUI *perm,
                               cJSON *msg)
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
            if (!ps->is_playing)
                draw_placeholder(w);
        }
    } else if (strcmp(c, "play") == 0) {
        cJSON *jvideo = cJSON_GetObjectItem(msg, "video");
        if (!jvideo || !cJSON_IsString(jvideo)) return;

        stop_playback(ps);

        if (masko_video_open(&ps->video, jvideo->valuestring) < 0) {
            fprintf(stderr, "masko-overlay: failed to open video: %s\n",
                    jvideo->valuestring);
            return;
        }

        cJSON *jloop = cJSON_GetObjectItem(msg, "loop");
        ps->is_looping = (jloop && cJSON_IsTrue(jloop)) ? 1 : 0;
        ps->fps = masko_video_fps(&ps->video);
        ps->is_playing = 1;
        gettimeofday(&ps->last_frame_time, NULL);

        render_video_frame(w, ps);
    } else if (strcmp(c, "stop") == 0) {
        stop_playback(ps);
        draw_placeholder(w);
    } else if (strcmp(c, "permission") == 0) {
        cJSON *jtool  = cJSON_GetObjectItem(msg, "tool");
        cJSON *jinput = cJSON_GetObjectItem(msg, "input");
        cJSON *jid    = cJSON_GetObjectItem(msg, "id");
        if (!jtool || !jinput || !jid) return;

        permission_ui_show(perm,
            cJSON_IsString(jtool)  ? jtool->valuestring  : "",
            cJSON_IsString(jinput) ? jinput->valuestring : "",
            cJSON_IsString(jid)    ? jid->valuestring    : "");
        card_stack_push(cards, CARD_PERMISSION);
    } else if (strcmp(c, "dismiss_permission") == 0) {
        permission_ui_hide(perm);
        card_stack_pop(cards, CARD_PERMISSION);
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
    PlaybackState playback = {0};
    CardStack cards;
    PermissionUI perm;
    card_stack_init(&cards);
    permission_ui_init(&perm);
    int need_redraw = 0;
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

        /* Short timeout when playing video to hit frame deadlines */
        long timeout_us = 100000;
        if (playback.is_playing) {
            double frame_ms = 1000.0 / playback.fps;
            struct timeval now;
            gettimeofday(&now, NULL);
            double wait = frame_ms - elapsed_ms(&playback.last_frame_time, &now);
            if (wait < 1.0) wait = 1.0;
            timeout_us = (long)(wait * 1000);
        }

        struct timeval tv = {
            .tv_sec  = timeout_us / 1000000,
            .tv_usec = timeout_us % 1000000,
        };
        select(maxfd + 1, &rfds, NULL, NULL, &tv);

        /* Process all pending X11 events */
        while (XPending(win.dpy)) {
            XEvent ev;
            XNextEvent(win.dpy, &ev);

            switch (ev.type) {
            case Expose:
                need_redraw = 1;
                break;

            case ButtonPress:
                if (ev.xbutton.button == 1) {
                    int hit = permission_ui_hit_test(&perm,
                                  ev.xbutton.x, ev.xbutton.y);
                    if (hit) {
                        const char *action = (hit == 1) ? "approve" : "deny";
                        if (ipc_connected) {
                            cJSON *resp = cJSON_CreateObject();
                            cJSON_AddStringToObject(resp, "event", "permission_response");
                            cJSON_AddStringToObject(resp, "id", perm.perm_id);
                            cJSON_AddStringToObject(resp, "action", action);
                            masko_ipc_send(&ipc, resp);
                            cJSON_Delete(resp);
                        }
                        permission_ui_hide(&perm);
                        card_stack_pop(&cards, CARD_PERMISSION);
                        need_redraw = 1;
                    } else {
                        drag.active = 1;
                        drag.start_mouse_x = ev.xbutton.x_root;
                        drag.start_mouse_y = ev.xbutton.y_root;
                        drag.start_win_x   = win.x;
                        drag.start_win_y   = win.y;
                    }
                }
                break;

            case MotionNotify:
                if (drag.active) {
                    int nx = drag.start_win_x + (ev.xmotion.x_root - drag.start_mouse_x);
                    int ny = drag.start_win_y + (ev.xmotion.y_root - drag.start_mouse_y);
                    masko_window_move(&win, nx, ny);
                } else if (perm.visible) {
                    permission_ui_hover(&perm, ev.xmotion.x, ev.xmotion.y);
                    need_redraw = 1;
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
                handle_ipc_message(&win, &playback, &cards, &perm, msg);
                need_redraw = 1;
                cJSON_Delete(msg);
            }
        }

        /* Advance video frame when it's time */
        if (playback.is_playing) {
            struct timeval now;
            gettimeofday(&now, NULL);
            double frame_ms = 1000.0 / playback.fps;
            if (elapsed_ms(&playback.last_frame_time, &now) >= frame_ms) {
                render_video_frame(&win, &playback);
                need_redraw = 1;
            }
        }

        if (need_redraw) {
            need_redraw = 0;

            /* Base content (already drawn if video frame just advanced) */
            if (!playback.is_playing)
                draw_placeholder(&win);

            /* Permission UI overlays on top of base content */
            if (perm.visible) {
                cairo_t *cr = masko_window_back_cr(&win);
                permission_ui_draw(&perm, cr, win.width, win.height);
                masko_window_flip(&win);
            }
        }
    }

    stop_playback(&playback);
    if (ipc_connected)
        masko_ipc_disconnect(&ipc);
    masko_window_destroy(&win);
    return 0;
}
