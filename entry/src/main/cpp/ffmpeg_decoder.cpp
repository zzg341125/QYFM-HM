#include "napi/native_api.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
}

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr uint64_t kDecoderMagic = 0x5159464d46464d50ULL;
constexpr int kOutputSampleRate = 48000;
constexpr int kOutputChannels = 2;
constexpr int kBytesPerSample = 4;

struct FfmpegDecoder {
    uint64_t magic = kDecoderMagic;
    const AVCodec *codec = nullptr;
    AVCodecContext *codecContext = nullptr;
    AVCodecParserContext *parser = nullptr;
    AVPacket *packet = nullptr;
    AVFrame *frame = nullptr;
    SwrContext *resampler = nullptr;
    int lastError = 0;
};

bool IsValid(FfmpegDecoder *decoder)
{
    return decoder != nullptr && decoder->magic == kDecoderMagic;
}

std::string ErrorText(int error)
{
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
    av_strerror(error, buffer, sizeof(buffer));
    return buffer;
}

void SetNamedError(napi_env env, const char *code, const std::string &message)
{
    napi_throw_error(env, code, message.c_str());
}

bool ConfigureResampler(FfmpegDecoder *decoder, const AVFrame *frame)
{
    if (decoder->resampler != nullptr) {
        return true;
    }

    AVChannelLayout inputLayout = {};
    if (frame->ch_layout.nb_channels > 0) {
        int ret = av_channel_layout_copy(&inputLayout, &frame->ch_layout);
        if (ret < 0) {
            decoder->lastError = ret;
            return false;
        }
    } else {
        av_channel_layout_default(&inputLayout, 2);
    }

    AVChannelLayout outputLayout = AV_CHANNEL_LAYOUT_STEREO;
    int ret = swr_alloc_set_opts2(
        &decoder->resampler,
        &outputLayout,
        AV_SAMPLE_FMT_FLT,
        kOutputSampleRate,
        &inputLayout,
        static_cast<AVSampleFormat>(frame->format),
        frame->sample_rate,
        0,
        nullptr
    );
    av_channel_layout_uninit(&inputLayout);
    if (ret < 0 || decoder->resampler == nullptr) {
        decoder->lastError = ret;
        return false;
    }
    ret = swr_init(decoder->resampler);
    if (ret < 0) {
        decoder->lastError = ret;
        return false;
    }
    return true;
}

bool AppendFramePcm(FfmpegDecoder *decoder, std::vector<uint8_t> &pcm)
{
    if (!ConfigureResampler(decoder, decoder->frame)) {
        return false;
    }

    int64_t delay = swr_get_delay(decoder->resampler, decoder->frame->sample_rate);
    int outputCapacity = static_cast<int>(av_rescale_rnd(
        delay + decoder->frame->nb_samples,
        kOutputSampleRate,
        decoder->frame->sample_rate,
        AV_ROUND_UP
    ));
    if (outputCapacity <= 0) {
        return true;
    }

    size_t oldSize = pcm.size();
    size_t bytesToAdd = static_cast<size_t>(outputCapacity) *
        kOutputChannels * kBytesPerSample;
    pcm.resize(oldSize + bytesToAdd);
    uint8_t *outputPlanes[1] = {pcm.data() + oldSize};
    int converted = swr_convert(
        decoder->resampler,
        outputPlanes,
        outputCapacity,
        const_cast<const uint8_t **>(decoder->frame->extended_data),
        decoder->frame->nb_samples
    );
    if (converted < 0) {
        decoder->lastError = converted;
        pcm.resize(oldSize);
        return false;
    }
    pcm.resize(oldSize + static_cast<size_t>(converted) *
        kOutputChannels * kBytesPerSample);
    return true;
}

bool ReceiveFrames(FfmpegDecoder *decoder, std::vector<uint8_t> &pcm)
{
    while (true) {
        int ret = avcodec_receive_frame(decoder->codecContext, decoder->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            return true;
        }
        if (ret < 0) {
            decoder->lastError = ret;
            return false;
        }
        bool appended = AppendFramePcm(decoder, pcm);
        av_frame_unref(decoder->frame);
        if (!appended) {
            return false;
        }
    }
}

bool SendPacket(FfmpegDecoder *decoder, std::vector<uint8_t> &pcm)
{
    int ret = avcodec_send_packet(decoder->codecContext, decoder->packet);
    av_packet_unref(decoder->packet);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
        decoder->lastError = ret;
        return false;
    }
    return ReceiveFrames(decoder, pcm);
}

napi_value CreateDecoder(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char codecHint[32] = {};
    size_t hintLength = 0;
    if (argc > 0) {
        napi_get_value_string_utf8(env, args[0], codecHint, sizeof(codecHint), &hintLength);
    }

    AVCodecID codecId = AV_CODEC_ID_MP3;
    if (std::strcmp(codecHint, "aac") == 0) {
        codecId = AV_CODEC_ID_AAC;
    } else if (std::strcmp(codecHint, "aac_latm") == 0) {
        codecId = AV_CODEC_ID_AAC_LATM;
    }

    const AVCodec *codec = avcodec_find_decoder(codecId);
    if (codec == nullptr) {
        SetNamedError(env, "CODEC_NOT_FOUND", "FFmpeg decoder is unavailable");
        return nullptr;
    }

    auto *decoder = new FfmpegDecoder();
    decoder->codec = codec;
    decoder->codecContext = avcodec_alloc_context3(codec);
    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    decoder->parser = av_parser_init(codecId);
    if (decoder->codecContext == nullptr || decoder->packet == nullptr ||
        decoder->frame == nullptr || decoder->parser == nullptr) {
        SetNamedError(env, "ALLOCATION_FAILED", "Unable to allocate FFmpeg decoder");
        return nullptr;
    }

    decoder->codecContext->thread_count = 0;
    int ret = avcodec_open2(decoder->codecContext, codec, nullptr);
    if (ret < 0) {
        decoder->lastError = ret;
        SetNamedError(env, "OPEN_FAILED", "FFmpeg decoder open failed: " + ErrorText(ret));
        return nullptr;
    }

    napi_value result;
    napi_create_double(env, static_cast<double>(reinterpret_cast<uintptr_t>(decoder)), &result);
    return result;
}

bool ReadHandle(napi_env env, napi_value value, FfmpegDecoder **decoder)
{
    double raw = 0;
    if (napi_get_value_double(env, value, &raw) != napi_ok) {
        return false;
    }
    *decoder = reinterpret_cast<FfmpegDecoder *>(static_cast<uintptr_t>(raw));
    return IsValid(*decoder);
}

napi_value Decode(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    FfmpegDecoder *decoder = nullptr;
    if (argc < 2 || !ReadHandle(env, args[0], &decoder)) {
        SetNamedError(env, "INVALID_HANDLE", "Invalid FFmpeg decoder handle");
        return nullptr;
    }

    void *input = nullptr;
    size_t inputSize = 0;
    if (napi_get_arraybuffer_info(env, args[1], &input, &inputSize) != napi_ok) {
        SetNamedError(env, "INVALID_INPUT", "Decoder input must be an ArrayBuffer");
        return nullptr;
    }
    bool flush = false;
    if (argc > 2) {
        napi_get_value_bool(env, args[2], &flush);
    }

    std::vector<uint8_t> pcm;
    const uint8_t *data = static_cast<const uint8_t *>(input);
    size_t remaining = inputSize;
    if (!flush) {
        while (remaining > 0) {
            int consumed = av_parser_parse2(
                decoder->parser,
                decoder->codecContext,
                &decoder->packet->data,
                &decoder->packet->size,
                data,
                static_cast<int>(remaining),
                AV_NOPTS_VALUE,
                AV_NOPTS_VALUE,
                0
            );
            if (consumed < 0) {
                decoder->lastError = consumed;
                SetNamedError(env, "PARSE_FAILED", "FFmpeg parser failed: " + ErrorText(consumed));
                return nullptr;
            }
            data += consumed;
            remaining -= static_cast<size_t>(consumed);
            if (decoder->packet->size > 0 && !SendPacket(decoder, pcm)) {
                SetNamedError(
                    env,
                    "DECODE_FAILED",
                    "FFmpeg decode failed: " + ErrorText(decoder->lastError)
                );
                return nullptr;
            }
            if (consumed == 0) {
                break;
            }
        }
    } else {
        avcodec_send_packet(decoder->codecContext, nullptr);
        if (!ReceiveFrames(decoder, pcm)) {
            SetNamedError(
                env,
                "DECODE_FAILED",
                "FFmpeg flush failed: " + ErrorText(decoder->lastError)
            );
            return nullptr;
        }
    }

    napi_value result;
    void *outputData = nullptr;
    napi_create_arraybuffer(env, pcm.size(), &outputData, &result);
    if (!pcm.empty()) {
        std::memcpy(outputData, pcm.data(), pcm.size());
    }
    return result;
}

napi_value LastError(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    FfmpegDecoder *decoder = nullptr;
    if (argc < 1 || !ReadHandle(env, args[0], &decoder)) {
        napi_create_int32(env, 0, &args[0]);
        return args[0];
    }
    napi_value result;
    napi_create_int32(env, decoder->lastError, &result);
    return result;
}

napi_value DestroyDecoder(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    FfmpegDecoder *decoder = nullptr;
    if (argc < 1 || !ReadHandle(env, args[0], &decoder)) {
        return nullptr;
    }
    decoder->magic = 0;
    if (decoder->resampler != nullptr) {
        swr_free(&decoder->resampler);
    }
    if (decoder->parser != nullptr) {
        av_parser_close(decoder->parser);
    }
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->packet);
    avcodec_free_context(&decoder->codecContext);
    delete decoder;
    return nullptr;
}

napi_value OutputSampleRate(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_create_int32(env, kOutputSampleRate, &result);
    return result;
}

napi_value OutputChannels(napi_env env, napi_callback_info info)
{
    napi_value result;
    napi_create_int32(env, kOutputChannels, &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"createDecoder", nullptr, CreateDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"decode", nullptr, Decode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"destroyDecoder", nullptr, DestroyDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"lastError", nullptr, LastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"outputSampleRate", nullptr, OutputSampleRate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"outputChannels", nullptr, OutputChannels, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(
        env,
        exports,
        sizeof(descriptors) / sizeof(descriptors[0]),
        descriptors
    );
    return exports;
}

} // namespace

static napi_module qyfmFfmpegModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "qyfm_ffmpeg",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterQyfmFfmpegModule()
{
    napi_module_register(&qyfmFfmpegModule);
}
