"""用 ffmpeg 做一批「不太标准」的音频文件（Telegram 上常见的那种），
看泡泡音能不能测响度、能不能顺利放完。

用法：python3 make_problem_files.py 输出文件夹
写出各种文件和 expected.json：{ "文件名": {"ffmpeg_lufs": ... 或 null, "mono": bool, "note": "..."} }
ffmpeg_lufs 是 ffmpeg 自己能解码的部分测出来的响度，当参考答案。
"""
import json
import os
import re
import subprocess
import sys


def ff(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def lufs(path, mono):
    out = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af",
                          f"ebur128=dualmono={'true' if mono else 'false'}", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    m = re.findall(r"I:\s+(-?[\d.]+) LUFS", out)
    return float(m[-1]) if m else None


def truncate(src, dst, fraction):
    data = open(src, "rb").read()
    open(dst, "wb").write(data[: int(len(data) * fraction)])


def main(out):
    os.makedirs(out, exist_ok=True)
    os.chdir(out)
    notes = {}

    # 40 秒「像音乐」的立体声：粉红噪声 + 一个音，音量一会儿大一会儿小
    music = ("anoisesrc=d=40:c=pink:a=0.3:r=44100:seed=7[n];sine=f=330:d=40:sample_rate=44100[s];"
             "[n][s]amix=inputs=2:weights=1 0.6,volume='0.55+0.45*sin(2*PI*0.2*t)':eval=frame,"
             "aformat=channel_layouts=stereo,volume=16dB,alimiter=limit=0.9:level=false")
    ff("-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-filter_complex", music, "-t", "40",
       "-c:a", "pcm_f32le", "base.wav")
    # 开头 6 秒几乎没声音（VBR mp3 的时长会被估错）
    ff("-i", "base.wav", "-af", "volume='if(lt(t,6),0.003,1)':eval=frame", "quiet_intro.wav")
    ff("-f", "lavfi", "-i", "color=c=pink:s=600x600", "-frames:v", "1", "cover.png")
    ff("-f", "lavfi", "-i", "testsrc2=s=1600x1600", "-frames:v", "1", "bigcover.png")

    def make(name, note, *args, mono=False):
        ff(*args)
        notes[name] = {"note": note, "mono": mono}

    make("cbr.mp3", "普通 mp3（CBR 192k）", "-i", "base.wav", "-c:a", "libmp3lame", "-b:a", "192k", "cbr.mp3")
    make("vbr_noxing.mp3", "VBR mp3、没有 Xing 头、开头很安静（时长会被估错）",
         "-i", "quiet_intro.wav", "-c:a", "libmp3lame", "-q:a", "6", "-write_xing", "0", "vbr_noxing.mp3")
    make("bigcover.mp3", "带很大封面的 mp3（ID3 标签好几 MB）",
         "-i", "cbr.mp3", "-i", "bigcover.png", "-map", "0", "-map", "1", "-c:a", "copy", "-c:v", "png",
         "-id3v2_version", "3", "-disposition:v", "attached_pic", "bigcover.mp3")
    make("mono22k.mp3", "单声道 22kHz mp3", "-i", "base.wav", "-ac", "1", "-ar", "22050",
         "-c:a", "libmp3lame", "-b:a", "64k", "mono22k.mp3", mono=True)
    make("aac_named.mp3", "其实是 AAC（ADTS），却叫 .mp3",
         "-i", "base.wav", "-c:a", "aac", "-b:a", "160k", "-f", "adts", "aac_named.mp3")
    make("adts.aac", "裸 AAC（.aac）", "-i", "base.wav", "-c:a", "aac", "-b:a", "160k", "adts.aac")
    make("adts_named.m4a", "其实是裸 AAC（ADTS），却叫 .m4a（Telegram 上 mime 是 audio/aac 时会这样）",
         "-i", "base.wav", "-c:a", "aac", "-b:a", "160k", "-f", "adts", "adts_named.m4a")
    try:
        make("ogg_named.mp3", "其实是 Ogg Opus，却叫 .mp3（iPhone 放不了，只要不闪退就行）",
             "-i", "base.wav", "-c:a", "libopus", "-b:a", "128k", "-f", "ogg", "ogg_named.mp3")
    except subprocess.CalledProcessError:
        print("（这台 ffmpeg 做不了 ogg，跳过）")
    make("mp3_named.m4a", "其实是 mp3，却叫 .m4a",
         "-i", "base.wav", "-c:a", "libmp3lame", "-b:a", "192k", "-f", "mp3", "mp3_named.m4a")
    make("video.mp4", "带画面的 mp4 视频（H.264 + AAC）",
         "-f", "lavfi", "-i", "testsrc2=s=320x240:r=15", "-i", "base.wav", "-shortest",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "video.mp4")
    make("alac.m4a", "ALAC 无损 m4a", "-i", "base.wav", "-c:a", "alac", "alac.m4a")
    make("cover.flac", "带封面的 flac", "-i", "base.wav", "-i", "cover.png", "-map", "0", "-map", "1",
         "-c:a", "flac", "-c:v", "png", "-disposition:v", "attached_pic", "cover.flac")
    make("s24.wav", "24 位 wav", "-i", "base.wav", "-c:a", "pcm_s24le", "s24.wav")
    make("lowrate.m4a", "低码率 AAC（48k、22kHz）", "-i", "base.wav", "-c:a", "aac", "-ar", "22050",
         "-b:a", "48k", "lowrate.m4a")
    try:
        make("opus.m4a", "m4a 里装的是 Opus（YouTube 下载器偶尔会这样）",
             "-i", "base.wav", "-c:a", "libopus", "-b:a", "128k", "-f", "mp4", "opus.m4a")
    except subprocess.CalledProcessError:
        print("（这台 ffmpeg 做不了 opus.m4a，跳过）")
        if os.path.exists("opus.m4a"):
            os.remove("opus.m4a")

    # 坏掉的文件
    ff("-i", "base.wav", "-c:a", "libmp3lame", "-b:a", "192k", "tmp.mp3")
    data = open("tmp.mp3", "rb").read()
    open("junk_tail.mp3", "wb").write(data + os.urandom(300_000))
    notes["junk_tail.mp3"] = {"note": "mp3 后面多了 300KB 乱码", "mono": False}
    truncate("tmp.mp3", "truncated.mp3", 0.6)
    notes["truncated.mp3"] = {"note": "mp3 只下载了 60%", "mono": False}
    ff("-i", "base.wav", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", "tmp.m4a")
    truncate("tmp.m4a", "truncated_faststart.m4a", 0.6)
    notes["truncated_faststart.m4a"] = {"note": "m4a（目录在前面）只下载了 60%", "mono": False}
    ff("-i", "base.wav", "-c:a", "aac", "-b:a", "160k", "tmp2.m4a")
    truncate("tmp2.m4a", "truncated_moovlast.m4a", 0.9)
    notes["truncated_moovlast.m4a"] = {"note": "m4a（目录在最后）只下载了 90%：目录没了，哪里都放不了", "mono": False}

    for f in ["base.wav", "quiet_intro.wav", "cover.png", "bigcover.png", "tmp.mp3", "tmp.m4a", "tmp2.m4a"]:
        os.remove(f)

    result = {}
    for name, info in sorted(notes.items()):
        result[name] = {"ffmpeg_lufs": lufs(name, info["mono"]), **info}
        print(f"{name:26s} {str(result[name]['ffmpeg_lufs']):>8s}  {info['note']}")
    json.dump(result, open("expected.json", "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/problems")
