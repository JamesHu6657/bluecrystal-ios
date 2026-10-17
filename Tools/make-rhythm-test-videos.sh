#!/usr/bin/env bash
# rhythm-follow P0：生成「已知往复频率」的测试视频，用来在真机上验证画面联动的频率跟随。
#
# 每个视频：静止的噪声纹理背景 + 一块带自己纹理的方块水平正弦往复（相位连续），
# 音轨在方块到达最右端（定义为「最深点」）时响一声 1800 Hz 的短促咔哒，方便用慢动作 / 耳朵对时机。
#
#   const-0.5hz.mp4 / const-1hz.mp4 / const-2hz.mp4 / const-3hz.mp4   常频 30 秒
#   step-1to2hz.mp4                                                    前 20 秒 1 Hz、后 20 秒 2 Hz（阶跃，相位连续）
#   sweep-0.5to3hz.mp4                                                 60 秒内 0.5 → 3 Hz 线性扫频
#
# 声画融合 F0（观测与标定，docs/visual-sync-design.md「av-fusion F0/F1」§4.3，验证流程见 docs/rhythm-calibration.md 第 11 节）：
#   av-flash-click-1.6hz.mp4        基线：方块 1.6 Hz，最深点同一帧整幅闪白 + 宽带咔哒（慢动作拍屏幕 + 听，量声画偏移）
#   av-offset+120ms-1.6hz.mp4       同上，声音比画面晚 120 ms（容差：仍应判「耦合」）
#   av-offset-200ms-1.6hz.mp4       同上，声音比画面早 200 ms（超出 ±150 ms 容差的边界样本，记录实际表现）
#   av-music-only-120bpm.mp4        纯配乐：画面静止，120 BPM 底鼓 + 八分踩镲 + 和弦（应判「像配乐」，不耦合）
#   av-music-1.6hz-picture-1.6hz.mp4 画面 1.6 Hz + 同频配乐（鼓点和最深点错开 0.23 秒），15 秒处切镜、音乐不断（应判「像配乐」）
#   av-voice-like-1.6hz.mp4         画面 1.6 Hz + 类人声（150 Hz 谐波 + 4 Hz 音节包络，无撞击）（应判「像人声」，不耦合）
#
# 用法：bash Tools/make-rhythm-test-videos.sh [输出目录]（默认 ./rhythm-test-videos）。需要 ffmpeg（不需要 drawtext）。
# 生成后用隔空投送 / 文件 App 放到手机上，在「视频联动」里选「画面」+ 打开「伸缩跟随动作频率」播放，
# 看状态行「动作节奏 x.x 次/秒」是否 ≈ 文件名里的频率。验证流程见 docs/rhythm-calibration.md。
set -euo pipefail

OUT="${1:-rhythm-test-videos}"
W=640
H=360
FPS=30
BW=140          # 方块宽
BH=200          # 方块高
# 往复单程振幅（像素）按视频里最高频率定：App 在 64×36 的分析帧上以 15 fps 做块匹配，搜索半径 8 像素 / 帧，
# 峰值速度 2π·f·A 超过它会估成一半频率。这里让最高频率时峰值速度 ≈ 5 分析像素 / 帧（640 宽 = 10 倍）
amp_for() { awk -v f="$1" 'BEGIN { a = 10 * 5 * 15 / (2 * 3.14159265 * f); if (a > 120) a = 120; printf "%d", a }'; }
command -v ffmpeg >/dev/null || { echo "需要 ffmpeg" >&2; exit 1; }
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 静态纹理：背景偏暗、方块偏亮，块运动分析需要纹理才能估计位移
ffmpeg -v error -y -f lavfi -i "color=c=0x404040:s=${W}x${H}" \
    -vf "noise=alls=60:allf=0:all_seed=11,boxblur=1:1" -frames:v 1 "$TMP/bg.png"
ffmpeg -v error -y -f lavfi -i "color=c=0xb0b0b0:s=${BW}x${BH}" \
    -vf "noise=alls=90:allf=0:all_seed=23" -frames:v 1 "$TMP/block.png"

# make <文件名> <秒数> <最高频率 Hz> <相位表达式 φ(t)，弧度>
make() {
    local name="$1" dur="$2" phi="$4"
    local amp
    amp="$(amp_for "$3")"
    local cx=$(( (W - BW) / 2 ))
    local cy=$(( (H - BH) / 2 ))
    ffmpeg -v error -y \
        -loop 1 -framerate "$FPS" -i "$TMP/bg.png" \
        -loop 1 -framerate "$FPS" -i "$TMP/block.png" \
        -f lavfi -i "aevalsrc='0.6*sin(2*PI*1800*t)*gt(sin(${phi}),0.995)':s=44100:d=${dur}" \
        -filter_complex "[0:v][1:v]overlay=x='${cx}+${amp}*sin(${phi})':y=${cy}:eval=frame,format=yuv420p[v]" \
        -map "[v]" -map 2:a -t "$dur" -r "$FPS" \
        -c:v libx264 -preset veryfast -crf 20 -g "$FPS" -c:a aac -b:a 96k -movflags +faststart \
        "$OUT/$name.mp4"
    echo "已生成 $OUT/$name.mp4（单程 ±${amp} 像素）"
}

# 切镜用的第二张背景（另一个噪声种子）
ffmpeg -v error -y -f lavfi -i "color=c=0x383838:s=${W}x${H}" \
    -vf "noise=alls=70:allf=0:all_seed=47,boxblur=1:1" -frames:v 1 "$TMP/bg2.png"

# 声画融合 F0：make_av <文件名> <秒数> <最高频率 Hz> <相位表达式 φ(t)> <音轨表达式 a(t)> [闪白条件] [切镜秒数] [振幅像素]
# 闪白条件为空 = 不闪；切镜秒数为空 = 不切（之后换第二张背景，方块照常）；振幅 0 = 画面静止
make_av() {
    local name="$1" dur="$2" phi="$4" audio="$5" flash="${6:-}" cut="${7:-100000}" amp="${8:-}"
    [ -n "$amp" ] || amp="$(amp_for "$3")"
    local cx=$(( (W - BW) / 2 ))
    local cy=$(( (H - BH) / 2 ))
    local fx="null"
    [ -z "$flash" ] || fx="drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='${flash}'"
    ffmpeg -v error -y \
        -loop 1 -framerate "$FPS" -i "$TMP/bg.png" \
        -loop 1 -framerate "$FPS" -i "$TMP/block.png" \
        -f lavfi -i "aevalsrc='${audio}':s=44100:d=${dur}" \
        -loop 1 -framerate "$FPS" -i "$TMP/bg2.png" \
        -filter_complex "[0:v][3:v]overlay=0:0:enable='gte(t,${cut})'[b];[b][1:v]overlay=x='${cx}+${amp}*sin(${phi})':y=${cy}:eval=frame[m];[m]${fx},format=yuv420p[v]" \
        -map "[v]" -map 2:a -t "$dur" -r "$FPS" \
        -c:v libx264 -preset veryfast -crf 20 -g "$FPS" -c:a aac -b:a 96k -movflags +faststart \
        "$OUT/$name.mp4"
    echo "已生成 $OUT/$name.mp4（单程 ±${amp} 像素）"
}

# 宽带咔哒（随机噪声 × 8 ms 衰减），在 sin(ψ) 越过峰值的那一帧附近响：ψ = 画面相位按声音偏移平移后的值
click() { echo "0.7*(2*random(0)-1)*exp(-150*mod(t-(${2}),1/${1}))*lt(mod(t-(${2}),1/${1}),0.06)*gte(t,${2})"; }
# 1.6 Hz 时 sin(2π·1.6·t) 的峰在 t = (k + 1/4)/1.6
P16="2*PI*1.6*t"
PEAK16="0.15625"
# 闪白：最深点所在的那一帧（30 fps 每帧 1/30 秒，每个往复正好一帧）
FLASH16="lt(mod(t-${PEAK16}+1/60,0.625),1/30)"

make const-0.5hz 30 0.5 "2*PI*0.5*t"
make const-1hz   30 1   "2*PI*1*t"
make const-2hz   30 2   "2*PI*2*t"
make const-3hz   30 3   "2*PI*3*t"
# 阶跃：φ = 2π·t（t < 20），之后 2π·(20 + 2·(t − 20))，在 20 秒处相位连续
make step-1to2hz 40 2 "2*PI*if(lt(t,20),t,20+2*(t-20))"
# 扫频：f(t) = 0.5 + 2.5·t/60，φ = 2π·(0.5·t + 2.5·t²/120)
make sweep-0.5to3hz 60 3 "2*PI*(0.5*t+2.5*t*t/120)"

# —— 声画融合 F0（§4.3）——
make_av av-flash-click-1.6hz 30 1.6 "$P16" "$(click 1.6 "$PEAK16")" "$FLASH16"
make_av av-offset+120ms-1.6hz 30 1.6 "$P16" "$(click 1.6 "$PEAK16+0.12")" "$FLASH16"
make_av av-offset-200ms-1.6hz 30 1.6 "$P16" "$(click 1.6 "$PEAK16-0.2")" "$FLASH16"
# 120 BPM：底鼓每 0.5 秒（55 Hz 衰减正弦）、踩镲每 0.25 秒（噪声 12 ms 衰减）、C 大三和弦一直在
MUSIC120="0.8*sin(2*PI*55*mod(t,0.5))*exp(-12*mod(t,0.5))+0.18*(2*random(0)-1)*exp(-80*mod(t,0.25))+0.06*(sin(2*PI*261.63*t)+sin(2*PI*329.63*t)+sin(2*PI*392*t))"
make_av av-music-only-120bpm 30 1 "0" "$MUSIC120" "" "" 0
# 96 BPM = 1.6 Hz 的鼓点，比画面最深点晚 0.23 秒；和弦每 2.5 秒换一次（C → A 小）
MUSIC96="0.8*sin(2*PI*55*mod(t-0.38125,0.625))*exp(-12*mod(t-0.38125,0.625))*gte(t,0.38125)+0.15*(2*random(0)-1)*exp(-80*mod(t-0.38125,0.3125))*gte(t,0.38125)+0.06*(sin(2*PI*261.63*t)+sin(2*PI*if(lt(mod(t,5),2.5),329.63,220)*t)+sin(2*PI*392*t))"
make_av av-music-1.6hz-picture-1.6hz 30 1.6 "$P16" "$MUSIC96" "" 15
# 类人声：150 Hz 基频（±4% 颤动）+ 3 个谐波，4 Hz 音节包络（sin² 起落，没有陡的起音）
VOICE="0.25*(sin(2*PI*150*t+0.9*sin(2*PI*5*t))+0.6*sin(2*PI*300*t+1.8*sin(2*PI*5*t))+0.4*sin(2*PI*450*t+2.7*sin(2*PI*5*t))+0.25*sin(2*PI*600*t+3.6*sin(2*PI*5*t)))*pow(sin(PI*4*t),2)"
make_av av-voice-like-1.6hz 30 1.6 "$P16" "$VOICE"
