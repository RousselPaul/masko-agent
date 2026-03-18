#include "video.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavutil/imgutils.h>

int masko_video_open(MaskoVideo *v, const char *path)
{
    memset(v, 0, sizeof(*v));

    if (avformat_open_input(&v->fmt_ctx, path, NULL, NULL) < 0) {
        fprintf(stderr, "Cannot open video: %s\n", path);
        return -1;
    }
    if (avformat_find_stream_info(v->fmt_ctx, NULL) < 0) {
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    v->stream_idx = -1;
    for (unsigned i = 0; i < v->fmt_ctx->nb_streams; i++) {
        if (v->fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            v->stream_idx = i;
            break;
        }
    }
    if (v->stream_idx < 0) {
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    AVCodecParameters *par = v->fmt_ctx->streams[v->stream_idx]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) {
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    v->codec_ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(v->codec_ctx, par);
    if (avcodec_open2(v->codec_ctx, codec, NULL) < 0) {
        avcodec_free_context(&v->codec_ctx);
        avformat_close_input(&v->fmt_ctx);
        return -1;
    }

    v->width = par->width;
    v->height = par->height;
    v->frame = av_frame_alloc();
    v->frame_rgba = av_frame_alloc();
    v->pkt = av_packet_alloc();

    int buf_size = av_image_get_buffer_size(AV_PIX_FMT_BGRA, v->width, v->height, 1);
    v->rgba_buf = av_malloc(buf_size);
    av_image_fill_arrays(v->frame_rgba->data, v->frame_rgba->linesize,
                         v->rgba_buf, AV_PIX_FMT_BGRA, v->width, v->height, 1);

    v->sws_ctx = sws_getContext(v->width, v->height, v->codec_ctx->pix_fmt,
                                 v->width, v->height, AV_PIX_FMT_BGRA,
                                 SWS_BILINEAR, NULL, NULL, NULL);

    v->surface = cairo_image_surface_create_for_data(
        v->rgba_buf, CAIRO_FORMAT_ARGB32, v->width, v->height,
        v->frame_rgba->linesize[0]
    );
    v->finished = 0;

    return 0;
}

cairo_surface_t *masko_video_next_frame(MaskoVideo *v)
{
    while (1) {
        int ret = av_read_frame(v->fmt_ctx, v->pkt);
        if (ret < 0) {
            v->finished = 1;
            return NULL;
        }
        if (v->pkt->stream_index != v->stream_idx) {
            av_packet_unref(v->pkt);
            continue;
        }

        avcodec_send_packet(v->codec_ctx, v->pkt);
        av_packet_unref(v->pkt);

        ret = avcodec_receive_frame(v->codec_ctx, v->frame);
        if (ret == 0) {
            sws_scale(v->sws_ctx, (const uint8_t *const *)v->frame->data,
                      v->frame->linesize, 0, v->height,
                      v->frame_rgba->data, v->frame_rgba->linesize);

            /* Chroma-key: the mascot videos have a light blue background
               (approx R=160 G=212 B=224) baked in as opaque pixels.
               Make those pixels transparent so the mascot floats. */
            int stride = v->frame_rgba->linesize[0];
            for (int y = 0; y < v->height; y++) {
                uint8_t *row = v->rgba_buf + y * stride;
                for (int x = 0; x < v->width; x++) {
                    uint8_t b = row[x * 4 + 0];
                    uint8_t g = row[x * 4 + 1];
                    uint8_t r = row[x * 4 + 2];
                    int dr = (int)r - 160;
                    int dg = (int)g - 212;
                    int db = (int)b - 224;
                    int dist_sq = dr * dr + dg * dg + db * db;
                    /* Hard cutoff with soft edge for anti-aliasing */
                    if (dist_sq < 900) {
                        row[x * 4 + 3] = 0; /* fully transparent */
                    } else if (dist_sq < 2500) {
                        /* Fade alpha near the boundary for smooth edges */
                        float t = (float)(dist_sq - 900) / 1600.0f;
                        row[x * 4 + 3] = (uint8_t)(t * 255.0f);
                        /* Pre-multiply alpha for Cairo ARGB32 */
                        float a = t;
                        row[x * 4 + 0] = (uint8_t)(row[x * 4 + 0] * a);
                        row[x * 4 + 1] = (uint8_t)(row[x * 4 + 1] * a);
                        row[x * 4 + 2] = (uint8_t)(row[x * 4 + 2] * a);
                    }
                }
            }

            cairo_surface_mark_dirty(v->surface);
            return v->surface;
        }
    }
}

void masko_video_rewind(MaskoVideo *v)
{
    av_seek_frame(v->fmt_ctx, v->stream_idx, 0, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(v->codec_ctx);
    v->finished = 0;
}

double masko_video_fps(MaskoVideo *v)
{
    AVRational r = v->fmt_ctx->streams[v->stream_idx]->avg_frame_rate;
    if (r.den == 0) return 30.0;
    return (double)r.num / r.den;
}

void masko_video_close(MaskoVideo *v)
{
    if (v->surface)    cairo_surface_destroy(v->surface);
    if (v->sws_ctx)    sws_freeContext(v->sws_ctx);
    if (v->rgba_buf)   av_free(v->rgba_buf);
    if (v->frame)      av_frame_free(&v->frame);
    if (v->frame_rgba) av_frame_free(&v->frame_rgba);
    if (v->pkt)        av_packet_free(&v->pkt);
    if (v->codec_ctx)  avcodec_free_context(&v->codec_ctx);
    if (v->fmt_ctx)    avformat_close_input(&v->fmt_ctx);
}
