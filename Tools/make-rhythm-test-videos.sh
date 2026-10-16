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

make const-0.5hz 30 0.5 "2*PI*0.5*t"
make const-1hz   30 1   "2*PI*1*t"
make const-2hz   30 2   "2*PI*2*t"
make const-3hz   30 3   "2*PI*3*t"
# 阶跃：φ = 2π·t（t < 20），之后 2π·(20 + 2·(t − 20))，在 20 秒处相位连续
make step-1to2hz 40 2 "2*PI*if(lt(t,20),t,20+2*(t-20))"
# 扫频：f(t) = 0.5 + 2.5·t/60，φ = 2π·(0.5·t + 2.5·t²/120)
make sweep-0.5to3hz 60 3 "2*PI*(0.5*t+2.5*t*t/120)"
