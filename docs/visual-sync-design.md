# 一起看 · 画面联动设计（Visual Sync）

> 状态：设计稿，只有文档，不含任何 App 代码改动。
> 基线：`audio-floor-autogain` @ `144c4c1`（本文引用的类型、函数、常量都以这个提交为准）。
> 范围：视频页（`BlueCrystalIOS/VideoSyncView.swift`）在现有「声音联动」之外，增加按**画面内容（主要是屏幕上的运动）**决定输出参数的能力。全部在手机本地完成：不联网、不调用任何付费 API、不保存任何画面。
> 硬约束：不修改 `BLEManager.swift`、`SafetyLedger.swift`、`Protocol.swift`、`AIProgram.swift`；暂停 / seek / 播完 / 断开必须照旧立刻归零；任何时候不超过用户设的强度上限。

---

## 0. 一页结论

- **取帧**：在 `loadVideo(url:)` 里给 `AVPlayerItem` 挂一个 `AVPlayerItemVideoOutput`（和 `AudioLevelTap.install` 并列），在独立串行队列上以 **15 Hz** 拉帧，只读 **Y（亮度）平面**，步长采样 + 4×4 盒平均降到 **64×36**。
- **运动量**：去均值帧差（抗闪光 / 渐变）+ 每像素噪声门 τ=4 + **全局平移补偿**（32×18 粗搜 ±3 px，64×36 精修 ±1 px），得到「主体运动残差」；**直方图距离判镜头切换**，切换帧不出尖峰。
- **归一化**：对数压缩后，用和 `AudioReactiveShaper.refDb` 同一套思路的「快升慢降」参考值跟踪每个视频自己的运动范围，参考响段映射到 85%，与 `autoTargetPercent` 一致。
- **节奏**：6 秒窗口自相关（0.33~3 Hz），优先用**带符号的局部位移**（避免帧差能量的倍频问题），节奏只调制「伸缩」的强度（±30%），不尝试逐下复刻（0.3 秒 tick 物理上做不到，见 §4.10）。
- **融合**：三种来源「声音 / 画面 / 声音+画面」，默认仍是**声音**（老用户行为逐位不变）。混合按占比 w（默认 0.6 画面）线性加权，缺哪路就自动归给另一路；可选「伸缩跟画面、震动跟声音」分开驱动。
- **出口**：新的纯函数 `SyncOutputStage` 做「最低强度 / 上限映射（与现有逻辑逐位一致）→ 升幅限速（画面模式 ≤ +20 点/拍）→ 归零后至少保持 2 拍 → 最终夹紧」，结果仍然只经 `VideoSyncPlayer.tick()` → `BLEManager.sendTick(levels:)` 发出。
- **性能**：每帧 CPU < 0.5 ms（A13 级别估算），15 Hz 下平均 < 1% 单核；预算上限 p95 ≤ 2 ms / 帧、平均 ≤ 3% 单核、常驻内存 < 1 MB。发热时自动降频，`.critical` 时画面分析关闭、回落到声音或 0。
- **分期**：P1 画面运动 → 强度（只有「声音 / 画面」二选一）；P2 混合 + 镜头平移补偿 + 分开驱动；P3 节奏；P4 Vision 高精度 + 可选预扫描 / 前瞻。

---

## 1. 现状：代码实际在做什么

### 1.1 数据流（`audio-floor-autogain`）

```
AVPlayerItem ──audioMix──▶ MTAudioProcessingTap（实时线程，AudioLevelTap.makeTap）
                               │ AudioLevelMeter.process → AudioWindowAccumulator.add（os_unfair_lock）
                               ▼
Timer 0.3 s（AudioReactiveShaper.interval，RunLoop .common，主线程）
  VideoSyncPlayer.tick()
    ble.heartbeat()                                  ← 看门狗心跳（BLEManager.watchdogInterval = 5 s）
    guard !isSeeking, isPlaying
    progressWatch.observe(...)                       ← PlaybackProgressWatch：.moving / .waitingAfterSeek / .stalled / .paused
    PlaybackCompletion.reachedEnd(...)
    window = meter.drain()                           ← AudioLevelMeter.drain → AudioWindow
    out = shaper.step(window, settings, dt, hasAudio) ← AudioReactiveShaper.step
    vals = settings.channels.levels(percent:)        ← AudioSyncChannels.levels（0~99，通道 2/3 恒 0）
    if needsResync || ActiveChannels(values: vals) != lastActive { ble.sendTick(levels: vals) }
```

### 1.2 本设计直接依赖的现有类型 / 函数

| 现有符号 | 位置 | 本设计怎么用 |
|---|---|---|
| `VideoSyncPlayer`（`tick()`、`loadVideo(url:)`、`seek(to:)`、`handleTimeJump(_:)`、`togglePlay()`、`handleExternalPlay(_:)`、`stopAll()`、`passiveStop(reason:)`、`zeroDisplay()`、`applySettings(_:)`） | VideoSyncView.swift | 唯一接线点。每个已有的 `meter?.reset()` / `shaper.reset()` 旁边加画面侧的 reset；`tick()` 里在 `shaper.step` 之后加融合与出口 |
| `AudioLevelMeter` / `AudioLevelTap.install` / `AudioLevelTap.Status` | AudioLevelTap.swift | 画面侧完全照抄这个结构：`VideoMotionMeter`（锁里交换几个数）+ `VideoMotionTap.install`（主线程回调 `Status`）+ 安装代次 `motionGen`（对应 `meterGen`） |
| `AudioWindowAccumulator` / `AudioWindow` | Models.swift | 对应 `MotionWindowAccumulator` / `MotionWindow`：取走即清零，`frames == 0` 表示这段没有画面 |
| `AudioReactiveShaper`（`smoothed` 为 `private(set)` 可读、`refDb`、`autoTargetPercent = 85`、`gateOpenPercent = 8` / `gateClosePercent = 4`、`step(...)` 尾部的最低强度 / 上限映射） | Models.swift | 声音模式**原样调用、结果原样使用**；混合模式读 `shaper.smoothed`（门后、平滑后、上限前的 0~100）作为声音分量；出口映射逐位复刻 `step` 尾部（有回归测试钉住） |
| `AudioSyncSettings`（`Keys`、`load(from:)`、夹紧规则、`minPercent ≤ maxPercent`） | Models.swift | 继续作为上限 / 最低强度 / 输出通道的唯一来源；新增 `VisualSyncSettings` 照同样的写法（键名不带点、坏值夹回） |
| `AudioSyncChannels.levels(percent:)` | Models.swift | 「同值输出」时照用；分开驱动时由 `SyncOutputStage` 直接产出 `[thrust, vibration, 0, 0]` |
| `ActiveChannels` | Models.swift | 变化才发，逻辑不变 |
| `PlaybackProgressWatch`（`waitingAfterSeek` 时 `_ = meter?.drain()`） | Models.swift | 同一分支里把画面窗口也取走丢掉 |
| `BLEManager.sendTick(levels:)` | BLEManager.swift（不改） | 仍是唯一出口；`opensGate: false`，只有用户点播放（`userResumeOutput()`）能开闸 |
| `OutputGate.decide` / `OutputAdmission.decide` | Protocol.swift（不改） | 运行中的全零 tick 会被换成**完整停止帧对**（0x08 at 255 → 100 ms → 0x06），停止进行中到来的非零帧被 `deferUntilStopped`。这是 §4.12「归零后保持 2 拍」的理由 |
| `OutputWriteCoalescer` | Protocol.swift（不改） | 只对带 `maxRise` 的帧（AI）限升幅；**视频 tick 没有任何升幅限制**，所以画面模式的升幅限速必须在 VM 侧做（§4.12） |
| `BCProtocol.maxManualLevel = 99`、`Channel.thrust = 0` / `.vibration = 1` / `.suction = 2`（`isUsed == false`） | Protocol.swift（不改） | 最终夹紧上界；吮吸 / 旋转恒 0 |

### 1.3 现有归零路径（新功能不得绕开、也不得新增绕开它们的发送）

| 触发 | 现有处理 |
|---|---|
| 用户暂停 | `togglePlay()` → `stopTimer(sendZero: true)`（`ble.sendStop()`）+ `zeroDisplay()` |
| 系统控件暂停 / 外部暂停 | `observeTimeControlStatus` → `handlePausedPlayer` → `handleExternalPause()` |
| 播完 | `didPlayToEndTimeNotification` / tick 里 `PlaybackCompletion.reachedEnd` → `handleNaturalCompletion` |
| 拖进度条 / 快进快退 | `seek(to:)`、`handleTimeJump(_:)`：先 `sendTick(zero)`，`progressWatch.awaitSeekProgress`，等播放头真正前进才恢复 |
| 缓冲卡住 | `progressWatch` `.stalled` → `handleStall()` |
| 断开 | `ble.$state` 非 `.ready` → `stopTimer(sendZero: false)` |
| 被动停机（看门狗 / 退后台 / 上限 / 写失败 / 被拒） | `ble.forceZeroOutputs` → `passiveStop(reason:)` |
| 关掉联动 | `applySettings` → `sendTick(zero)` |
| 离开页面 / 隐私锁停止 / 打开文件选择器 | `onDisappear` / `privacy.stopAllRequested` / `stopBeforePicker()` → `stopAll()` |

这些路径都**不经过** `shaper.step`，直接发停止或全零。画面联动只改变 `tick()` 里「正常播放、播放头在前进」那一条分支算出来的数，所以以上保证天然保留。

### 1.4 读代码时发现的、会影响设计的细节

1. `BLEManager.heartbeat()` 的注释写「视频页 tick（100ms）」，实际 tick 是 `AudioReactiveShaper.interval = 0.3 s`。看门狗阈值 5 s，余量足够；本设计**不改 tick 间隔**。
2. 0x08 帧的强度是设备内部电机的档位（伸缩 = 速度 / 力度档，震动 = 强度档），App 不控制位置。**画面上的一下一下无法逐下复刻**，只能把「运动强弱 / 节奏快慢」映射成档位。
3. 0.3 s 一拍 ≈ 3.3 Hz 采样，按奈奎斯特最多表达 1.67 Hz 的起伏；实际有平滑，能感知的包络变化在 1 Hz 以下。节奏信息因此只用来「调档」，不用来「打拍」（P3 的「慢节奏跟拍」只在周期 ≥ 1.2 s 时启用）。
4. 现有 CI（`.github/workflows/pr-checks.yml`）的纯逻辑检查只编译 `Protocol.swift`、`Models.swift`、`SafetyLedger.swift`、`AIProgram.swift` + `Tests/*/main.swift`。所以**画面算法必须放在只依赖 Foundation 的文件里**，才能被同样方式测试（§3.2、§9）。
5. 全屏页 `FullScreenVideoView` 用的是同一个 `vm.player`，`AVPlayerItemVideoOutput` 挂在 item 上，和用哪个 `AVPlayerViewController` 显示无关，内嵌 / 系统全屏 / 自绘全屏切换都不影响取帧。
6. `SystemPlayerView` 里画中画已禁用、退后台本来就停机，所以不需要考虑后台取帧。

---

## 2. 目标与非目标

**目标**

- G1：没有音轨、或声音和画面不相关（配乐视频）的片子，也能按画面动作驱动设备。
- G2：镜头切换、手持晃动、平移摇镜、闪光 / 渐黑、字幕出现，不产生假的强输出。
- G3：每个视频自适应（安静画面和激烈画面都能用满 最低强度 ~ 上限 的范围），与现有「自动灵敏度」体验一致。
- G4：能识别有规律的往复运动，并让「伸缩」跟着节奏快慢变化。
- G5：可与声音混合，用户能选比例或分通道驱动。
- G6：安全语义与现在完全一致，额外再加一道升幅限速。

**非目标**

- 不做语义理解（不识别是什么人 / 什么动作），不上传、不存帧、不用云端或付费模型。
- 不改 tick 频率，不改 BLE 协议、准入、额度、看门狗、停止帧对。
- 不做逐下同步的「脚本生成」（`TimelineScript` 那条路以后可以接 P4 的预扫描结果，但不在本设计范围）。

---

## 3. 架构

### 3.1 数据流（新增部分加粗）

```
AVPlayerItem ──audioMix──▶ AudioLevelTap ──▶ AudioLevelMeter ─────────────────────────┐
     │                                                                                │
     └──add(output)──▶ **VideoMotionTap**（AVPlayerItemVideoOutput，motion 队列 15 Hz 拉帧）│
                          │ CVPixelBuffer（420f，只读 Y 平面）                          │
                          ▼                                                           │
                     **LumaDownscaler** → 64×36 LumaFrame                              │
                          ▼                                                           │
                     **MotionAnalyzer**（去均值帧差、噪声门、平移补偿、切换检测、局部位移）│
                          ▼ MotionSample（每帧）                                       │
                     **RhythmEstimator**（每 0.9 s 一次自相关，motion 队列上算）           │
                          ▼                                                           │
                     **VideoMotionMeter**（os_unfair_lock：MotionWindowAccumulator + 最新节奏）
                                                                                      │
Timer 0.3 s → VideoSyncPlayer.tick()                                                  │
    audioWin = meter.drain() ◀───────────────────────────────────────────────────────┘
    motionWin = motionMeter.drain()
    out = shaper.step(audioWin, …)                       （不变）
    m   = **motionNormalizer.step(motionWin)** → **motionShaper.step(…)**
    mix = **SyncBlender.blend(audio: shaper.smoothed, motion: m, rhythm, settings)**
    vals = **outputStage.step(mix, audioSettings, visualSettings)**   （上限 / 最低 / 限速 / 夹紧）
    变化才 ble.sendTick(levels: vals)                    （不变）
```

### 3.2 新文件与新类型

| 文件 | 依赖 | 类型 | 职责 |
|---|---|---|---|
| `BlueCrystalIOS/VisualSync.swift`（新，**只 import Foundation**） | Models.swift | `LumaFrame` | 64×36（或按比例）8 位亮度图 + 时间戳 |
| | | `LumaDownscaler` | 从 (base 指针, width, height, bytesPerRow) 步长采样 + 盒平均到目标尺寸；可选黑边裁剪 |
| | | `MotionAnalyzer` | 相邻帧 → `MotionSample`（残差能量、全局位移、覆盖率、是否切换、带符号局部位移）；`reset()` |
| | | `MotionSample` / `MotionWindow` / `MotionWindowAccumulator` | 每帧结果 / 每拍窗口 / 窗口累加（照 `AudioWindowAccumulator`） |
| | | `RhythmEstimator` | 15 Hz 环形缓冲 → `RhythmEstimate(hz, confidence)?`；`reset()` |
| | | `MotionNormalizer` | 对数压缩 + 快升慢降参考值 → 0~100；`reset()` / `resetAdaptation()`（照 `AudioReactiveShaper` 的两级 reset） |
| | | `MotionShaper` | 噪声门（回差）+ 攻击 / 释放平滑 → 0~100 |
| | | `VisualSyncSource` | `.audio = 0`（默认）/ `.motion = 1` / `.mix = 2` |
| | | `VisualSyncSettings` | 画面相关设置（§7），`Keys` / `load(from:)` / 夹紧 |
| | | `SyncBlender` | 声音 / 画面 / 节奏 → 每通道 0~100 |
| | | `SyncOutputStage` | 最低强度 / 上限映射 + 升幅限速 + 归零保持 + 最终夹紧 → `[Int]`（4 通道） |
| `BlueCrystalIOS/VideoMotionTap.swift`（新） | AVFoundation、CoreVideo、QuartzCore | `VideoMotionMeter` | 锁保护的窗口 + 最新节奏；`drain()` / `reset()`（照 `AudioLevelMeter`） |
| | | `VideoMotionTap` | `install(on:asset:meter:completion:)`、`uninstall()`；拉帧定时器、发热降频 |
| | | `VideoMotionTap.Status` | `.none / .loading / .ready / .noVideo / .failed(String) / .degraded(String)` |

> 为什么不塞进 Models.swift：Models.swift 已有 700+ 行，且现有两套检查都编译它；单独文件可以单独加一个 CI 步骤，不影响 ProtocolChecks / Round4Checks 的编译命令。若评审更希望不改 CI，也可以把 `VisualSync.swift` 的内容放进 Models.swift 末尾（同样只依赖 Foundation），测试照样能编。

### 3.3 线程模型

| 线程 / 队列 | 做什么 | 不许做什么 |
|---|---|---|
| `com.bluecrystal.motion`（串行，QoS `.userInitiated`） | `DispatchSourceTimer` 66 ms 拉帧、降采样、分析、每 0.9 s 节奏估计，结果写进 `VideoMotionMeter` | 不碰 `BLEManager`、不碰 `@Published`、不分配大块内存（缓冲预分配复用） |
| 主线程 | `tick()` 里 `drain()` + O(1) 的归一化 / 平滑 / 融合 / 出口 | 不做任何逐像素运算（保证心跳准时，不影响看门狗） |
| bleQueue | 不变 | 画面代码对它零依赖 |

分析跟不上时（上一帧还没算完）直接丢帧，**永远不阻塞主线程**。

### 3.4 `VideoSyncPlayer` 的接线点（实施时改动的位置）

| 函数 | 新增动作 |
|---|---|
| 新属性 | `motionMeter: VideoMotionMeter?`、`motionTap: VideoMotionTap?`、`motionGen`、`motionStatus`、`motionNormalizer`、`motionShaper`、`outputStage`、`visualSettings`、`@Published motionLevel`、`@Published rhythmHz` |
| `loadVideo(url:)` | `motionGen += 1`；`motionTap?.uninstall()`；`motionNormalizer.resetAdaptation()`；新建 meter，`VideoMotionTap.install(on: item, asset: asset, meter: m)`，回调里照 `meterGen` 的写法核对 `item === player?.currentItem && gen == motionGen` |
| `handleExternalPlay` / `togglePlay`（开播分支） | 在 `meter?.reset(); shaper.reset()` 旁加 `motionMeter?.reset(); motionShaper.reset(); outputStage.reset()` |
| `seek(to:)`、`handleTimeJump(_:)` | 同上，另外 `motionMeter?.reset()` 会让 `MotionAnalyzer` 丢掉上一帧（不和跳转前的画面做差） |
| `tick()` `.waitingAfterSeek` 分支 | 在 `_ = meter?.drain()` 旁加 `_ = motionMeter?.drain()` |
| `tick()` 正常分支 | §4.11 / §4.12 |
| `zeroDisplay()` | `motionLevel = 0`、`motionShaper.reset()`、`outputStage.reset()` |
| `applySettings` | 新增 `applyVisualSettings(_:)`，变化时 `needsResync = true`；切换来源不归零（下一拍按新来源算），但会重置 `outputStage` 的升幅基准为当前输出 |
| 播放器释放 / 换视频 | `motionTap?.uninstall()`（停定时器、`item.remove(output)`） |

`VideoMotionTap` 内部只在 `player.timeControlStatus == .playing` 时有新帧可拉（暂停时 `hasNewPixelBuffer` 返回 false），但**是否输出完全由 VM 现有的 `isPlaying` / `isSeeking` / `progressWatch` 决定**，画面侧不做任何「是否该输出」的判断。

---

## 4. 算法（带具体数值）

### 4.1 取帧：`VideoMotionTap`

- `AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelBufferIOSurfacePropertiesKey: [:]])`。420f 是硬解的原生输出，通常不需要格式转换；只读 plane 0（Y）。
- 先 `asset.loadTracks(withMediaType: .video)`：没有视频轨 → `.noVideo`；有 → `item.add(output)` → `.ready`。
- motion 队列上 `DispatchSourceTimer`，间隔 **1/15 s ≈ 66.7 ms**，leeway 10 ms：
  ```swift
  let t = output.itemTime(forHostTime: CACurrentMediaTime())
  guard output.hasNewPixelBuffer(forItemTime: t),
        let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) else { return }
  CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
  // plane 0：base / width / height / bytesPerRow → LumaDownscaler（结果写进预分配缓冲）
  ```
- 30 fps 片源约每 2 帧取 1，60 fps 约每 4 帧取 1；没拉的帧系统直接丢，不积压。
- 时间戳用 `shown`（item 时间）。相邻样本 Δt 不在 [0.03, 0.5] s（倒退、跳跃、长时间没帧）→ 当作不连续，analyzer 内部 `reset()`，这一帧只当新的参考帧（双保险，主保险是 VM 的 `motionMeter.reset()`）。
- 能量按 Δt 归一：`E ← E × clamp((1/15) / Δt, 0.5, 2)`，避免拉帧抖动造成假起伏。倍速播放时画面本来就动得更快，按 item 时间算 Δt 会把倍速「抵消」，所以 Δt 用 **host 时间差**（人眼看到的速度）。
- HDR / 10 位片源：请求 8 位 420f 时系统会做转换，成本随分辨率上升，§6 的实测项里单列。

### 4.2 降采样：`LumaDownscaler`

- 目标：宽 64，高按显示比例取整到 [18, 64]（横屏 16:9 → 64×36；竖屏 9:16 → 36×64，下文都以 64×36 举例，竖屏同理）。
- 每个输出像素对应源图一个 (sx × sy) 的块（1080p 时 30×30），**只取块内均匀分布的 4×4 = 16 个点求平均**：每帧读 2304 × 16 = **36,864 字节**，与源分辨率无关（4K 也是这个数）。
- 纯函数，输入是 `UnsafeRawBufferPointer + width + height + bytesPerRow`，测试里可以用 `[UInt8]` 构造（含行尾 padding）。
- **黑边裁剪**（P2）：每 3 秒统计一次行 / 列平均亮度，连续 ≥ 2 次 < 20 的边缘行列视为黑边，之后的帧只在有效区域内降采样；有效区域面积 < 30% 时放弃裁剪（防止把暗场景误当黑边）。
- **字幕带降权**（P2）：底部 15% 的行在能量统计里权重 0.3（字幕、水印的出现 / 消失是局部的强边缘变化）。

### 4.3 帧差能量（主体运动）

设当前帧 Y_t、上一帧 Y_{t-1}（64×36），均值 μ_t、μ_{t-1}：

1. **去均值**：d(x) = (Y_t(x) − μ_t) − (Y_{t-1}(x) − μ_{t-1})。整体变亮 / 变暗（闪光、渐变、自动曝光）对 d 几乎没有贡献。
2. **噪声门**：e(x) = max(0, |d(x)| − τ)，**τ = 4**（0~255 亮度刻度；4×4 平均后 H.264/HEVC 的压缩噪声通常 ±2~3）。
3. **全帧能量** D = Σ w(x)·e(x) / Σ w(x)（w 为字幕带权重，P1 全 1）。
4. **覆盖率**：8×6 个格子（每格 8×6 像素），格能量 > 2.0 的格子占比 `coverage ∈ [0,1]`。

经验量级（64×36、τ=4 之后，待真机标定）：静止讲话 0.2~1.0；走动 2~5；激烈动作 6~15；硬切 25 以上。

### 4.4 镜头平移补偿（P2，P1 可关）

1. 32×18 半分辨率图上，搜索全局位移 s ∈ [−3, 3]²（49 个候选），最小化重叠区（约 26×12 像素）上的去均值 SAD。
2. 在 64×36 上以 2s 为中心 ±1 像素精修（9 个候选），再对 SAD 做一维抛物线插值得到亚像素 s。
3. 补偿后残差 R：用平移后的 Y_{t-1} 按 §4.3 同样算能量（只在重叠区）。
4. **主体运动** M_raw = R + κ·max(0, D − R)，**κ = 0.15**：保留一点镜头能量（完全去掉会让手持运动镜头显得「死」）。用户关掉「过滤镜头晃动」时 M_raw = D。
5. 搜索范围 ±6 像素（64 宽）/ 1/15 s ≈ 每秒 1.4 个画面宽，覆盖绝大多数摇镜；更快的甩镜通常伴随运动模糊，会被 §4.5 的切换检测或残差自然处理。
6. 缩放 / 旋转（推拉镜头）这个方法补偿不了：P4 的 `VNHomographicImageRegistrationRequest` 负责（§5）。

成本：49 × 312 + 9 × ~1,600 ≈ **3 万次绝对差**。

### 4.5 镜头切换 / 闪白

- 16 桶亮度直方图（64×36 上统计），h_dist = ½ Σ |h_t − h_{t-1}| ∈ [0, 1]。
- **判为切换**：h_dist > 0.45 且 D > 2.5 × 最近 2 s 的 D 中位数；或 h_dist > 0.65（无条件）。
- 切换帧：样本标 `isCut = true`，能量**用最近 1 s 的中位数代替**（不出尖峰，也不突然掉到 0），参考帧换成当前帧，之后 **2 个样本（≈ 133 ms）** 继续用中位数（新镜头第一两帧编码质量差）。
- 闪白 / 闪黑：均值突变 > 60 且下一帧回到原水平 → 这两个样本同样按切换处理。
- 剪辑密度（每秒切换数）作为附加特征保留在 `MotionWindow.cutCount` 里，P1~P3 不参与输出（避免快剪 MV 被当成「激烈」），P4 再评估。

### 4.6 带符号的局部位移（P3，供节奏用）

- 取残差能量最高的 **4 个格子**（且格能量 > 2.0），每格在 64×36 上做 ±2 像素块匹配（25 候选 × 48 像素），得到局部 (dx, dy)，减去全局 s。
- 方差较大的那个轴作为主轴，`signedShift = 4 格的平均主轴位移`（像素 / 样本，带符号）。
- 成本 ≈ 4 × 25 × 48 = 4,800 次绝对差。

### 4.7 每拍窗口：`MotionWindowAccumulator`

- 每拍（0.3 s）约收到 4~5 个 `MotionSample`。
- `drain()` 返回 `MotionWindow(meanEnergy, peakEnergy, frames, cutCount, panMean)`，`frames == 0` 表示这段没有画面（暂停 / 缓冲 / 无视频轨）。
- 窗口代表值 **e_win = 0.6 × mean + 0.4 × peak**（思路同 `AudioReactiveShaper.rmsWeight`：均值为主，峰值保留瞬态）。

### 4.8 自适应归一化：`MotionNormalizer`

- 对数压缩：ℓ = ln(1 + e_win / 1.0)。（e=1 → 0.69，e=5 → 1.79，e=15 → 2.77，e=40 → 3.71）
- **绝对门**：e_win < 0.5 → 当作静止，ℓ = 0，且**不更新参考值**（同 `adapt` 里 `db > absoluteGateDb` 才学习）。
- 两个参考值，按真实 dt 指数逼近（与 `AudioReactiveShaper.adapt` 同一写法）：

| 参考 | 初值 | 向上 τ | 向下 τ | 含义 |
|---|---|---|---|---|
| `refHigh` | ln(1+6) ≈ 1.95 | 2 s | 25 s | 这个视频最近的「动得多」水平（≈ 90 分位） |
| `refLow` | ln(1+0.8) ≈ 0.59 | 20 s | 1.5 s | 这个视频最近的「底噪 / 静止」水平（≈ 10 分位） |

- 最小跨度：span = max(**0.8**, refHigh − refLow)（≈ 2.2 倍能量比）。静止画面不会被放大成强输出。
- 映射：n = (ℓ − refLow) / span × g，g = 10^(画面灵敏度 dB / 20)（−6…+12 dB）；**目标 = clamp(n × 85, 0, 100)**（refHigh 对应 85%，与 `autoTargetPercent` 一致）。
- 关闭「自动适应画面」时用固定参考：refLow = ln(1.8)、refHigh = ln(13)。
- `reset()`（暂停 / seek）只清平滑状态；`resetAdaptation()`（换视频）参考值回初值，并启动 **3 s 热身**：置信度 c_m 从 0 线性升到 1（§4.11 用）。
- 切换保持期内的窗口不更新参考值。

### 4.9 平滑与门：`MotionShaper`

- 噪声门沿用声音侧常量：开 **8**、关 **4**（`AudioReactiveShaper.gateOpenPercent` / `gateClosePercent`）。
- 平滑：攻击 τ = **0.15 s**、释放 τ = **0.7 s**（比声音的 0.08 / 0.8 攻击慢一点：画面能量本身比响度更跳）。
- dt 夹在 [0.01, 1] s，非有限值按 0（与 `step` 一致）。
- 输出 `smoothed ∈ [0, 100]` 和 `level`（门前值，界面「画面」条用）。

### 4.10 节奏：`RhythmEstimator`（P3）

- 输入：每个样本的 `signedShift` 和 M_raw，按 item 时间线性插值重采样到严格 15 Hz，环形缓冲 **6 s = 90 点**。
- 每 3 拍（0.9 s）在 motion 队列上算一次：
  1. 去趋势：减去 1 s（15 点）居中滑动平均。
  2. 能量不足（信号标准差 < 0.3 px 或 M_raw 中位数 < 1.0）→ 无节奏。
  3. 归一化自相关 r(L) = Σ x_t·x_{t+L} / √(Σx_t² · Σx_{t+L}²)，L = 5…45（3.0 Hz … 0.33 Hz），取最大 r 的 L*，抛物线插值得亚样本周期。
  4. **优先用带符号位移**：往复运动的位移信号周期就是动作周期。**能量信号有倍频问题**（往复运动每个周期速度有两个峰，能量周期是动作周期的一半），只在位移置信度不够时回落用能量，并做倍频校正：若 2L* ≤ 45 且 r(2L*) ≥ 0.9·r(L*)，取 2L*。
  5. 置信度 c_r = r(L*)，回差：> **0.40** 才认，< **0.30** 才放弃。
  6. 频率在 log2 域做 EMA（τ = 3 s）；单次跳变 > 30% 需要连续 2 次估计一致才接受。
- 成本：41 个 lag × 90 点 ≈ 3,700 次乘加 / 0.9 s。
- 用途（§4.11）：只调制「伸缩」档位快慢，不打拍；周期 ≥ 1.2 s（≥ 4 拍一个周期）时可选「慢节奏跟拍」（P3 实验开关，默认关）：输出 × (0.75 + 0.25·cos(2π·相位))，相位取自位移信号最近一次过零。

### 4.11 融合：`SyncBlender`

记 A = `shaper.smoothed`（声音，0~100，门后平滑后、上限前），可用 a = (`audioStatus == .ready`)；
M = `motionShaper.smoothed`（画面，0~100），可用 v = (`motionStatus == .ready` 且最近 1.0 s 内有画面样本)；
c_m = 热身置信度（§4.8），c_r / f = 节奏置信度 / 频率。

| 来源 | 计算 | 「有信号」（决定是否加最低强度） |
|---|---|---|
| `.audio`（默认） | **不经过 Blender**：沿用 `out = shaper.step(...)` 和 `settings.channels.levels(percent: out.percent)`，逐位等于现在 | `hasAudio`（现有） |
| `.motion` | E = v ? c_m·M : 0 | v |
| `.mix` | w = 画面占比（默认 **0.6**）。wₘ = w·[v]，wₐ = (1−w)·[a]；和为 0 → E = 0；否则 E = (wₘ·c_m·M + wₐ·A) / (wₘ + wₐ) | a ∨ v |

说明：

- 某一路不可用时权重自动归给另一路（例如混合模式遇到无音轨视频 = 纯画面）。
- 热身期 c_m < 1 只会让输出**偏低**（安全方向），不会把权重挪给声音再放大。
- 声音模式下画面分析可以不跑（P1 起：来源是 `.audio` 时不安装 `VideoMotionTap`，零额外开销）。

**通道分配**

- **同值**（默认）：E 经 `SyncOutputStage` 后按 `AudioSyncChannels`（伸缩 + 震动 / 仅伸缩 / 仅震动）分配，和现在一样。
- **分开驱动**（P2，仅 `.mix` 且 `channels == .both` 时可开）：
  - 伸缩 = 画面 M（不可用时用 A），并乘节奏系数 k；
  - 震动 = 声音 A（不可用时用 M）。
  - 理由：伸缩是「动作」通道，和画面里的动作对应最直观；震动对响度的瞬态更敏感，跟声音更自然。
- **节奏系数**（P3，「节奏带动伸缩」开关）：T = clamp((f − 0.6) / (2.4 − 0.6), 0, 1)，k = 1 + c_r·(T − 0.5)·0.6 ∈ [0.7, 1.3]；伸缩 = clamp(M·k, 0, 100)。节奏快 → 伸缩档位高，慢 → 低；没有可信节奏（c_r < 0.3）时 k = 1。**k 放大后仍要过上限**（§4.12），所以不会超上限。

### 4.12 出口：`SyncOutputStage`

只在 `.motion` / `.mix` 使用（`.audio` 完全走现有代码）。每拍对每个使用中的通道 v_ch ∈ [0, 100]：

1. **最低强度 / 上限映射**：与 `AudioReactiveShaper.step` 尾部逐位一致（有回归测试钉住）：
   - floor = 有信号 ? min(cap, minPercent) : 0；
   - floor ≥ 1：`min(Int(cap.rounded(.down)), max(Int(floor.rounded()), Int((floor + v·(cap−floor)/100).rounded())))`；
   - 否则：`scaled = v·cap/100`，`scaled < 1 ? 0 : min(Int(cap.rounded(.down)), Int(scaled.rounded()))`。
2. **升幅限速**：每拍每通道最多比上一拍 **+20**（百分点，≈ 67 点/秒；上限 60 时从 0 到顶 ≥ 0.9 s）；下降不限。原因：`OutputWriteCoalescer` 只限 AI 帧，视频 tick 在 BLE 层没有任何升幅限制，而画面能量比响度更容易突跳（甩镜、遗漏的切换）。
3. **归零后保持**：某通道输出从 > 0 变成 0 后，**至少保持 0 两拍（0.6 s）**才允许再升。原因：运行中的全零 tick 会被 `OutputGate` 换成完整停止帧对（两笔写入 + 100 ms 间隔，期间的非零帧被 `deferUntilStopped`），频繁 0↔非 0 会让链路忙于停止帧对。这一步只会**推迟升高**，是安全方向。
4. **最终夹紧**：每通道 ∈ [0, min(Int(cap.rounded(.down)), `BCProtocol.maxManualLevel`)]，非有限值 → 0，索引 2 / 3 恒 0。
5. `reset()`：升幅基准与归零计数清零（暂停 / seek / 开播 / 换视频时调用）。开播后第一拍从 0 开始爬，和现在「开播 `shaper.reset()` 后从 0 起」一致。

### 4.13 参数总表

| 参数 | 值 | 所在类型 |
|---|---|---|
| 拉帧频率 | 15 Hz（发热 `.serious` 时 8 Hz） | `VideoMotionTap` |
| 分析尺寸 | 64×36（竖屏 36×64），每像素 4×4 采样 | `LumaDownscaler` |
| 噪声门 τ | 4（亮度级） | `MotionAnalyzer` |
| 网格 / 活跃格阈值 | 8×6 / 2.0 | `MotionAnalyzer` |
| 平移搜索 | 半分辨率 ±3 + 全分辨率 ±1 + 抛物线 | `MotionAnalyzer` |
| 镜头能量保留 κ | 0.15 | `MotionAnalyzer` |
| 切换阈值 | h_dist > 0.45 且 D > 2.5×中位数；或 h_dist > 0.65；保持 2 样本 | `MotionAnalyzer` |
| 不连续判定 | Δt ∉ [0.03, 0.5] s | `MotionAnalyzer` |
| 窗口代表值 | 0.6·mean + 0.4·peak | `MotionWindowAccumulator` |
| 绝对门 | e_win < 0.5 | `MotionNormalizer` |
| refHigh 初值 / 升 / 降 | ln 7 / 2 s / 25 s | `MotionNormalizer` |
| refLow 初值 / 升 / 降 | ln 1.8 / 20 s / 1.5 s | `MotionNormalizer` |
| 最小跨度 / 目标位置 | 0.8 / 85% | `MotionNormalizer` |
| 画面灵敏度 | −6…+12 dB，默认 0 | `VisualSyncSettings` |
| 热身 | 3 s | `MotionNormalizer` |
| 门开 / 关 | 8 / 4 | `MotionShaper` |
| 攻击 / 释放 | 0.15 s / 0.7 s | `MotionShaper` |
| 节奏窗口 / 更新 / 频段 | 6 s / 0.9 s / 0.33~3 Hz | `RhythmEstimator` |
| 节奏置信 开 / 关 | 0.40 / 0.30 | `RhythmEstimator` |
| 节奏系数范围 | ×0.7 ~ ×1.3（0.6~2.4 Hz 线性） | `SyncBlender` |
| 画面占比默认 | 0.6 | `VisualSyncSettings` |
| 升幅限速 | +20 点 / 拍 | `SyncOutputStage` |
| 归零保持 | 2 拍 | `SyncOutputStage` |

所有数值都是初始值，P1 / P2 真机标定后可调；调参只改常量，不改结构。

---

## 5. 可选：Vision 高精度模式（P4）

工程已使用 `scrollDisabled`（iOS 16+），下列 Vision 接口都可用，全部本地运行：

- **光流**：`VNGenerateOpticalFlowRequest`（`computationAccuracy = .low`），输入用 `VTPixelTransferSession` 硬件缩放到 256×144，**5 Hz**，在 motion 队列上异步执行，上一对还没算完就跳过。
  - 主体运动 = 光流幅值减去中位数光流（相机运动）后的均值；
  - 带符号主轴平均流替代 §4.6 的块匹配位移，节奏更稳。
- **相机运动**：`VNHomographicImageRegistrationRequest` 估计单应矩阵，处理推拉 / 旋转（§4.4 处理不了的情况）。
- 预算：每对 ≤ 15 ms（待实测，A14 级别估计），超预算或 `thermalState ≥ .serious` 自动退回 §4.3~§4.6 的纯 CPU 方案。
- 高精度结果与基础结果走同一个 `MotionSample` 结构，下游（归一化 / 融合 / 出口 / 安全）完全不变。

**预扫描与前瞻（P4，可选，默认关）**：选视频后可在后台用 `AVAssetReader` + `AVAssetReaderTrackOutput`（420f）跑一遍 §4.2~§4.6，按 4 Hz 存一条运动曲线（20 分钟视频 ≈ 4,800 个 Float，< 20 KB，只在内存）。好处：① 用全片 10 / 90 分位初始化 `refLow / refHigh`，开头不用热身；② 前瞻 150~250 ms 抵消取帧到出口的延迟。硬解速度因机型差异大，预扫描可随时取消，进度在界面显示；播放时以实时分析为准，预扫描只做参考与前瞻。

---

## 6. 性能预算（iPhone）

**每帧 CPU（估算，A13 级别，Release，`-O`）**

| 步骤 | 运算量 | 估计耗时 |
|---|---|---|
| 锁 Y 平面 + 步长采样降采样 | 36,864 次读 + 加法 | ~0.05 ms |
| 去均值帧差 + 噪声门 + 网格 + 直方图 | ~2,304 × 4 | ~0.02 ms |
| 平移搜索（粗 + 精） | ~3 万次绝对差 | ~0.05 ms |
| 局部位移（P3） | ~4,800 次绝对差 | ~0.01 ms |
| 合计 | | **< 0.2 ms，按 0.5 ms 留余量** |

- 15 Hz → 平均 < 1% 单核。节奏估计 3,700 次乘加 / 0.9 s，可忽略。
- **预算上限（验收线）**：p95 ≤ **2 ms / 帧**；画面分析开启时整机 CPU 增量 ≤ **3% 单核**；常驻内存增量 < **1 MB**（2 帧 64×36 + 90 点环形缓冲 + 直方图，全部预分配）。
- 解码本来就在进行（播放需要），`AVPlayerItemVideoOutput` 在 420f 下通常不额外转换；HDR / 10 位片源的转换成本需单独实测。
- Vision 模式（P4）单独预算：5 Hz × ≤ 15 ms ≈ 7.5% 单核或部分转到 ANE / GPU，只在用户打开「高精度」且温度正常时运行。
- **发热降级**（订阅 `ProcessInfo.thermalStateDidChangeNotification`）：
  - `.nominal / .fair`：15 Hz，可开 Vision；
  - `.serious`：降到 8 Hz、关 Vision、关预扫描，状态显示「手机发热，画面分析已降频」；
  - `.critical`：停止画面分析（`.degraded`），`.motion` 输出 0（无信号不加最低强度），`.mix` 自动只用声音。
- 测量方式：`os_signpost` 包住 `analyze()`；Instruments Time Profiler + Energy Log；测试机覆盖 A12 / A15 / A17 各一台，片源 1080p30 H.264、1080p60 HEVC、4K30 HEVC、竖屏 1080×1920、HDR10。
- 延迟：取帧（≤ 67 ms）+ 分析（< 2 ms）+ 等拍（0~300 ms，平均 150 ms）+ 攻击平滑（τ 0.15 s）+ BLE 写入，**体感约 0.3~0.5 s**，与声音侧同量级；P4 的前瞻可以抵掉 150~250 ms。

---

## 7. 界面

放在现有 `link` 卡片里，延续 `Velvet` 风格与无障碍写法；高级项收进 `DisclosureGroup("画面分析")`，默认收起。

| 控件 | 类型 | 显示条件 | 默认 | `@AppStorage` 键 |
|---|---|---|---|---|
| 联动总开关 | Toggle（沿用 `syncEnabled`，文案改为「视频联动」） | 总是 | 开 | `bcAudioSyncEnabled`（不改键名） |
| 跟随 | 分段 Picker：声音 / 画面 / 声音+画面 | 总是 | 声音 | `bcVisualSyncSource` |
| 电平 | `MeterBar`（现有） | 来源用到声音 | | |
| 画面 | `MeterBar`（新，`vm.motionLevel`，`Velvet.gold`） | 来源用到画面 | | |
| 强度 | `MeterBar`（现有；分开驱动时拆成「伸缩」「震动」两条） | 总是 | | |
| 节奏 | 小标签「节奏 ≈ 1.4 次/秒」，没识别出显示「—」 | P3，来源用到画面 | | |
| 画面占比 | Slider 0~100%，步长 10 | 声音+画面 | 60% | `bcVisualSyncMotionWeight` |
| 灵敏度 | Slider（现有） | 来源用到声音 | | |
| 画面灵敏度 | Slider −6…+12 dB，显示「×0.5 ~ ×4」 | 来源用到画面 | 0 | `bcVisualSyncMotionGainDb` |
| 强度上限 / 最低强度 / 输出到 | 现有 | 总是 | 现有 | 现有 |
| 自动适应画面 | Toggle | 高级 | 开 | `bcVisualSyncAutoMotion` |
| 过滤镜头晃动 | Toggle | 高级（P2） | 开 | `bcVisualSyncCameraReject` |
| 伸缩跟画面、震动跟声音 | Toggle | 声音+画面 且 输出到 = 伸缩+震动（P2） | 关 | `bcVisualSyncSplit` |
| 节奏带动伸缩 | Toggle | 高级（P3） | 关 | `bcVisualSyncRhythm` |
| 高精度（更耗电） | Toggle | 高级（P4） | 关 | `bcVisualSyncHighAccuracy` |

- `VisualSyncSettings` 照 `AudioSyncSettings` 写：`Keys` 不带点、`init` 夹紧、`load(from:)` 坏值回默认；`.onChange` 调 `vm.applyVisualSettings(...)`。
- 状态提示（和现有 `audioStatus` 提示并列）：
  - `.noVideo`：「这个视频没有画面轨，画面联动没有输出」；
  - `.failed`：「画面分析不可用（原因），已改用声音」/「…联动没有输出」（视来源）；
  - `.degraded`：「手机发热，画面分析已降频 / 已暂停」。
- 文案：`PageHeader` 副标题按来源切换（「声音起伏…」/「画面起伏…」/「声音和画面起伏…」）；幕布提示「视频的声音会实时变成她的节奏」同理。
- 无障碍：所有新控件 `accessibilityLabel` + `accessibilityValue`；「画面」条与现有 `MeterBar` 一样 `.ignore` 子元素。
- 切换来源在播放中即时生效：不停播、不归零，下一拍按新来源计算，升幅仍受 §4.12 限制（从声音切到画面不会一下跳高）。

---

## 8. 安全

| # | 约束 | 怎么保证 |
|---|---|---|
| S1 | 唯一发送者 | 只有 `VideoSyncPlayer.tick()` 调 `ble.sendTick(levels:)`；`VideoMotionTap` / `VisualSync.swift` 不持有、不 import 任何 BLE 相关类型（代码评审 + grep 检查项） |
| S2 | 暂停 / seek / 播完 / 卡住 / 断开 / 被动停机 / 离开页面 必须归零 | §1.3 的所有路径原样保留，它们不经过融合与出口；画面侧只在这些路径里额外 reset，不新增任何发送 |
| S3 | seek 后不把跳转前的画面当成运动 | VM 的 `motionMeter.reset()` 清掉 analyzer 参考帧；analyzer 自己按 Δt 不连续再 reset 一次；`.waitingAfterSeek` 期间画面窗口取走丢弃 |
| S4 | 不超过用户上限 | `SyncOutputStage` 最终夹紧到 `min(Int(cap.rounded(.down)), 99)`；节奏系数、混合、灵敏度都在夹紧之前；随机模糊测试钉住（§9） |
| S5 | 不自动开闸 | 仍用 `sendTick`（`opensGate: false`）；开播仍必须用户点（`userResumeOutput()`），被动停机后画面信号再强也发不出去 |
| S6 | 看门狗语义不变 | 主线程只做 O(1) 运算，`tick()` 第一行仍是 `ble.heartbeat()`；分析在 motion 队列，跟不上就丢帧，不阻塞主线程 |
| S7 | 降级只往更弱的方向 | 发热 / 失败 / 无视频轨 → 画面分量为 0 或改用声音；热身期置信度 < 1 只降低输出 |
| S8 | 突跳保护 | 画面模式升幅 ≤ +20 点 / 拍；切换帧用中位数代替；归零后保持 2 拍 |
| S9 | 最低强度不凭空出现 | 只在当前来源「有信号」时加（§4.11 表），与现有 `hasAudio` 规则一致；无信号时输出 0 |
| S10 | 存储坏值不放大 | `VisualSyncSettings` 夹紧 + 默认值保守（来源默认声音、占比 0.6、灵敏度 0 dB） |
| S11 | 隐私 | 帧只在内存里降到 64×36 参与计算，不写盘、不上传、不缓存；预扫描曲线只在内存 |
| S12 | 安全文件零改动 | 不改 `BLEManager.swift`、`SafetyLedger.swift`、`Protocol.swift`、`AIProgram.swift`；单次 1200 s 上限、30 分钟额度、停止帧对、锁存、自动重连全部照旧生效 |

---

## 9. 测试计划

### 9.1 纯逻辑检查：`Tests/VisualSyncChecks/main.swift`

写法与 `Tests/Round4Checks/main.swift` 一致（`vcheck(ok, name)` 打印 PASS / FAIL，最后有失败 `exit(1)`）。CI 新增一步（`pr-checks.yml` 与 `build-unsigned-ipa.yml` 各加一段，现有两步不动）：

```bash
xcrun swiftc \
  BlueCrystalIOS/Protocol.swift BlueCrystalIOS/Models.swift \
  BlueCrystalIOS/SafetyLedger.swift BlueCrystalIOS/AIProgram.swift \
  BlueCrystalIOS/VisualSync.swift Tests/VisualSyncChecks/main.swift \
  -o "$RUNNER_TEMP/visual-sync-checks"
"$RUNNER_TEMP/visual-sync-checks"
```

测试辅助：`makeFrame(w:h:rowPadding:_ f: (x, y) -> UInt8)`、确定性 LCG 纹理（同 Round4Checks 的 `nextRandom`）、移动方块、整体平移纹理、两张无关纹理（模拟硬切）。

**降采样**
- 常数图 → 常数；带行尾 padding 的 `bytesPerRow` 不读错；源图小于目标尺寸不越界；竖屏输出 36×64。
- 黑边：上下各 12% 纯黑 → 裁剪后有效区正确；整体很暗（亮度 15）的场景不被当黑边（面积 < 30% 规则）。

**帧差 / 平移 / 切换**
- 相同两帧 → 能量 0；±3 随机噪声 → 能量 0（τ=4）。
- 整体亮度 +40 → 能量 < 0.1（去均值）。
- 8×8 方块移动 4 像素 → 能量 > 1.0，覆盖率 < 0.2。
- 纹理整体平移 (3, 1) 像素：补偿开 → 残差 < 补偿关时的 20%，估计位移误差 < 0.5 像素；补偿关 → M_raw = D。
- 两张无关纹理 → `isCut == true`，该样本能量 = 中位数（不出尖峰）；之后 2 个样本也是中位数。
- 闪白一帧再回来 → 两个样本都按切换处理。
- `reset()` 后第一帧 → 能量 0、不与 reset 前的帧做差；Δt = 0.8 s 的样本 → 视为不连续。
- 字幕带：只在底部 15% 出现的白字 → 能量降为不降权时的约 30%。

**归一化 / 平滑**
- 静止画面（e 在 0.2~0.4 抖动）持续 60 s → 输出恒 0（绝对门 + 最小跨度）。
- 「小动作视频」（e ≈ 1.5~3）与「大动作视频」（e ≈ 8~20）各跑 40 s → 动作段都 ≥ 70%（同 Round4Checks 自动灵敏度测试的口径），大动作视频不长期顶在 100。
- 关闭自动适应 → 小动作视频明显低于自动（证明自动有效）。
- `resetAdaptation()` 后参考值回初值，热身 3 s 内 c_m 单调从 0 到 1。
- 门回差：4~8 之间不关门；攻击一步能跟上 ≥ 80%（dt 0.3 s、τ 0.15 s → 1 − e⁻² ≈ 86%）；持续静止 6 s 内落到 0。
- NaN / ∞ / 负值 / dt = 1000 → 输出有限且在 [0, 100]。

**节奏**
- 位移信号 1.5 Hz 正弦 + 20% 噪声 → 估计 1.5 Hz ± 5%，置信 > 0.4。
- 只给能量信号 |sin(2π·1.2t)|（能量 2.4 Hz）→ 倍频校正后报 1.2 Hz。
- 纯随机噪声 → 置信 < 0.3、不报节奏（误报率：100 个种子里 ≤ 2 个）。
- 5 Hz（超频段）→ 不报；0.2 Hz → 不报。
- 1.0 Hz 突变到 2.0 Hz → 至少 2 次估计后才切换，EMA 收敛 < 6 s。
- `reset()` 后 → nil。

**融合 / 出口（安全相关，重点）**
- **回归**：来源 `.audio` 时，2000 组随机设置 + 随机音频窗口，VM 用的输出与直接 `AudioReactiveShaper.step` + `AudioSyncChannels.levels` 完全相等。
- **映射等价**：`SyncOutputStage` 的最低强度 / 上限映射，在关闭升幅限速和归零保持时，与 `AudioReactiveShaper.step` 尾部对同一 `smoothed` 逐位相等（2000 组随机 cap / floor / v）。
- `.mix`：v = false → 等于纯声音分量；a = false → 等于纯画面分量；w = 0 / 1 两端正确；两路都不可用 → 0 且不加最低强度。
- `.motion`：无视频轨 → 0（即使最低强度 = 10）。
- **上限模糊测试**：5000 组随机（来源、占比、灵敏度、cap ∈ [−20, 150]、floor、分开驱动、节奏 c_r / f、输入含 NaN / ∞）→ 每通道 ∈ [0, min(Int(cap 夹紧后), 99)]，索引 2 / 3 恒 0，`BCProtocol.videoFrame(levels:)` 字节 [5]、[6] 为 0。
- 升幅：任意相邻两拍每通道升高 ≤ 20；下降不限（从 60 一拍能到 0）。
- 归零保持：输出到 0 后两拍内为 0，第三拍才允许 > 0。
- 节奏系数 ×1.3 在 cap = 40 时仍 ≤ 40。
- `reset()` 后第一拍从 0 起爬（≤ 20）。

**设置**
- 空 `UserDefaults` → 来源 = 声音（老用户行为不变）、占比 0.6、灵敏度 0、自动适应开、过滤晃动开、分开 / 节奏 / 高精度关。
- 坏值（字符串、越界、未知来源 9、NaN）→ 夹回或默认。
- 所有键名不含「.」。
- 现有 `Round4Checks` 必须仍然全部通过（声音路径没动）。

### 9.2 不能单测、需要真机 / 手动验证的部分

| 场景 | 期望 |
|---|---|
| 固定机位讲话 | 画面模式基本在最低强度附近，不乱跳 |
| 运动 / 舞蹈（含摇镜） | 动作段明显升高；摇镜时不因背景平移而顶高（过滤开） |
| 快剪 MV | 切换处无尖峰（录 `intensity` 曲线核对） |
| 暗场景、黑边电影、竖屏视频 | 有效区与能量正常 |
| 无音轨视频 + 混合模式 | 等于纯画面 |
| 只有音频的文件（无视频轨） | `.noVideo` 提示；混合 = 纯声音 |
| 2× 倍速 | 能量随画面变快而升高，不因拉帧间隔变化而抖 |
| 播放中：暂停、拖进度条、快进 10 秒、播完、断蓝牙、退后台、切全屏、打开文件选择器、隐私锁 | **每一项都立刻归零**，恢复后从 0 起爬；和声音模式表现一致 |
| 连续 seek 10 次 | 无残留强输出 |
| 长时间播放 20 分钟 | 1200 s 单次上限照常触发；无内存增长；温度与耗电对比声音模式增量在预算内 |
| 发热（可用 Xcode 热状态模拟） | `.serious` 降频提示、`.critical` 回落 |

---

## 10. 分期实施

每一期单独一个分支 / PR，PR Checks 全绿才合并；每期都**不改** `BLEManager.swift`、`SafetyLedger.swift`、`Protocol.swift`、`AIProgram.swift`。

### P1：基础画面强度（先做这个）

- 范围：`VideoMotionTap`（15 Hz 拉帧 + Y 平面）、`LumaDownscaler`、`MotionAnalyzer`（去均值帧差 + 噪声门 + **切换检测**，平移补偿先不做）、`MotionWindowAccumulator`、`MotionNormalizer`、`MotionShaper`、`SyncOutputStage`、`VisualSyncSettings`（只有 来源 / 画面灵敏度 / 自动适应）。
- 来源只有「声音 / 画面」二选一；声音模式下不安装取帧（零开销）。
- UI：跟随 Picker、「画面」电平条、画面灵敏度、自动适应、状态提示。
- VM 接线：§3.4 全部 reset 点 + `tick()` 分支。
- 改动文件：`VisualSync.swift`（新）、`VideoMotionTap.swift`（新）、`VideoSyncView.swift`、`BlueCrystalIOS.xcodeproj/project.pbxproj`（加两个文件）、`Tests/VisualSyncChecks/main.swift`（新）、两个 workflow 各加一步。
- 验收：§9.1 中「降采样 / 帧差 / 切换 / 归一化 / 出口 / 设置」全部通过；Round4Checks 照常通过；§9.2 的归零清单全部手测通过；1080p60 p95 ≤ 2 ms / 帧。

### P2：与声音混合 + 镜头平移补偿

- `SyncBlender` 的 `.mix`、画面占比；平移补偿（§4.4）+「过滤镜头晃动」开关；黑边裁剪；字幕带降权；分开驱动（伸缩跟画面、震动跟声音）+ 两条强度条。
- 验收：平移 / 混合 / 分开驱动相关测试通过；运动类视频摇镜误触发明显下降（同一视频录曲线对比）。

### P3：节奏

- §4.6 局部位移、`RhythmEstimator`、节奏标签、「节奏带动伸缩」开关、实验性「慢节奏跟拍」（默认关）。
- 验收：节奏测试全部通过；真机上明显往复的视频节奏标签稳定（10 s 内跳动 < 20%）。

### P4：高精度与前瞻（可选）

- Vision 光流 / 单应配准（§5）、发热自动回退；可选预扫描（全片分位初始化 + 前瞻）。
- 验收：Vision 开 / 关输出曲线在同一视频上大体一致但对推拉镜头更稳；预扫描可取消、不影响播放流畅度；发热时自动关闭。
- 实际做了：前瞻 + 预扫描 + 发热 / 后台回退（默认关），Vision 光流 / 单应配准推迟，见下面「rhythm-lookahead P4」。

---

### algo-opt-1：联动算法优化（Notion AI，P1 之上的增量）

只改纯逻辑和取帧 / 电平计的数据通路；`BLEManager.swift` / `SafetyLedger.swift` / `Protocol.swift` / `AIProgram.swift` 不动，
输出仍只经 `VideoSyncPlayer.tick()` → `BLEManager.sendTick`；上限 / 最低强度 / 升幅限速（画面模式）/ 夹紧 [0, min(上限, 99)] 不变，所有新项都在这个范围内。
注意不是每一项都只降不升：近场降权、轻柔声音降权在同一拍里只降不升；稳健去均值在局部变亮 / 变暗时能量可能比按整幅均值去均值略高，
近场窗口不学参考值也会让之后的正常画面比学了时略高。

| 项 | 位置 | 做法 | 默认 |
|---|---|---|---|
| 稳健去均值 | `MotionAnalyzer.analyze` | 平移选择仍按均值去均值；能量 / 覆盖率改减「对齐后帧差的中位数」（511 档直方图），局部变暗不再把整幅算成在动 | 总是 |
| 近场 / 遮挡分数 N | `MotionAnalyzer.updateNearField` → `MotionSample.nearField` → `MotionWindow.nearField` | 遮挡 = s(覆盖率) × max(s(直方图离背景), s(变糊))；贴脸晃动 = s(覆盖率) × s(平移采用率) × s(对齐残差)；背景 τ 4 s、近场时冻结 ≤ 6 s；切镜 / 闪变（含手一下盖住镜头）不立刻换背景，保留切镜前背景待定，新画面连续 0.5 s 安静（近场 ≤ 0.5 或覆盖率 < 0.35）或满 6 s 才采用；待定期间直方图项需同时变糊 | 总是 |
| 近场降权 | `MotionNormalizer.step` | ratio −= N·max(0, ratio − 0.6·固定尺度)；N ≥ 0.5 的窗口不学参考值 | 总是（单拍只降不升） |
| 内容时间戳 | `MotionDisplayClock` + `VideoMotionTap` | t = host − (播放头 − 帧显示时间)/速率（滞后 0~0.5 s 内），单调、间隔 ≥ min(31 ms, 到 host 的距离)、不晚于 host；静止补样按上一帧滞后换到同一条时间轴；24 fps 片源能量不再一大一小 | 总是 |
| 性能卫生 | `LumaDownscaler` / `MotionAnalyzer` | 裸指针读采样表、每帧临时数组复用、参考帧拷进已有存储；Instruments「Points of Interest」可看 `MotionDownscale` / `MotionAnalyze` | 总是 |
| 轻柔声音降权 | `AudioChannelStats`（512 点块电平，`AudioLevelMeter` 按声道跨 tap 回调接着分块）→ `AudioWindow.block*` → `AudioReactiveShaper` | 起伏度 Dyn、轻柔度 S；电平 ×(1 − 0.4·S̄)，自动增益的放大部分 ×(0.3 + 0.7·Dyn̄) | 视频页开关「轻柔声音降权」，App 默认开；`AudioSyncSettings.init` 默认关（逐位不变） |
| 来源交接 | `SourceHandover` + `VideoSyncPlayer` | 声音→画面：4 s 内用声音补画面热身 / 还没有新鲜画面样本的空档并淡出（≤ max(两来源)；algo-opt-2 起画面占比再按 1.5 s 爬坡）；画面→声音：先经 `SyncOutputStage` 限速追上直出（≤ 10 拍） | 播放中切换时 |

没做（后续）：声音+画面可靠度混合（P2）、节奏 / 投影速度 + 自相关（P3）、亚像素 / 四象限相似变换平移、Vision（P4）。
真机要验证：手贴镜头 / 遮挡片段的输出、24 / 25 fps 片源的平稳度、轻音乐 / 白噪声视频的力度、切换来源时的手感、Instruments 每帧耗时。

### algo-opt-2：软切恢复 / 交接平滑 / 稳态零分配 / 对比度补偿（v1.8.0 之上）

同样只改纯逻辑（`VisualSync.swift`）和测试；安全文件不动、无新发送路径、无新文件。上限 / 最低强度 / 升幅 ≤ +20 / 拍 / 夹紧 [0, min(上限, 99)] 不变。

| 项 | 位置 | 做法 |
|---|---|---|
| 软切快速恢复 | `MotionAnalyzer.isSoftCut` / `updateNearField` | 切镜待定或近场冻结开始时记下「出事前」的上一帧和每格纹理。之后的帧同时满足：① 整幅都换了（出事前有纹理的格子原样留着的 ≤ 5%）② 帧间稳定（均值变化 ≤ 4、直方图距离 ≤ 0.12、清晰度变化 ≤ 20%）③ 动得不多（能量 ≤ 8）④ 不是又暗又平（均值 < 40 且清晰度 < 2），就算软切；连续 0.5 s 就采用为背景（含没被识别成切镜、走近场冻结的情况），约 0.6~0.75 s 恢复，原来最长 6 s。手盖住 75% 时右边背景还在（留着 ≥ 12%），照旧按遮挡；软切只会让背景更早采用，不会让近场分数变高 |
| 交接平滑 | `SourceHandover.blend` | 画面占比 k = 爬坡 r × 置信度 c，r 从画面有新鲜样本起 1.5 s 由 0 到 1，每次 `begin` 清零：v = k·M + (1 − k)·淡出·A ≤ max(M, A)。以前同一视频第二次切到画面时 c = 1，画面一出样本就一拍掉到 M（刚 reset，≈ 0）；现在每拍最多降约 12。淡出满且 r 满（或画面没在流）才结束，结束那拍和原路径连续 |
| 稳态零分配 | `MotionAnalyzer.globalShift(scratch:)` 等 | 原来每帧两次 `[Double]` 分配（cellDiff / cellN）改成复用 `shiftScratch`；新增缓冲（参考帧、每格纹理、补偿用每格能量）全部预分配，尺寸变了才重分配。`scratchAddresses` 供测试确认地址不变 |
| 整体对比度补偿 | `MotionAnalyzer.contrastModel` / `contrastResidual` | 两帧亮度标准差之比 g 偏离 1 ≥ 8%（0.5~2，两帧标准差 ≥ 4）时，按 cur − g·prev − b 再算残差，不到原来一半才采用：渐黑 / 渐亮、自动曝光、按比例的闪光不再算成运动（渐黑 ×0.8 / 帧：约 4.5 → 0）。偏离 < 8% 时逐位不变；真实动作解释不掉，照旧 |

没做：亚像素 / 抖动专门的防抖（只靠现有整像素平移补偿）；节奏、Vision 仍在后续。
真机要验证：切到柔焦 / 暗场 / 特写镜头后 1 s 内是否恢复力度；手盖镜头仍明显降权；渐黑转场、开关灯时不再有假输出；连续两次切换来源时手感是否平滑。

### algo-opt-3：主体运动 + 相机补偿 + 往复节奏 + 姿态辅助（v1.8.0「跟随画面」问题修正）

问题（v1.8.0 真机反馈）：① 慢慢移动的大面积皮肤特写被判成强；② 手持镜头晃动会抬高强度；③ 很小的轻动作（舔、轻抚）被判成强；
④ 固定机位后入、臀部只占画面 15~25% 的快速抽插反而只有轻档。根因是旧映射看「画面变化的总能量 / 面积」：
大面积慢动作和镜头晃动能量大，小面积快动作能量小；自动适应又会把一直很强的视频往中档压。

本轮改为**按运动区域自己的速度 / 幅度 / 节奏打分**，和「多少面积在动」无关；镜头运动先估出来扣掉；有人体时再用 Vision 姿态补强。
安全边界不变：`BLEManager.swift` / `SafetyLedger.swift` / `Protocol.swift` / `AIProgram.swift` / `Models.swift` 不动，无新发送路径（仍只在 `tick()` 里 `sendTick`），
输出仍经 `SyncOutputStage`：夹紧 [0, min(上限, 99)]、升幅 ≤ +20 / 拍、最低强度规则、STOP / 看门狗都不变。无新文件、不改 pbxproj
（Vision 由 `import Vision` 自动链接）。实时音频回调没动。

#### 数据流

```
VideoMotionTap（workQueue，15 Hz）── 64×36 亮度帧 ──▶ MotionAnalyzer.analyze
   │                                         ├─ 原有：帧差能量 / 切镜 / 近场（保留，供近场降权、切镜保持、老调用方）
   │                                         └─ 新增：BlockMotionEstimator → CameraTransform + 主体残差速度
   │                                                      └▶ SubjectFlowTracker（1.2 s P80 + StrokeRhythm）→ MotionSample.subject
   └─ 约 9 Hz 原始缓冲 + 期间合成的相机运动 ──▶ PoseWorker（poseQueue，.utility）
                                                  VNDetectHumanBodyPoseRequest → PoseMotionTracker → PoseReading
主线程 0.3 s 一拍：MotionWindowAccumulator.drain → MotionNormalizer.subjectStep（PoseBlend 融合 → 近场收拢 → 自动适应 → 灵敏度）
                   → MotionShaper → SourceHandover → SyncOutputStage（不变）
```

#### 1. 块运动 + 相机补偿：`BlockMotionEstimator` / `CameraTransform`

| 参数 | 值 | 说明 |
|---|---|---|
| 网格 | 8 × 6 块（和 `MotionAnalyzer` 的格子一致），每块加 2 像素边 | 64×36 分析帧上每块约 8×6 像素 |
| 搜索 | ±8 像素，先隔点粗搜再 ±1 细搜，抛物线亚像素 | 去均值 SSD：局部变亮变暗不算动 |
| 静止块 | 零位移 rms ≤ 3 → 没动；纹理 rms ≥ 6 的静止块当可靠零向量参加相机拟合 | 压缩噪声不算动 |
| 可靠向量 | 最小曲率 ≥ 4、两方向曲率比 ≥ 0.1、最佳匹配能解释 ≥ 50% 变化（且 ≥ 9）、没顶到搜索边界 | 一条边 / 没纹理的块走「法向流」（只给大小，≤ 6） |
| 混合块 | 只拿 \|帧差\| > 12 的像素再搜（≥ 6 个像素、截断 40²、位移惩罚 0.005），能解释 ≥ 50% 才用 | 静止背景里一小块在动（如臀部只占一块的一部分）也能测到速度；只算主体，不参加相机拟合 |
| 相机拟合 | 可靠块 ≥ 8 → 中位数平移 → 内点（容差 1 + 0.1 × 位移）→ 最小二乘相似变换（缩放 / 旋转 ≤ 8%）→ 再取内点重拟合 | 平移 + 轻微缩放 / 旋转 |
| 判为相机在动 | 位移 ≥ 0.6 像素且内点份额 ≥ 0.6、比「不动」多 0.2 余量；份额 = 内点 / (可靠块 + 2 × 有争议块) | 有争议块 = 既不可靠又解释不了的块：大片在乱动时不轻易判成镜头运动 |
| 在动的块 | 残差 > 0.75 + 0.2 × 相机位移 | 扣掉相机后 |
| 主体速度 | 在动的块的 P80（像素 / 名义帧 1/15 s），≥ 3 块满额，1~2 块按比例；大半画面一致地动时 × (1 − 0.35·…) | 和面积无关 |

`CameraTransform` 是分析帧像素坐标上的复数相似变换 z' = m·z + t；`then` 合成连续几帧（姿态隔几帧才算一次，用合成后的那段扣相机）。
`MotionAnalyzer.lastCamera` / `cameraContinuous` 给出上一个帧间隔的相机运动和能否连上（参考帧 / 切镜 / 保持期 / reset 后为 false）。

#### 2. 往复节奏与打分：`StrokeRhythm` / `StrokeScore` / `SubjectFlowTracker`

- `StrokeRhythm`：最近 4 s 带方向的速度 → 主轴投影 → 15 Hz 重采样 → 归一化自相关；滞后 4~30 格（3.75~0.5 Hz）；
  取不低于最高峰 85% 的最短周期（用抛物线插值后的峰值比，避免非整数滞后 / 不均匀采样把 2 Hz 判成 1 Hz）；至少 12 个样本、跨度 ≥ 1.5 s。
  输出 hz、confidence（峰值 0~1）、amplitude（单程幅度 ≈ √2·rms / 2πf）。
- `StrokeScore`：速度分 = 对数斜坡（块运动 0.7 → 4.5 像素 / 帧；姿态 0.12 → 2.2 躯干长度 / 秒）；
  节奏分 = 置信度斜坡(0.3 → 0.7) × 频率斜坡(0.6 → 1.8 Hz) × (0.4 + 0.6 × 幅度斜坡)（块运动幅度 1 → 6 像素；姿态 0.03 → 0.25 躯干长度）；
  分数 = 速度分 × (0.72 + 0.28 × 节奏分) + 0.15 × 节奏分 × 速度分（一直快但没节奏 ≈ 0.72 × 速度分；又快又有节奏 → 1）。
- `SubjectFlowTracker`：最近 1.2 s 每帧主体速度的 P80 + 节奏 → `MotionSample.subject`（valid / score / speed / hz / rhythm / amplitude）；
  切镜时重新攒历史，读数先保持切镜前的（不出尖峰也不突然归零）。

#### 3. 姿态辅助：`PoseWorker`（`VideoMotionTap.swift`）/ `PoseMotionTracker` / `PoseBlend`

- 取帧：每帧分析完把相机运动合进「上次提交以来」那一段；约 9 Hz（15 Hz 拉帧时每 5 帧提交 3 帧）把原始缓冲交给独立 `.utility` 串行队列。
  上一次没跑完就跳过（不排队、不阻塞画面分析）；发热 `.serious` 起不提交（画面分析自身 `.serious` 降到 8 Hz、`.critical` 暂停，不变）；Vision 连续出错 3 次停用。
- 方向：读视频轨 `preferredTransform` → `PoseOrientation`（up / down / left / right）→ Vision 的 `CGImagePropertyOrientation`，结果再换回缓冲（分析帧）坐标。竖拍视频也能认出人。
- `PoseMotionTracker`：11 个关键点（鼻、颈、双肩、根、双髋、双膝、双腕），点置信度 ≥ 0.3、人置信度 ≥ 0.3、至少 4 个点；
  关节速度按躯干长度（或肩宽、包围框对角线；0.8 s 平滑、≥ 0.06 × 帧高）归一 → 远近 / 缩放无关；先扣相机运动、再扣全身一致的平移（中位数，只留 40%）；
  检测抖动：每个关节先做 0.08 s 时间常数的指数平滑（平滑状态随相机运动搬），平滑后的位移再减 0.015 躯干的死区（点置信度 < 0.6 时按 0.6 / 置信度放大），
  静止的人 1.5~2% 躯干的关键点抖动 → 0；速度刻度相应改为 0.14 → 1.8 躯干 / s；
  分组权重 头 1.0 / 肩 0.7 / 髋 1.0 / 膝 0.6 / 腕 0.35；最近 1.2 s P80 + 髋 / 头的往复节奏 → `StrokeScore.pose`；
  髋 / 头这组 0.5 s 没有新样本（被挡住 / 出画）就不再用它的旧节奏；
  换人判定：中心偏离预测位置 > 1.5 个身体尺度就按置信度 × 尺度重选；帧间隔 0.02~0.4 s 才连起来算速度；换人 / 断过时速度历史和节奏一起清。
- `PoseBlend`（在 `MotionNormalizer` 里每拍一次）：累计有人 ≥ 0.55 s（至少 2 拍）才用姿态；没人 0.9 s 内保持上一次的姿态分数；
  权重 1 s 升到最多 0.8 × (0.5 + 0.5 × 置信度斜坡 0.3 → 0.6) × (0.5 + 0.5 × 关节可信度)、1.5 s 降回 0
  （关节可信度：髋这组有可用关节 = 1，只有头 = 0.5，都没有 = 0）；
  s = max(w × 姿态分 + (1 − w) × 块运动分, 块运动分 × (1 − 0.4 × w))：姿态只细化、不否决强的块运动（认到的是静止的人 / 髋不可用时，
  块运动 0.9 的输出约保留 0.65 / 0.74）。检测一闪一闪不出尖峰。
  切镜后的画面里没人：不保持，直接降权重；同一拍里切镜前的读数、切镜后才回来的旧帧读数都不算有人（MotionWindowAccumulator 记最近的切镜时间）。
  分析连续停（发热 `.critical` 暂停 / 缓冲）超过 0.9 s，恢复后姿态融合从头确认。
- 界面：姿态权重 ≥ 0.2 时「画面」条下显示「已识别人体姿态，按动作幅度和节奏跟随」。seek / 跳转（`resetMotionSide`）、拆掉取帧时姿态融合从头确认。

#### 4. 映射：`MotionNormalizer.subjectStep`

窗口里有主体读数（`subjectFrames > 0`）时按主体分数映射，不再看画面变化的面积 / 整幅均值（老调用方手搭的窗口没有读数，仍走原来的能量映射，逐位不变）：
近场 / 遮挡时往 0.3 收拢 N 倍（只降不升）；自动适应只做两件事——减掉这个视频安静时的底（最多 0.08）、动作一直偏小的视频最多放大 1.25 倍
（「动得多」参考 ≥ 0.7 就不放大）。**从不往下压**：持续的快速抽插不会被自动适应压到中档。灵敏度 dB 照旧。

#### 5. 性能

- 块运动 + 主体 + 节奏：本机 x86 -O 约 0.49 ms / 帧（含原有分析）；15 Hz 下 < 1% 单核。新缓冲全部预分配，稳态零分配（测试按 `scratchAddresses` 核对 26 个新缓冲地址不变）。
- 姿态：Vision 在 `.utility` 队列上约 9 Hz，自己做缩放；只在 `.nominal` / `.fair` 跑。主线程只在锁里取几个数。
  每次跑完至少空闲「这次耗时 × 0.5」（最多 1 s）再提交：慢设备上单次超过 1/9 s 时姿态队列最多约 2/3 时间在跑。

#### 6. 测试（`Tests/VisualSyncChecks/main.swift`「algo-opt-3」，本地 191 项全部 PASS）

合成场景 14 s、经完整链路（`MotionAnalyzer` → 窗口 → `MotionNormalizer` → `MotionShaper` → `SyncOutputStage`）取后段中位数：

| 场景 | 结果（上限 99） | 断言 |
|---|---|---|
| 60% 画面慢动（0.5 Hz、约 1 px/帧） | 8 | ≤ 快动 × 0.5 且差 ≥ 25 |
| 60% 画面快动（2 Hz、约 4 px/帧） | 68 | — |
| 80% 静止 + 10% 轻动（1 Hz、约 1 px/帧） | 12 | ≤ 30 |
| 静止背景 + 20% 快速往复（2 Hz、4 px/帧） | 99（上限 60 → 60；自动适应关 99） | ≥ 70、上限 60 时 ≥ 42、比慢动 / 轻动高 ≥ 30、自动适应开 / 关相差 ≤ 10 |
| 有纹理的静止画面 + 手持抖动（±5 px + 轻微缩放） | 0 | 均值 ≤ 10、最高 ≤ 20；不抖时最高 ≤ 3 |
| 手持晃动 + 20% 快速往复 | 54 | ≥ 晃动 + 30 |
| 升幅 | — | 每拍 ≤ +20 |
| 相机检测率 | 抖动 177 / 209 帧判为相机；20% 往复 0 帧；60% 快动 14 帧 | 抖动 ≥ 70%；20% 往复 ≤ 5%、60% 快动 ≤ 20% |
| 节奏频率 | 2 Hz → 2.0、0.5 Hz → 0.5、1 Hz → 1.0 | 误差分别 ≤ 0.25 / 0.15 / 0.2 Hz |

另有：`CameraTransform.then` 合成；姿态（15 Hz 块运动 + 每 5 帧 3 帧姿态的合成骨架）：髋部 2 Hz 往复 → 82.6、hz 2.00（≥ 70）；只点头 → 0（≤ 20）；
随镜头平移 / 整个人线性平移 → 0 / 0（≤ 5 / ≤ 10）；骨架放大 2 倍 → 结果完全相同；检测一闪一闪 → 最大 71.6 ≤ 正常值、单拍跳变 1.4；一两拍误检 → 权重 0；
`PoseOrientation.from` / `bufferPoint` 和 `preferredTransform` 四个方向往返一致；新缓冲稳态零分配。原有 algo-opt-1 / 2 及更早的检查全部保持通过。

#### 7. 真机验证清单

1. 慢慢移动的大面积皮肤特写：强度应在低档（参考 < 20），不再判成强。
2. 手持拍摄、画面里没人动 / 只轻微动：晃动时强度接近最低（参考 ≤ 10）；`Status` 不应误报。
3. 舔、轻抚等小幅轻动作：低到中低档（参考 ≤ 30）。
4. 固定机位后入、臀部占画面 15~25% 的快速抽插：高档（参考 ≥ 70，上限 60 时贴近 60），持续几分钟不被自动适应压到中档；节奏变慢时强度跟着降。
5. 手持 + 快速抽插：仍明显高于纯晃动。
6. 竖拍视频（preferredTransform 旋转 90° / 270°）与横拍、倒置视频：姿态提示能正常出现，强度和横拍一致。
7. 姿态提示「已识别人体姿态，按动作幅度和节奏跟随」：有人时 1~2 s 内出现，人离开 / 切镜后 1~2 s 内消失，不闪烁；seek 后重新确认。
8. 发热：`.serious` 起姿态停跑（提示随后消失）、画面分析按原逻辑降频 / 暂停；长时间播放的温度、耗电与 v1.8.0 对比。
9. Instruments：`MotionAnalyze` 每帧耗时（目标 < 2 ms）；姿态队列不影响 15 Hz 拉帧；主线程无卡顿。
10. 安全回归：STOP、看门狗、断连、上限 / 最低强度、关联动立刻归零，与 v1.8.0 一致。

### rhythm-follow P0 / P1：伸缩跟随动作频率（只跟快慢，不对相位）

**目标**：画面里动作每秒往复几次，设备伸缩也尽量每秒往复几次。0x08 帧只能发档位（Protocol.swift 不改，视频路径尾字节固定 0），
没有位置 / 相位可发，所以 P1 只做频率；「往里对往里」的相位对齐不在范围内（见研究报告 P2）。默认关，老用户无感。

**P0（真机标定，需要用户做）**：`docs/rhythm-calibration.md`——先确认伸缩是速度档还是幅度档，再量 10~99 档的往复次数、响应时间、STOP 位置，
结果填进 App 的「设备标定表」。`Tools/make-rhythm-test-videos.sh` 生成已知频率的测试视频（0.5 / 1 / 2 / 3 Hz 常频、1→2 Hz 阶跃、0.5→3 Hz 扫频，最右端有咔哒声）。

#### 数据流

```
VideoMotionTap ─ MotionAnalyzer（块运动主体：StrokeRhythm.estimate → subjectHz / 分数（不变）；
               │                 StrokeRhythm.followEstimate → followHz / followRhythm / followAmplitude）
               └ PoseMotionTracker（髋 / 头 / 腕三组 StrokeRhythm.followEstimate → rhythmPick → rhythmHz / rhythmConfidence /
                                    rhythmPart / rhythmRate；score / hz 仍用 estimate）
        → MotionWindowAccumulator.drain() → MotionWindow（subjectFollow* 三个、poseRhythm* 四个字段，最后一个有效值；
                                                       切镜 / 保持期样本不带跟随值）
        → VideoSyncPlayer.motionTick：
             activity = RhythmOutput.motionActivity(level, smoothed, confidence)  # activity(置信度 × min(门前即时强度, 平滑值))：≤ 2 → 0，≥ 25 → 1
             RhythmFollower.step(window, dt, active: activity > 0)  # 合成「现在的动作频率」+ weight
             DeviceRateMap.level(forHz:)                # 频率 → 伸缩档位（标定表 / 估计值）
             RhythmOutput.target(value, …, rateLevel, weight, activity)   # 伸缩按频率（weight × activity）、震动照旧按强度
             SyncOutputStage.step(levels:)              # 同一套：上限 / 升幅 ≤ +20 / 拍 / 归零保持
             RhythmOutput.statusText(…, thrust: 实际发出的伸缩档位)       # 状态行
        → ble.sendTick（仍只在 tick 里，变化才发）
```

#### 类型（`VisualSync.swift` 末尾「rhythm-follow P1」）

| 类型 | 作用 | 关键参数 |
| --- | --- | --- |
| `DeviceRateMap` | 档位 ↔ 次/秒的单调分段线性表；`parse` 认「档位:次数」，逗号 / 分号 / 顿号 / 空白 / 换行分隔，全角冒号逗号分号也认，冒号两边可有空格 | 2~12 点，档位 1~99、0.1~8 Hz，严格递增，≤ 400 字；`uncalibrated` = 10:0.5, 99:3.0 |
| `RhythmCandidate` | 一拍的频率候选（flow / pose / both） | — |
| `RhythmFollower` | 候选 → 锁定 / 平滑 / 跳变确认 / 丢失保持 → `hz`、`weight` | 0.4~4 Hz；块运动要主体分数 ≥ 0.05、幅度 ≥ 1 px；姿态要姿态分数 ≥ 0.1（挑中腕时 ≥ 0.2）；两路差 ≤ 15% 合并（置信度 +0.1）；不一致且块运动频率 > 姿态采样率 × 0.4（或不知道采样率）时取块运动（不论差多少）；其余取高的（姿态 +0.05）；只有姿态时姿态采样率 ≥ max(2.5 × 读数, 6) 才给；锁定 0.40 / 释放 0.30；log 域平滑 τ 1.5 s（±30% 以内）；同方向偏离 > 15% 的读数记待确认，≥ 2 拍、累计 ≥ 0.6 s − 半拍（每拍最多算 0.3 s）、彼此一致（最大 / 最小 ≤ 1.45）、对数平均偏离 > 30% 才跳到对数平均；锁定中一拍没候选不清待确认，连续缺 0.6 s 才清；画面还在动时丢失保持 1.5 s；切镜马上解锁；画面不动（`active` = false，窗口有帧）没锁定时不锁、锁定中连续 2 拍才解锁（第 1 拍按丢失保持）；`frames` = 0 的窗口当没信息，按丢失保持；weight 1 s 升 / 1.5 s 降（不动 / 切镜 0.3 s） |
| `RhythmOutput.target` | 原来的映射 + 通道分配，伸缩通道按 **weight × activity** 插值到 `min(上限, max(最低强度, min(节奏档位, 弱动作上界(m))))`，m = 上限之前的强度档位（`map(value, cap: 100, floor: 0)`）；弱动作上界：m ≤ 20 时 max(m + 12, 2m)，20~30 线性放开到 99，m ≥ 30 为 99（不设上界） | activity：画面自己的强度 ≤ 2 → 0、≥ 25 → 1（播放器用门前即时强度和平滑值里小的那个，动作一停当拍归 0）；弱动作（点头 / 手势，强度 10 / 15）节奏最多把伸缩抬到 22 / 30 档（全 weight 时；上限 100 下 activity 部分交接后约 14 / 23 档），和用户上限无关；画面强度为 0 时伸缩就是原来的档位（节奏不加任何伸缩）；「仅震动」、没信号、没节奏档位、activity 0 时与原路径逐位相同 |
| `RhythmOutput.statusText` | 状态行（纯展示，可测） | 显示实际发出的伸缩档位；按 weight > 0 判断节奏是否起作用；「比设备最快 / 最慢」和「已到上限」各自独立提示；弱动作上界压低了节奏档位时提示「动作偏弱」（这时不报「已到上限」） |
| `SyncOutputStage.step(levels:)` | 和 `step(value)` 共用 `limit`（上限、升幅、归零保持） | 不变 |
| `VisualSyncSettings` | `rhythmFollow`（`bcVisualSyncRhythmFollow`，默认 false）、`rateTable`（`bcVisualSyncRateTable`，默认 ""，≤ 400 字） | `rateMap` 填错 / 没填 → 估计值 |

姿态侧新增腕组（`wristGroup`，只给节奏、不进 score），`PoseReading.rhythmPart`：0 无 / 1 髋 / 2 头 / 3 腕；`rhythmRate`：挑出的那组最近 4 秒的实际采样率。

**`StrokeRhythm` 的减半只给频率跟随（r1 复审 M1 / L7）**：真实视频的 2 Hz 在 15 fps 上是 7.5 格一个周期，块匹配速度有量化、
相邻两下形状不同，自相关 7/8 格只有 ~0.67、15 / 30 格 1.0，原来 85% 的规则会报 1 Hz（用生成的 2 Hz 视频和 1→2 Hz 阶跃复现）。
`estimate`（进 StrokeScore 的 hz / 置信度 / 幅度）**保持 algo-opt-3 的算法不变**；另给一个 `followEstimate`：选中周期后再看
「正好一半处」（插值后 ±0.75 格）有没有 ≥ **最高峰** 55%、且自相关本身 ≥ 0.3 的峰，有就减半，**最多一次**（`halvedLag`，纯函数）。
推拉不对称的真 1 Hz 在半周期上是负相关，不受影响（有测试钉住）。`followEstimate` 还带窗口里样本的实际采样率，
跟随频率高于采样率 × 0.4 时不给（L3：慢设备上 Vision 节流到约 3 Hz 时，1.2 Hz 以上看不清）。

**开关关着时与 algo-opt-3 逐位相同**：分数路径的 `estimate` 算法没变（测试里放了 07ac4d4 `StrokeRhythm` 的原样拷贝逐位比对，
`SubjectFlowTracker` 的分数 / hz / 置信度 / 幅度也逐位比对）；VideoSyncPlayer 关着时仍走 `SyncOutputStage.step(value)` 和 `preview`
（和 07ac4d4 `SyncOutputStage` 原样拷贝随机比对 3000 组）。腕组的 StrokeRhythm 关着时也在算，但只进 rhythm* 字段，不影响输出。

#### 界面（`VideoSyncView.swift`）

- 「画面」灵敏度区：开关「伸缩跟随动作频率」；打开后显示「设备标定表」输入框 + 提示（已标定范围 / 没标定 / 格式不对）。
  输入框编辑的是草稿（`rateTableDraft`），按「完成」、收起键盘或输入框消失时才写回 `rateTable`：打字过程中半截的表（如「…, 99:2」）不会生效；
  提示按草稿算，没写回时注明「按「完成」或收起键盘后生效」。
- 仪表区：`rhythmStatus` 一行（`RhythmOutput.statusText`），显示这一拍实际发出的伸缩档位（联动关着时是预览值），例如
  「动作节奏 1.8 次/秒 → 伸缩 46 档」「（节奏丢了，正在交回动作强度）」「（画面没在动，伸缩不跟节奏）」「（比设备最快的 2.8 次/秒还快）」「（已到上限 60）」「；设备还没标定，档位是估计值」。
  联动关着时强度条预览也算上节奏（开关关着时预览照旧）。
- 所有 `motionShaper.reset()` 处同时 `resetRhythm()`（seek、缓冲、切来源、关联动、新视频、拆取帧）；开关切换时也从头确认。
- 频率按画面帧的显示时刻（host 时间轴）算，倍速播放时已是实际看到的快慢，不再乘倍速。

#### 安全不变

不改 BLEManager / SafetyLedger / Protocol / AIProgram / 工程文件；只换伸缩的**目标档位**，出口照旧上限夹紧、升幅 ≤ +20 / 0.3 s、归零保持 2 拍、STOP / 看门狗 / 关联动归零不变；仍只在 `tick()` 里 `sendTick`。

#### 测试（`Tests/VisualSyncChecks/main.swift`「rhythm-follow P1」）

标定表解析 / 校验 / 插值单调 / 反查；候选合并与冲突、相机抖动 / 小幅度 / 越界 / NaN 不算；跟随器稳态、±10% 抖动、1→2 Hz 阶跃 0.6 s 确认后到位、
单拍倍频误检不跟、回差、丢失保持 1.5 s、weight 斜率、NaN dt；3000 组随机输入经 `step(levels:)` 后 ≤ 上限、升幅 ≤ 20、归零保持、只用两个通道；
没有节奏档位 / activity 0 时与 `step(value)` 逐位一致；合成画面 1 / 2 Hz 端到端锁定并给出不同档位、静止 / 纯抖动不锁定、抖动 + 主体照样锁定；
腕 1.5 Hz → 取腕（采样率约 9 次/秒）、髋 2 Hz → 取髋；设置默认值 / 坏值 / 超长 / 键名。

r1 复审新增：
- M1：`estimate` 和 07ac4d4 `StrokeRhythm` 原样拷贝逐位相同（半整数周期 2 Hz、推拉不对称 1 Hz、带噪声的二维信号、约 9 Hz 不均匀采样），
  `SubjectFlowTracker` 的分数 / hz / 置信度 / 幅度逐位相同；`followEstimate` 上半整数周期 2 Hz ≈ 2 Hz；开关关着的出口 / 预览和 07ac4d4 原样拷贝逐位相同。
- M2：画面强度 0 时伸缩为原来的档位（没有最低强度就是 0）；强度 8.5 交接一半；动作停了（窗口里还留着旧节奏）伸缩 ≤ 0.5 s 归零、不重新锁定；
  切镜后 ≤ 0.5 s 回到按强度；画面不动不锁定；姿态分数 < 0.1（腕 < 0.2）不算；切镜 / 保持期样本不带跟随频率。
- M3：锁在 1.4 Hz、读数 2.0 / 2.4 交替 → ≤ 1.5 s 跟到 ≈ 2.19 Hz；1.7 / 2.4 交替 → ≈ 2.02 Hz；单拍离群不跟。
- L2：dt 0.65 s 的单拍离群不跟；0.1 s 一拍时第 6 拍（0.6 s）才确认。
- L3：姿态 3 Hz 采样、和块运动差一个八度时取块运动；15 Hz 采样的 1.4 Hz 照常给，3 Hz 采样时 > 1.2 Hz 一律不给。
- L4：状态行（实际档位、超速与上限同时提示、交接期 / 画面不动的说明）。
- L5：空白 / 顿号 / 全角分隔、冒号两边空格。
- （r2 见下）
- L7：`halvedLag` 直接喂自相关：真 2 Hz 减半到 7.5 格；0.5 Hz 最多减一次；弱峰 < 0.3、不到最高峰 55% 不减；带噪声 / 量化的 0.5 / 1 Hz 一次都不减；
  随机噪声里跟随频率不超过基础估计的 2.5 倍。

r2 复审新增：
- M1：真实 `MotionShaper` 链路（门 + 0.7 s 释放平滑）阶跃 60→0 和 1.8 s 逐渐落到 0：落到 0 那一拍起伸缩 ≤ 节奏关着的伸缩（以前停下后 0.9 s 还在 63 档）；
  `motionActivity` = activity(置信度 × min(即时强度, 平滑值))。
- L1：锁在 1 Hz、真 2 Hz、置信度 0.45 / 0.25 隔拍交替 → 0.9 s 跟到 2 Hz（以前 30 s 停在 1 Hz）；连续缺 0.9 s 后待确认清掉。
- L2：2 Hz ±20% 逐拍抖动 60 s 频率 1.82~2.16、拍间 > 10% 的跳 0 次；2.0 + 1.35 不一致不跳；dt 0.29 s 2 拍确认、0.1 s 仍 6 拍。
- L3：3.5 Hz 采样时姿态 1.5 / 块运动 2.0 → 2.0；只有姿态时 3 Hz 采样的 1 Hz、不知道采样率不给，8 Hz 采样的 1.5 Hz 照常给。
- L4：节奏 1.5 Hz（46 档）时强度 10 → 14 档（原 10）、15 → 23 档（原 15），强度 40 照样到 46 档。
- L5：3000 组随机出口检查按生产的 zeroAge 数归零保持（刚归零那拍算 0，非 0 → 0 后至少连续 3 拍 0），保持少一拍会被测出。

r3 复审新增：
- M1：弱动作上界改按上限之前的强度算再和上限取小（以前按乘过上限的档位算：上限 40 时 1.5~3 Hz 全是 22 / 24 / 32 档，频率不起作用）。
  标定表 10:1.0, 30:2.0, 50:3.0 下，上限 40 / 60、强度 30 / 40：2 Hz 30 档、3 Hz 40 / 50 档；估计值表上限 99、强度 30：2 Hz 63 / 3 Hz 99（以前都是 60）；
  强度 10 / 15 在上限 40 / 60 / 100 下都 ≤ 22 / 30；状态行「动作偏弱」。
- L1：置信度 0.35 靠滞回锁着时，一拍 `frames` = 0 或门一拍没开（有帧、强度 0）不丢锁：伸缩 63 → 23（当拍按强度）→ 43 → 63；
  连续 2 拍有帧不动照样解锁；动作停下的端到端释放检查不变（停下那拍起 ≤ 节奏关着）。

`make-rhythm-test-videos.sh` 的 6 个视频离线跑（常频 0.5 / 1 / 2 / 3 Hz 锁到 ±1%，阶跃 4 s 内跟上，扫频滞后 1~3 s、有一次短暂跳到 1/3 频率）是 r1 之前的版本，
减半规则改成「最多一次、按最高峰、≥ 0.3」后需要重跑确认。`VideoSyncView.swift` 的 SwiftUI 部分 Linux 编不了，需要 Xcode 编译确认。

#### 真机验证清单

1. P0 标定做完、表填进 App，输入框下面显示「已标定：…」。
2. 测试视频 const-1hz / 2hz：状态行 3~6 s 内显示 ≈ 1.0 / 2.0 次/秒，设备实际往复次数与视频接近（±15%）。
3. step-1to2hz：20 s 后 2~4 s 内设备明显变快；中途不来回跳。
4. 真实视频：快慢变化能跟上；动作停下（画面强度归零）或切镜后 0.5 s 内伸缩回到按强度、状态回到「还没找到稳定的动作节奏」；
   人还在、检测一闪而过时节奏保持 1.5 s 不掉。光说话比划手势 / 点头（画面强度低）时伸缩只比按强度略高（强度 10 → 约 14 档、15 → 约 23 档），不会被拉到节奏档位。
   注意：「动作停下」以画面强度（主体分数 P80，约 1.2 s 窗口）落到门下为准，这一段滞后节奏开关两边一样；落到门下那一拍起伸缩不高于节奏关着时。
5. 上限 60 / 最低强度 20：伸缩档位不超过 60、不低于 20；「仅震动」时不跟频率。
6. 关掉开关：行为与 algo-opt-3 完全一样（分数 / 出口逐位相同，测试钉住）。
7. 标定表：播放中改表，打字过程中设备不变，按「完成」后才按新表出档。
8. 安全回归：STOP、看门狗、断连、关联动立刻归零。

### rhythm-phase P2：相位对齐（画面往里时伸缩加强；相位锁 + 0.1 秒子拍脉动，默认关）

**目标**：在 P1「伸缩每秒几下跟画面」之上，让设备在画面「往里」那半拍更强、「往外」那半拍更弱。
**边界**：0x08 帧只能发档位，设备没有可用的位置反馈（FFA2 含义未知，只被动观察），所以 P2 是**开环预测**：
从画面估出往复的相位 → 锁相环（PLL）平滑并外推 → 按「延迟补偿」提前发 → 在 P1 的伸缩档位上叠一个和画面同频的脉动。
设备自己的往复并不受控，脉动改的是每个周期里伸缩档位（速度）的高低；对得准不准要靠真机标定（`docs/rhythm-calibration.md` 第 8 节）。
相位不可靠（没锁上、没标定、太快、太弱、切镜、动作停了）时一律退回 P1（只跟频率，逐位相同）。

#### 数据流

```
VideoMotionTap ─ MotionAnalyzer → SubjectFlowTracker：followEstimate 有频率时 StrokeRhythm.phaseFit(hz) → SubjectReading.phase
               └ PoseMotionTracker：挑出的那组 phaseFit(hz, lag: smoothingLag) → PoseReading.rhythmPhase（补上关节 EMA 的滞后）
        → MotionWindowAccumulator.drain() → MotionWindow.subjectPhase / posePhase（这一拍最后一个有效拟合，带时间戳；切镜清掉）
        → VideoSyncPlayer（Timer：P2 开着时 0.1 秒，每 3 次里 1 次走完整拍）
             完整拍 motionTick（原来 0.3 秒的全部逻辑，dt 仍按完整拍算）：
               RhythmFollower.step                       # P1 不变
               RhythmPhaseLock.step(window, followerHz/Locked/Source, now: host 时间, dt, active)
               RhythmOutput.target(…)                     # P1 的目标档位 levels
               RhythmPulseDriver.beat(levels, lock, …)    # 能脉动 → 叠脉动、按时间限速；不能 → 原样 step(levels:)
             子拍 pulseSubTick（完整拍之间的两次）：
               RhythmPulseDriver.subBeat(lock, now)       # 只在上一个完整拍在脉动时出值：同一个 levels，只重算伸缩脉动
        → 同一个 outputStage（上限 / 升幅按时间 ≤ +20 / 0.3 秒 / 归零保持 0.85 秒 / 通道 3、4 恒 0）→ 变化才 ble.sendTick
```

#### 类型（`VisualSync.swift`「rhythm-phase P2」）

| 类型 | 作用 | 关键参数 |
| --- | --- | --- |
| `StrokeRhythm.phaseFit(hz:lag:)` / `PhaseFit` | 最近 2 个周期（夹在 1~3 秒）的二维速度做主成分取主轴，在 hz × (1 − 6%, 1, 1 + 6%) 上做正弦最小二乘 + 抛物线细化，得到最后一个样本时刻的**位移相位**（0 = 主轴正方向最远点，−π~0 = 往正方向走）；样本时间按差分中点算 | ≥ 8 个样本、跨度 ≥ 0.9 个周期；主轴正方向约定：竖直分量 ≥ sin 20° 取向下，否则向右，之后保持连续（夹角 > 60° 才重取，`epoch` + 1）；输出 `quality`（R²）、`linearity`（λ1 / (λ1 + λ2)）、`amplitude`；只读环形缓冲，`estimate` / `followEstimate` 逐位不变 |
| `PoseMotionTracker.smoothingLag` | 关节位置指数平滑（τ = `jitterSeconds`）在 hz 上的时间滞后 | 9 次/秒、1.5 Hz 时约 26 ms |
| `RhythmPhaseLock` | 读数门 → 捕获 → PI 锁相 → 外推 `phase(at:)` → `weight` | 读数：拟合 ≥ 0.5 锁 / ≥ 0.3 保持、线性 ≥ 0.65（画圈不要）、幅度 ≥ 块运动 1 px / 姿态 0.03、拟合频率和跟随频率差 ≤ 15%、读数不旧于 0.6 秒；姿态读数要采样率 ≥ max(4 × 频率, 6)；来源跟 `RhythmFollower.source`（both 时取拟合高的，当前来源 +0.05）。捕获：1 秒内 2 个读数按跟随频率外推一致（≤ 60°）才锁；PI：相位增益 0.35、频率微调增益 0.08、微调 ≤ ±10%；单个读数偏 > 90° 不跟，连续 2 个彼此一致才重新对齐（漏拍 / 抖动 / 主轴翻转都容忍）；读数没了保持 1 秒；跟随频率变 ≤ 15% 在当前时刻接上（相位连续），> 15% 重锁；切镜 / 跟随器解锁 / 有帧但不动 2 拍 → 立刻放开、weight 0；没帧的一拍不算；weight 1 秒升、0.5 秒降 |
| `RhythmPulse` | 波形 / 深度 / 档位（纯函数） | 波形：峰后 30% 周期线性降到谷、70% 周期线性升回峰（慢升快降：降不限速、升要守 +20 / 0.3 秒）；峰在位移相位 −45°（往里那半拍的后段）；深度 = min(设置, 66.7 × 0.7 / hz) × fade × 锁相 weight × 跟随 weight × activity × 强度斜坡，fade：2~2.5 Hz 线性到 0，≥ 2.5 Hz 不脉动，强度斜坡：上限前强度 20 → 0、30 → 1（点头 / 手势不脉动），< 2 档不脉动；档位：以 P1 档位为中心 ±d/2，谷 ≥ max(最低强度, 8)（运行中全 0 会变成停止帧对），峰 ≤ 上限，顶到上限时整体往下挪（只往下脉动），P1 档位低于谷值不脉动 |
| `RhythmPulseDriver` | 完整拍 / 子拍调度 + 状态行 | `takesFullBeat`：距上一个完整拍 ≥ 0.3 − 0.035 秒；完整拍先 `disarm`（这一拍提前返回时子拍不再按旧档位脉动）；`plan`：关着 → off；没标定 → uncalibrated；仅震动 → vibrationOnly；没锁 → unlocked；≥ 2.5 Hz → tooFast；深度 0 → weak；否则 active；不在脉动且上一次出口也不是按时间算的 → 原样 `step(levels:)`（P1 逐位相同）；`reset` 保留完整拍计时（开关 / 重建 Timer 时完整拍间隔不缩短） |
| `SyncOutputStage.step(levels:settings:elapsed:)` | 同一个 `limit`，按距上一次出口的实际时间限速 | 每通道预算 = 余数 + 20 × min(elapsed, 0.3) / 0.3，向下取整、≤ 20，小数余数留到下一次（0.1 秒 ≈ 6.67 档）；归零保持按时间 ≥ 0.85 秒（0.3 秒一拍时和原来的 2 拍逐位相同）；elapsed = 0.3 时和 `step(levels:)` 逐位相同 |
| `VisualSyncSettings` | `rhythmPulse`（`bcVisualSyncRhythmPulse`，默认 false）、`pulseDepth`（`bcVisualSyncPulseDepth`，默认 20，0~40）、`pulseLatencyMs`（`bcVisualSyncPulseLatencyMs`，默认 200，0~600）、`pulseInvert`（`bcVisualSyncPulseInvert`，默认 false） | 越界夹紧、NaN / 坏值回默认；`tickInterval`：跟随画面 + 频率跟随 + 相位脉动三个都开才 0.1 秒，否则 0.3 秒 |
| `NotifyPeriodProbe`（+ `ManualControlView.NotifyProbeMonitor`） | FFA2 通知的被动观察：最近 20 秒条数 / 速率、会变的字节、0.3~5 Hz 周期变化的字节（正弦 R² ≥ 0.5）、计数器字节 | 只读 `ble.lastNotifyHex`，最多每秒刷新一次摘要；**不参与控制** |

#### 界面

- 「伸缩跟随动作频率」打开后多一个开关「相位脉动（实验）」；打开后：脉动深度滑杆（0~40 档，步长 5）、延迟补偿滑杆（0~600 ms，步长 20）、
  「方向反转」开关、说明（开环预测、需要先标定、什么时候只跟频率）。
- 仪表区：P1 状态行下面多一行 `pulseStatus`（已对上（拟合 R²）/ 峰谷差 / 延迟补偿 / 方向已反转 / 已到上限只往下脉动；没标定 / 仅震动 / 没对上 / 太快 / 偏弱时说明在只跟频率）。
- 手动页 → 设备详情：「FFA2 观察」一行（真机判断 FFA2 有没有位置 / 行程信息）。

#### 安全不变

- 不改 BLEManager / SafetyLedger / Protocol / AIProgram / Models / 工程文件（没有新文件）；不新增发送路径：子拍和完整拍一样只在 `tick()` 里经 `outputStage` → `sendTick`（不开闸），
  STOP / 看门狗 / 断连 / 暂停 / 缓冲 / seek / 关联动的处理不变（子拍只在播放器确实在播、联动开着、三个开关都开、上一个完整拍在脉动时才出值；其余情况由下一个完整拍 ≤ 0.3 秒照旧处理）。
- 出口：≤ 上限、单步升 ≤ 20、任意两刻之间升幅 ≤ 20 × 间隔 / 0.3 + 1（P1 每 0.3 秒 +20 的包络之内）、归零后 ≥ 0.85 秒才再升、通道 3 / 4 恒 0。
  BLE 侧 `OutputWriteCoalescer` 在途只留最新一帧：0.1 秒发帧时中间帧可能被合并，但每一帧本身已按时间限速，合并只会让实际升幅更小。
- 动作停了：完整拍里 activity 归 0 → 深度 0 → 当拍不脉动、子拍停（≤ 0.3 秒）；伸缩照 P1 规则落下（降不限速）。
- **关着时和 main 逐位相同**：Timer 仍 0.3 秒，出口仍走 `step(value)` / `step(levels:)`（测试里放了 dfbfc8e `SyncOutputStage` 的原样拷贝，3000 组随机序列逐位比对）；
  画面侧的 `phaseFit` 关着时也在算，但只写新字段，不改 `estimate` / `followEstimate` / 分数。没标定、没锁上时脉动驱动也原样走 `step(levels:)`。

#### 测试（`Tests/VisualSyncChecks/main.swift`「rhythm-phase P2」）

- 出口：和 dfbfc8e `SyncOutputStage` 原样拷贝逐位相同（3000 组随机序列、step(value) / step(levels:) / seed / reset 混用）；elapsed = 0.3 时按时间和按拍逐位相同；
  0.1 秒子拍随机间隔下的升幅包络 / 单步 / 上限 / 通道 3、4 / 归零保持 0.85 秒。
- 相位拟合：0.5 / 1 / 2 / 3 Hz、15 Hz 抖动采样、横竖斜方向；约定方向（往上 / 往左差 180°）；跟随频率差 5% 细化；主轴 ±20° 晃动不翻；
  纯噪声拟合差、画圈线性低、样本不够不给；`estimate` / `followEstimate` 逐位不变；姿态 EMA 滞后补偿。
- 端到端：合成画面块左右往复 1 / 2 Hz → 窗口主体相位对上真值（向右为正，θ = 2πft − 90°）；静止画面没有合格读数；相位锁吃端到端窗口锁上。
- 相位锁：2 个一致读数锁上、1 秒升满、稳态误差、±25° 噪声滤波、跟随频率差 5% 时频率微调追上、单个 180° 离群不跟 / 连续 2 个才重新对齐、
  隔拍漏读数 + 时间抖动、没帧不解锁、切镜 / 不动 2 拍 / 跟随器解锁立刻放开、读数没了 1 秒后放开、跟随频率跳变重锁 / 小变化相位连续、各读数门、姿态采样率门。
- 脉动：波形、深度（升幅限速、淡出、weight / activity / 强度斜坡）、档位（谷 ≥ max(最低, 8)、上限往下挪、随机 5000 组）、指令相位（延迟补偿 / 反转）。
- 0.1 秒 Timer 整段模拟：1 Hz 锁上后伸缩 41~59 脉动、震动不变、峰在指令相位 −45° 附近；动作停了 ≤ 0.5 秒归零、之后没有子拍；切镜那一拍起不脉动、重新锁上后继续；
  上限 55 只往下脉动；没标定 / 开关关着 / 仅震动 / ≥ 2.5 Hz / 弱动作时完整拍和 P1 逐位相同、没有子拍；2.3 Hz 减弱；反转 + 延迟 0 时峰在 135°；全程升幅包络。
- 调度（每 3 次一个完整拍、抖动、reset / 0.3 秒 Timer 之后不缩短间隔、disarm）、状态行、设置（默认 / 键名 / 夹紧 / 读回 / tickInterval）、FFA2 观察（解析 / 周期字节 / 计数器 / 不变 / 太少 / 400 条 / 20 秒）。

`VideoSyncView.swift` / `ManualControlView.swift` 的接线（Timer 间隔切换、子拍、界面）Linux 编不了，靠 PR Checks（Xcode 16.4）编译确认，再上真机。

#### 真机验证清单

1. 开关全关：和 main 完全一样（Timer 0.3 秒、出口逐位相同）；只开「相位脉动」不开「伸缩跟随动作频率」看不到也不起作用。
2. P0 标定表填好后打开「相位脉动」：测试视频 const-1hz 上 3~6 秒内状态行变成「相位脉动：已对上」，设备伸缩一下强一下弱、和画面同频。
3. 时机：240 fps 同时拍屏幕和设备，比较方块到最右端（「嗒」声，θ = 0）和设备伸缩最强的时刻；按 `docs/rhythm-calibration.md` 第 8 节调「延迟补偿」，方向反了开「方向反转」；
   记下 0.5 / 1 / 2 Hz 各自的最佳延迟（差得多说明设备响应和频率有关，需要反馈回来）。
4. 2 Hz 以上脉动变弱、2.5 Hz 以上状态行显示只跟频率；体感上能分清强弱的大概在 1~1.5 Hz 以下（0.1 秒一档，2 Hz 一个周期只有 5 个点）。
5. 动作停下 / 切镜 / 拖进度条 / 暂停 / 缓冲：0.5 秒内脉动消失；STOP 一下就停；看门狗、断连照常。
6. 上限 60、最低强度 20：伸缩不超过 60、谷不低于 20；顶到上限时只往下脉动（状态行注明）。「仅震动」时不脉动。
7. 点头 / 比划手势 / 说话：不脉动（强度斜坡），伸缩和 P1 一样。
8. 0.1 秒发帧：观察日志里写入回执是否跟得上（`OutputWriteCoalescer` 合并属正常）、手机发热 / 耗电和 P1 比有没有明显变化。
9. 手动页固定伸缩 50 档跑 10 秒，看设备详情里「FFA2 观察」：有和往复同频的字节 / 计数器就反馈回来（后续可做闭环）；内容一直不变 → 只能开环。

#### 以后可以做

- FFA2 真带位置 / 行程：用它测设备的实际相位，把延迟补偿变成闭环自动校准。
- 航位推算：如果 STOP 后设备总停在同一个位置、且档位 → 频率的标定足够稳定，可以从开始输出那一刻按标定频率积分出设备相位，再用档位微调去追画面相位（真机确认前不做）。
- P4 提前读视频：画面分析提前跑几百毫秒，可以替代一部分延迟补偿的外推。

### rhythm-context P3：动作识别（手 / 头 / 髋 + 周期区域 ROI + 撞击声相位校正，默认关）+ P2 评审 L1–L3 修复

**目标**：P1 / P2 一直按「整幅画面的主体」或「姿态挑出的那组关节」跟频率和相位，真实视频里常常跟错部位（两个人一起动、手在画面边上、镜头晃）。
P3 多一层**上下文**：认出现在是哪种动作（插入 / 口 / 手），只按真正在做的那个部位跟频率和相位；在画面里一直往复的那块区域（周期区域）里
再做一次高分辨率块运动；视频里有和画面同节奏的撞击声时，用声音的时刻微调脉动的指令相位。
**边界**：仍是开环（设备没有位置反馈）；P3 只改「交给 RhythmFollower / RhythmPhaseLock 的那份窗口副本」和「脉动指令相位偏移」，
不改强度那条路（MotionNormalizer / SyncBlender）、不改档位规则、不改出口。认不出 / 不可信时一律退回 P2（逐位相同）。

#### 两个开关（都默认关）

| 开关 | 存储键 | 显示条件 | 真正生效 | 关着时 |
| --- | --- | --- | --- | --- |
| 动作识别（实验） | `bcVisualSyncRhythmContext` | 「伸缩跟随动作频率」打开时 | `usesRhythmContext` = 跟随画面 + 频率跟随 + 动作识别 | VideoMotionTap 不跑手 / 脸检测、不攒每块运动、不算周期区域 / 区域内运动；主线程不建 ActionContext；窗口不改 |
| 撞击声相位校正（实验） | `bcVisualSyncRhythmAudioAnchor` | 「相位脉动（实验）」打开时（方向反转下面） | `usesAudioAnchor` = `usesPulseTiming` + 撞击声 | 音频实时线程不分频带、不出块；主线程不做撞击检测；`phaseOffset` 恒 0 |

#### 数据流

```
VideoMotionTap（分析队列）
  MotionAnalyzer → BlockMotionEstimator：每块扣掉相机后的位移 residuals
    └ 动作识别开着：PeriodicityMap.add(residuals) → 每 0.3 秒按跟随频率找周期区域 PeriodicityROI
                    RoiFlowTracker：按区域裁原图（LumaCropDownscaler，放大 1.5~4 倍）→ BlockMotionEstimator（不拟合相机，整块扣整幅相机平移）
                    → SubjectFlowTracker → RoiReading（频率跟随 + 相位拟合，速度换回分析帧像素）；切镜 / 保持期样本不带
  PoseWorker（姿态队列）：身体（原有）+ 动作识别开着时手（VNDetectHumanHandPoseRequest，≤ 4 只）/ 脸（VNDetectFaceRectanglesRequest），
    各自 try? perform，出错不影响身体；PartMotionTracker（手 / 脸）、PoseMotionTracker.bodyContext（髋 / 头 / 腕三组 + 另一个人的髋 / 头）
    → PoseContext（切镜前那些帧算出来的不认）
  → MotionWindowAccumulator.drain() → MotionWindow（+ roi / roiSamples / context）
AudioLevelTap（音频实时线程，撞击声开着）：AudioBandSplitter → 10 ms 一块三频带能量（低 < 200 Hz / 中 / 高 > 2 kHz，时间 = 块中点的视频时间）
  → 无锁环形缓冲（1024 块）；主线程 drainBands
VideoSyncPlayer（主线程，完整拍）
  ActionContext.step(window, followerHz…) → 改写窗口副本（选部位的频率 / 相位、区域内运动代替整幅）+ 往里方向
  RhythmFollower.step / RhythmPhaseLock.step（吃改写后的副本）               # P1 / P2 不变
  AudioOnsetDetector.add(bands) → onsets / rhythm()；AudioPhaseAnchor.step(onsets, audioHz, lock, directionKnown) → offset
  RhythmPulseDriver.phaseOffset = offset → beat / subBeat                      # 只挪指令相位
  → 同一个 outputStage（上限 / 升幅按时间 ≤ +20 / 0.3 秒 / 归零保持 0.85 秒 / 通道 3、4 恒 0）→ 变化才 ble.sendTick
```

#### 类型（`VisualSync.swift`「rhythm-context P3」）

| 类型 | 作用 | 关键参数 |
| --- | --- | --- |
| `PeriodicityMap` | 每块扣掉相机后的速度最近约 4 秒的环形缓冲（64 帧，稳态不分配）；在跟随频率上对每块做 DFT，功率最大且周期性够的块为种子，向 8 邻域扩展 | ≥ 12 个样本；窗口 2 个周期（夹在 1.5~4 秒）；幅度 ≥ 4 px/s；种子周期性 ≥ 0.4、成员 ≥ 0.3、功率 ≥ 种子 25%、同向或反向（\|Re 相关\| ≥ 0.5）；区域 ≤ 60% 的块；0.3 秒更新一次；帧间隔 > 0.5 秒重攒 |
| `LumaCropDownscaler` / `CropRect` | Y 平面里一个裁剪框 → 小图（同 LumaDownscaler 的 4×4 平均，采样表按框缓存） | 框夹在画面内 |
| `RoiFlowTracker` / `RoiReading` | 周期区域内的高分辨率块运动 | 放大 1.5~4 倍、外扩 1.3 倍；框 1 秒最多挪一次（IoU < 0.5 才挪，< 0.2 时节奏重攒）；区域 1 秒没更新就不用；帧间隔 0.03~0.5 秒 |
| `PartCandidate` / `PartReading` / `PartMotionTracker` | 手 / 脸检测和运动跟踪（同 PoseMotionTracker：1.5 尺度连续性换目标、指数平滑 + 死区、扣相机、按尺度归一 → StrokeRhythm） | 置信度 ≥ 0.3；手的尺度 = 3 × 腕到中指根、脸 = 2.5 × 脸框高；速度 ≤ 8 尺度/秒；读数不旧于 0.5 秒；没开相位脉动时不算相位 |
| `PoseBodyContext` / `PartRhythm` / `PoseContext` | 跟踪的那个人的髋 / 头 / 腕位置和三组节奏，另一个人的髋 / 头 | 另一个人：上一帧那个人附近 1.5 个身体尺度内优先 |
| `ActionContext` | 每个完整拍判断动作：手在区域旁且频率一致 → 撸动（看手 / 手腕）；头 / 脸在区域旁 → 口交；髋往复为主 → 插入；据此改写窗口副本；按「朝另一个人的髋」判断往里方向 | 证据 ≥ 0.3 且领先 ≥ 0.1 才换、滞回 0.9 秒；1.5 秒没依据回「未知」；切镜立刻「未知」；频率一致 ≤ 15%；方向点积 ≥ 0.34、保持 1 秒；「未知」时只用区域内运动（区域可信时），部位 / 方向都不改 |
| `AudioBandSplitter` / `AudioBandFrame` | 实时线程上两个一阶低通分三段，10 ms 一块 | 只有几个数的状态，不分配、不加锁；采样率不对不出块；回调之间时间对不上 > 50 ms（seek / 丢样本）丢掉没满的块 |
| `AudioOnsetDetector` | 三频带对数能量正向增量（加权 1 / 1 / 0.5）= 撞击强度；高于最近 1 秒均值 + 1.5σ 且 ≥ 1.5、局部峰、间隔 ≥ 0.12 秒、不静音 → 撞击；`rhythm()`：最近 4 秒的撞击时刻做成脉冲串（σ = 15 ms 的高斯）求归一化自相关，0.4~4 Hz 里取最短的、不低于最高峰 85% 的局部峰（倍周期的相关一样高，避免认成 1/2、1/3 频率） | 时间倒退 / 块间隔 > 0.1 秒重来；稳定的噪声 / 哼声没有撞击，也就没有节奏 |
| `AudioPhaseAnchor` | 声音节奏和画面频率差 ≤ 15%、置信度 ≥ 0.3、最近 4 秒 ≥ 4 次撞击、撞击时刻的画面相位集中（R ≥ 0.6）→ offset 每拍向 −(平均撞击相位) 收 30%，把撞击对到「最深点」（相位 0） | 方向已判断时只做 ±60° 细调，判断不了时可以整个翻过来；条件不满足：保持 2 秒后按 2 秒时间常数回 0；相位锁放开 / 切镜 / seek 立刻 0 |
| `RhythmPulseDriver.phaseOffset` | 加到指令相位上（弧度），只挪时机 | 默认 0 = P2 逐位相同 |
| `VisualSyncSettings` | `rhythmContext` / `rhythmAudioAnchor`（默认 false）、`usesRhythmContext` / `usesAudioAnchor` | 不影响 `tickInterval` |

#### P2 评审问题的修复（不带开关，但关着 P2 时和 main 逐位相同）

- **L1 相位拟合只在需要时算**：`SubjectFlowTracker` / `MotionAnalyzer` / `PoseMotionTracker` / `PartMotionTracker` / `RoiFlowTracker` 的 `phaseFitEnabled`（默认 false），
  VideoMotionTap 按「相位脉动」每帧设。P2 里 `phaseFit` 一直在算（只写新字段），现在关着时不算，省 CPU。
- **L2 统一的按时间限速账本**：`SyncOutputStage.step(_:settings:hasSignal:now:)` / `step(levels:settings:now:timed:)`，VideoSyncPlayer 所有出口（值路径、档位路径、交接追赶）
  都带主机时钟 `now`。上一次是按时间限速的（`pendingTimed`），这一次不管走哪条路径都按实际间隔给预算；满 0.3 秒交回按拍。
  P2 时子拍后 0.1 秒的按拍出口还会按「一拍」给 +20，现在只给 ≈ +7。从没按时间限速过时和 P1 出口逐位相同（随机序列比对）。
- **L3 完整拍按 0.3 秒网格调度**：`takesFullBeat`：到「上一个完整拍该在的时刻 + 0.3 − 0.05 秒」且离上一个实际完整拍 ≥ 0.2 秒就算，算完网格往前推 0.3 秒
  （晚 > 0.1 秒才以现在为新起点）。原来按「距上一个实际完整拍 ≥ 0.265 秒」，Timer 晚一点就会拖到 ≈ 0.4 秒一拍并一直错开。

#### 界面

- 「伸缩跟随动作频率」打开后，「相位脉动（实验）」上面多一个开关「动作识别（实验）」；仪表区多一行 `contextStatus`：
  「动作识别：插入（看髋）/ 口交（看脸 / 头）/ 撸动（看手 / 手腕）/ 还没认出动作（按整幅画面跟）」+「用周期区域内的运动」+「往里方向已判断 / 判断不了」。
- 「相位脉动（实验）」打开后，「方向反转」下面多一个开关「撞击声相位校正（实验）」；仪表区多一行 `anchorStatus`（已对齐 / 偏移角度 / 没听到和画面同节奏的撞击声）。

#### 安全不变

- 不改 BLEManager / SafetyLedger / Protocol / AIProgram / Models / 工程文件（没有新文件，新类型都在 `VisualSync.swift`）；**不新增发送路径**：仍只在 `tick()` 里经 `SyncOutputStage` → `sendTick`。
  STOP / 看门狗 / 断连 / 暂停 / 缓冲 / seek / 关联动的处理不变。
- 出口规则不变：≤ 上限、单步升 ≤ 20、任意两刻之间升幅 ≤ 20 × 间隔 / 0.3 + 1、归零后 ≥ 0.85 秒才再升、通道 3 / 4 恒 0（P3 测试里子拍 / 完整拍 / 交接追赶随机混走仍守住）。
- 动作识别只改「跟哪个部位的频率 / 相位」，强度那条路不看这份副本；撞击声只改指令相位，不改档位、不改深度。
- **两个开关关着时和 P2 逐位相同**；P2 的开关也关着时和 main 逐位相同（测试钉住）。手 / 脸 Vision 请求只在动作识别开着时跑，出错只丢这一次上下文。

#### 测试（`Tests/VisualSyncChecks/main.swift`「rhythm-context P3」）

- L1：相位拟合默认关，关着时块运动 / 姿态都不算相位；L2：带 now 的出口在没按时间限速过时和 P1 出口逐位相同（12000 步随机）、子拍 / 完整拍 / 交接追赶随机混走时任意两刻升幅包络不破、
  子拍后 0.1 秒的完整拍只给 +7、满 0.3 秒交回按拍；L3：Timer 每次 112 / 95 ms / 抖 ±30 ms 时完整拍平均间隔都是 0.300 秒。
- 关着 = P2：分析器默认不算周期区域、开着时其余读数逐位相同；没有上下文的窗口动作识别不改。
- 周期区域：往复块被框出、随机游走的干扰块不算；裁剪降采样（稳态不重新分配）；放大框（1.5~4 倍、贴边不出画面、区域太大不放大、小变化不挪）；
  放大跟踪（裁剪小图里 1.5 Hz 往复读出 1.50 Hz、幅度换回分析帧）。
- 手 / 脸跟踪（1.5 Hz、镜头平移时照样 1.5 Hz、旁边更大的手不抢、相位只在开关开着时算）；姿态上下文（髋 / 头 / 腕 + 另一个人，关着时是空的、姿态读数逐位相同）；
  窗口（区域读数 / 上下文跟着样本走，切镜清掉、切镜前算出来的不认）。
- 动作识别：手 / 髋 / 脸同频往复分别认成撸动 / 插入 / 口交并用那个部位的节奏；方向：主轴朝着髋 = 往里、背着髋相位翻 180°、垂直时判断不了。
- 撞击声：频带（10 ms 一块、哼声进低频、白噪声进高频、采样率不对不出块、seek 丢半块）；撞击检测（1.6 Hz 撞击 13 / 13、误差 ≤ 20 ms、声音节奏 1.60 Hz、稳定噪声没有撞击、时间倒退重来）；
  相位校正（收敛到 −μ、方向已判断时限 ±60°、频率对不上 / 撞击散乱不校正、声音没了 2 秒后慢慢回 0、没锁立刻 0）；脉动相位偏移（偏移 Δ 和相位锁本身提前 Δ 逐位相同，默认 0 = P2）。
- 设置：默认 / 键名 / 读回 / `usesRhythmContext` / `usesAudioAnchor`。

`VideoMotionTap.swift` / `AudioLevelTap.swift` / `VideoSyncView.swift` 的接线（Vision 手 / 脸请求、区域裁剪、音频 tap 时间、界面）Linux 编不了，靠 PR Checks（Xcode 16.4）编译确认，再上真机。

#### 真机验证清单

1. 两个开关都关：和 P2 完全一样（状态行没有新行）；P2 也关：和 main 一样。
2. 打开「动作识别」：手机发热 / 耗电和不开比有没有明显变化（多了手 / 脸 Vision 请求和区域块运动）；Xcode Instruments 看姿态队列每帧耗时。
3. 区域对不对：找一段固定机位的真实视频，状态行出现「用周期区域内的运动」时，频率跟随是否更稳；镜头推拉 / 摇时区域会不会乱跳。
4. 动作分类：插入 / 口 / 手各找 2~3 段，看状态行认得对不对、切换要多久（应 ≤ 2 秒）；两个人都在动时是否跟对了主动的那个。
5. 往里方向：「往里方向已判断」时设备强弱是否和画面对上；判断错了用「方向反转」能不能救回来（反馈回来以便改规则）。
6. 撞击声：有拍打声的视频（不放背景音乐）上「撞击声相位校正」状态行能否在 4~6 秒内「已对齐」；配乐 / 说话的视频应保持「没听到」、偏移 0。
   `AudioLevelTap` 的 tap 时间（`MTAudioProcessingTapGetSourceAudio` 的 timeRange）在真机上是否有效、和画面时间差多少（看对齐后的偏移是否稳定）。
7. P2 的标定表 / 延迟补偿 / FFA2 观察照 `docs/rhythm-calibration.md` 第 8 节；P3 的验证见第 9 节。

### rhythm-lookahead P4：前瞻 + 预扫描（默认关；Vision 光流 / 单应配准推迟）

**目标**：P1~P3 的频率 / 相位读数都是因果的——`followEstimate` 看最近 4 秒、相位拟合看最近 2 个周期，跳频后要好几秒才跟上；
P2 的指令相位按「现在的频率」外推延迟补偿那一段。视频是本地文件，可以另开一路解码**提前读后面的画面**，把这两段延迟抵掉；
同一路解码顺带可以**预扫描整段视频**，给画面的自动适应一个全片分位数的起点。
**边界**：仍是开环；P4 只改「交给 RhythmFollower / RhythmPhaseLock 的那份窗口副本」（在 P3 动作识别之前）、
「脉动指令相位的有界提前量」和「MotionNormalizer 参考值的起点」，不改档位规则、不改出口、不新增发送路径。
没标定 / 核对不上 / 读不到 / 发热 / 后台时一律退回 P4 关着的行为（= main 92681ea 逐位相同）。

#### 两个开关（都默认关）

| 开关 | 存储键 | 显示条件 | 真正生效 | 关着时 |
| --- | --- | --- | --- | --- |
| 前瞻（实验） | `bcVisualSyncRhythmLookahead` | 「伸缩跟随动作频率」打开时 | `usesLookahead` = 跟随画面 + 频率跟随 + 前瞻 + **已标定** | 不建 `LookaheadReader`、不另外解码；窗口、相位偏移原样 |
| 预扫描整段视频（实验） | `bcVisualSyncPrescan` | 「自动适应画面」打开时 | `usesPrescan` = 跟随画面 + 自动适应 + 预扫描 | 不另外解码；`MotionNormalizer.seed` 不调用 |

两个都不改 `tickInterval`（0.1 / 0.3 秒 Timer 只跟 P2 走）。

#### 数据流

```
LookaheadReader（VideoMotionTap.swift，一个 .utility 串行队列，每步 ≤ 约 12 ms 后让出）
  前瞻：AVAssetReader(播放头起，420v) → 按 15 Hz 挑帧 → LumaDownscaler → MotionAnalyzer（相位拟合跟「相位脉动」走，不跑 Vision）
        → LookaheadTimeline（视频时间，最多 200 帧，播放头前 5 秒以前丢掉，最多领先 3 秒）
        往回 seek > 0.25 秒 / 播放头跑过读到的最远处 1 秒 → 从播放头重读；10 秒内重读 ≥ 4 次 = 解码跟不上，停 5 秒
  预扫描（前瞻不缺帧时才做）：AVAssetReader(从头 / 停下处) → 同样 15 Hz 分析 → MotionPrescan（0.3 秒窗口，和实时同一套学习门）
        → 扫完回调主线程 Summary（log 能量 / 主体分数的 10 / 90 分位）
        播放中每 20 ms 最多解码 1 帧（约每秒 50 帧），暂停时每步最多 10 帧
  发热 ≥ .serious 或 App 在后台：两路都停（前瞻清空，预扫描记下停在哪），恢复后接着读；读不了文件 3 次就放弃
VideoSyncPlayer（主线程，完整拍）
  tick：播放头 / 在不在播 / 时长 → LookaheadReader.notePlayhead
  motionTick：扫完了且这个视频还没学过 → MotionNormalizer.seed(summary)（只试一次）
  rhythmLevel：usesLookahead → LookaheadCoordinator.refine(窗口, 快照, Clock(host, 播放头, 倍速), 延迟补偿)
                → P3 ActionContext.refine → RhythmFollower.step / RhythmPhaseLock.step         # P1 / P2 / P3 不变
  脉动：phaseOffset = removeLead(上一拍的) → updateAudioAnchor（P3）→ applyLead（这一拍用了前瞻才加）→ beat / subBeat
```

#### 类型（`VisualSync.swift`「rhythm-lookahead P4」）

- `LookaheadTimeline`：追加 / 换段（切镜、断档 > 0.5 秒、重读）/ 修剪 / 按视频时间查：`causal`（核对用）、`centeredFollow`（往后看 2 秒 = 居中的跟随频率）、
  `centeredPhase`（拟合窗口盖住现在的读数按居中程度 × R² 加权圆平均，同代次才混）、`phaseAdvance`（现在 → 现在 + 延迟画面实际走的相位）；
  `needsRestart` / `wantsMore`（读帧那边什么时候重读、什么时候先不读）。
- `RhythmLookahead`：核对（频率差 ≤ 15%；实时没有节奏而前瞻同一时刻置信度 ≥ 0.4 也算不一致；只看最近 8 次：≥ 3 次一致、≤ 2 次不一致且最近一次不是不一致才通过，≥ 5 次不一致判「对不上」；读帧那边重读（时间轴 origin 变了）时核对历史清掉；相位 0° / 180° 折叠后 ≤ 45° 才认方向、连续 2 次才定；45°~135° 不认）→ 代入（频率按「现在 + 延迟」的居中读数 × 倍速；
  相位按现在的居中读数、折到实时的方向约定、时间戳记成现在）→ 提前量（±60°、每秒最多变 90°、相位锁不用时立刻 0、不代入相位时按速率回 0）。
  切镜那一拍原样、方向作废；保持期 / 空窗口原样。
- `LookaheadCoordinator`：播放器接线（和测试共用）。`enabled == false` 时窗口 / 偏移原样交回（位模式相同）并清状态；提前量下一拍先撤再算撞击声校正（防御性：现在 `updateAudioAnchor` 每个完整拍都会整个改写偏移，撤不撤结果一样）；
  总偏移 `RhythmLookahead.phaseOffset` 夹在 ±90°（= 撞击声校正自己最宽的 `AudioPhaseAnchor.unknownLimit`），提前量 0 时就是撞击声校正本身（不夹、逐位相同）。
- `MotionPrescan` / `MotionNormalizer.seed`：只在换视频后还一拍都没学过（`warmElapsed == 0`）时用分位数当参考值起点，热身照旧（开头 3 秒仍按 confidence 从 0 升）；
  可学窗口 < 30 个不给；坏值夹回实时学习能到的范围（`refHigh ≥ minHigh`、主体参考 0~1）。之后照常实时学。
  注意：起点不保证比不开时低。安静的片子 `scoreHigh` 起点低时主体放大一开始就到 1.25 倍、`refHigh` 起点可低到 `minHigh`，
  热身过后开头一段可能比不开预扫描时同一时刻更强（不超过实时学习本来会学到的范围，上限 / 每拍升幅 ≤ 20 照旧）。
  预扫描只在这个结果还用得上时解码：已经有结果、或播放已经开始学（`warmElapsed > 0`）就停掉，不会扫到片尾白费（复审 M1）。
- `LookaheadThermalPolicy`：另一路解码只在 `.nominal / .fair` 跑。

#### 没做（推迟）

- **Vision 光流 / 单应配准（`VNGenerateOpticalFlowRequest` / `VNHomographicImageRegistrationRequest`）**：没做。理由：没有真机就量不了每对 ≤ 15 ms 的预算；
  P3 已经在 `.nominal` 下多跑手 / 脸 Vision，再加光流在 A12~A14 上很可能顶到 `.serious`，而 P4 又在 `.serious` 起整个停；块运动 + 周期区域对推拉镜头的问题
  目前靠切镜 / 近场 / 相机补偿兜底。等真机给出 P3 + 前瞻的发热数据后再评估，接口位置留在 `MotionAnalyzer` 之后（结果走同一个 `MotionSample`）。
- 预扫描的「取消」就是关掉开关（没有单独按钮）；进度显示在仪表区「预扫描：已扫 xx%」。
- 前瞻不跑 P3 的周期区域 / 手 / 脸：代入的只是块运动主体的频率 / 相位，P3 认出部位时照旧由 P3 改写。

#### 安全不变

- 只改交给跟随器 / 相位锁的窗口副本（锁不锁、用几成仍由 P1 / P2 的门、滞回、`activity` 决定：动作停了照样同一拍放开，画面不动时前瞻看到后面的节奏也不提前锁）；
  没有全局主体读数（`subjectFrames == 0`）的窗口原样，不碰部位信号和方向。
- 输出仍只经 `tick()` → `SyncOutputStage`（上限、每拍升幅 ≤ 20 / 按时间折算、归零保持、通道 2 / 3 为 0）→ `sendTick`；STOP / 看门狗 / 断连不变。
- 相位偏移有界（提前量 ±60°、总和 ±90°）、按时间限速；`MotionNormalizer.seed` 只改起点、不跳过热身。
- 另一路解码不碰 BLE、不在主线程做；`BLEManager.swift` / `SafetyLedger.swift` / `Protocol.swift` / `AIProgram.swift` / `Models.swift` / `project.pbxproj` 都没动（新代码都在已有文件里）。

#### 测试

`Tests/VisualSyncChecks/main.swift`「rhythm-lookahead P4」（CI 跑）：时间轴（追加 / 换段 / 容量 / 修剪 / 重读）、居中相位 / 频率、关着 / 没读到 3000 组随机原样、端到端 1 Hz、
1→1.6 Hz 跳频（频率早 2 秒、相位早 1.4 秒）、动作停 / 开始、对不上（别的画面 → 逐位同实时；偏 0.25 秒 → 只代入频率）、主轴反向、切镜 / 保持期、核对只看最近 8 次（不一致 > 2 次 / 最近一次不一致就不代入；实时没节奏而前瞻有把握算不一致；读帧重读后历史清掉、reset 不清）、2× 倍速、提前量、
P4 + 子拍脉动整段（出口不变量 + 峰相位 + 跳频后相位误差比只用实时小）、视频到头退回、**关着整段 173 拍与不走 P4 的链逐位相同**、接线关着 3000 组随机原样、
提前量撤加 / 总偏移上限、设置（默认 / 键名 / 读回 / 要标定）、状态行、读帧重读规则、发热、预扫描分位数 / 初始化。

`Tests/P4OffCompare/run.sh`（本地，不在 CI）：只用 main 已有接口的整条链模拟（P1 / P2+切镜 / P3 三组，246 行逐拍输出含浮点位模式），分别和 main 92681ea 与本分支的
`VisualSync.swift` 编译，输出逐字节相同。

草稿里两条失败测试的处理（算法没改，都是断言本身写错了，见测试里的注释）：
1. 提前量复合断言：−14° 的提前量在切镜后「按速率回 0」，一拍最多回 90°/秒 × 0.3 秒 = 27°，本来就该一拍到 0；草稿要求「变小但不为 0」不可能。改成 −14° 一拍到 0、
   夹在 −60° 的一拍回 27°（−33° → −6° → 0），比原来钉得更死。
2. P4 + 子拍脉动整段：统计窗口 15~20 秒、1.4 Hz 只有 7 个往复，草稿要求 ≥ 8 个峰不可能（只用实时也是 7 个）；最后一拍要求 `.engaged`，但草稿让前瞻和模拟同时在 20 秒结束，
   最后 2 秒没有「后面的画面」，按设计就该退回 `.waiting`。改成前瞻多读 3 秒（真实视频这时还有画面），峰数 ≥ 7；「视频到头退回只用实时、提前量 0」另加一条。
   另外加了对照：跳频后 4 秒内指令相位最大误差 31°（只用实时时相位锁已放开，180°）。

`VideoMotionTap.swift`（`LookaheadReader`）/ `VideoSyncView.swift`（接线、界面）Linux 编不了，靠 PR Checks（Xcode 16.4）编译确认，再上真机。

#### 真机验证清单

1. 两个开关都关：和 main 完全一样（仪表区没有「前瞻：」「预扫描：」两行，Instruments 里没有 `com.bluecrystal.motion.lookahead` 队列在跑）。
2. 打开「前瞻」但没标定：不生效（状态行不出现）；标定后：`const-1hz` 上 3~6 秒内状态行到「频率和相位都按将来的画面」，提前量接近 0。
3. 跳频测试视频（如 1 → 1.6 Hz）：和不开前瞻比，伸缩快慢 / 脉动时机是不是更早跟上（应早 1~2 秒）。
4. 拖进度条 / 快进快退 10 秒 / 暂停再播：状态行回到「正在提前读…」再重新对上；不会在跳转后一下输出变强。
5. 2× 倍速：仍能「对上」；长时间 2× 播放时会不会出现「解码跟不上播放」（记机型）。
6. 播放流畅度：1080p60 HEVC / 4K30 片源开着前瞻（+ 预扫描）时有没有掉帧、卡顿；Instruments 看 lookahead 队列 CPU、解码器占用；10 分钟温度 / 耗电和不开比。
7. 发热：手机进入 `.serious`（或用 Xcode 的 Thermal State 模拟）时两行都显示「手机发热，已暂停提前读视频」、行为退回只用实时；降温后恢复。切到后台再回来同样恢复。
8. 预扫描：选视频后不点播放，看「已扫 xx%」涨到扫完（记 1 分钟 / 10 分钟视频各要多久、机型）；扫完再播，开头几秒强度是否比不开时更贴这个视频（热身照旧从 0 升；安静的片子热身后可能比不开时略强——起点按全片范围，主体放大最多 1.25 倍——记下是否过猛）。
   扫一半关掉开关：进度行消失、不再解码。扫完前就开始播放：提示「已经开始播放，这次按实时学（不再扫描，换视频后重新扫）」，Instruments 里预扫描那路解码随即停掉（前瞻开着时前瞻照常读）。
9. 动作停下 / 切镜：0.5 秒内伸缩回落、脉动消失，和不开前瞻一样；STOP 一下就停。

### av-fusion F0/F1：声画融合（F0 观测与标定；F1 耦合度，只显示，默认关）

研究页「BlueCrystal 声画融合联动研究」的 F0 / F1 两步。融合**不是第三种联动来源**：`VisualSyncSource` / `resolveSource` / 来源选择界面都不动，
声音模式一行不改；F1 只在「跟随画面」下多一个默认关的开关。两步都不改任何输出：输出只走 `tick()` → `SyncOutputStage` 限幅 → `BLEManager.sendTick`，
没有新的发送路径，STOP 照旧一下就停，安全上限不变。新类型都在 `VisualSync.swift` 末尾 `// MARK: - av-fusion`，实时线程部分在 `AudioLevelTap.swift`，
没有新 Swift 文件；`BLEManager.swift` / `SafetyLedger.swift` / `Protocol.swift` / `AIProgram.swift` / `Models.swift` / `project.pbxproj` 都没动。

#### F0：观测与标定（不加开关，跟着「调试记录」走）

目标：先把「声音和画面在手机上到底差多少」量出来，再谈融合。F0 不改控制，只加观测：

- **tap 回调时间**（`AudioTapTiming` / `AudioTapTimingRing`）：每次 MTAudioProcessingTap 回调记 host 时间（`CACurrentMediaTime`）、
  这段第一个样本的视频时间（`MTAudioProcessingTapGetSourceAudio` 给的时间范围，拿不到记 NaN）和样本数。环形缓冲 64 条、init 时一次分配，
  在 `AudioLevelMeter` 已有的 `os_unfair_lock` 第一段里写（不多加锁、不分配）。**只在调试记录开着时写**（`setTimingEnabled`）：关着时实时线程只多看一个布尔，
  不多读一个样本；`setBandsEnabled(usesAudioAnchor)` 的表达式 F0 一点没动。
- **播放器时钟快照**（`MediaClockSnapshot`）：主线程每拍读一次 host 时间 / `currentTime` / `rate`，视频时间 ↔ host 时间互换。
- **tap 提前量**（`AudioTapLeadEstimator`）：提前量 = 这段声音按播放器时钟该出声的 host 时刻 − tap 处理它的 host 时刻；最近 32 个的中位数，
  离谱的（> 2 秒，seek / 时钟跳）丢掉。这是「tap 看到的撞击」要换成「耳朵听到的撞击」时要减掉的量，F1 的时间可用判断也看它。
- **调试表格新列**（`AVDebugColumns`，接在 `MotionDebugLog` 原有列后面，原列不变）：
  `av_onsets`（这一拍新出现的撞击时刻，视频秒，分号分隔；撞击声相位校正开着才有）、`av_band_frames` / `av_band_low_db` / `av_band_mid_db` / `av_band_high_db`
  （这一拍取走的三频带块数和均值能量 dB；同样只在 P3 频带已经在流的时候有）、`av_tap_lead_ms`、`av_tap_valid` / `av_tap_invalid`（这一拍时间范围有效 / 无效的回调数）、
  `av_play_host` / `av_play_item` / `av_play_rate`。非有限数一律写空格子。频带块是 `updateAudioAnchor` 取走后顺手汇总的同一份，撞击检测吃到的数据不变。
- **测试视频**（`Tools/make-rhythm-test-videos.sh` 新增 §4.3 一组）：同帧闪白 + 宽带咔哒基线（1.6 Hz）、声音晚 120 ms / 早 200 ms、纯配乐（120 BPM 底鼓 + 踩镲 + 和弦，画面静止）、
  画面 1.6 Hz + 同频配乐（鼓点错开 0.23 秒，15 秒切镜音乐不断）、类人声（150 Hz 谐波 + 4 Hz 音节包络）。真机怎么量见 `docs/rhythm-calibration.md` 第 11 节。

F0 的测试（`Tests/VisualSyncChecks/main.swift`「av-fusion F0」，都在函数里）：调试列表头 / 有数 / 空列列数一致、NaN / ∞ 写空、撞击时刻分号分隔；回调时间缓冲关着不记、
满 64 条留最新且旧 → 新、有效 / 无效计数、取走清零、关掉清掉；播放器时钟互换（倍速 2、暂停 → NaN）；提前量中位数（±3 ms 抖动 + seek 离谱值，1× / 2× / 负提前量各一组，误差 < 2.5 ms）。

#### F1：声音特征 + 耦合度（开关 `bcVisualSyncAVFusion`，默认关；只显示，不改输出）

「跟随画面」下多一个「声画融合（实验）」开关（`VisualSyncSettings.avFusion`；`usesAVFusion = source == .motion && avFusion`，跟随声音时不显示也不生效；
不改 `tickInterval` / 其他任何判断）。开着时只多一行「声画：」状态（耦合 / 像配乐 / 像人声 / 没声音 / 时间不可用 / 切镜考验 / 画面相位没锁 / 不耦合）
和调试表格的 21 列 `av_state` … `av_rhythm_conf`（`AVDebugColumns.f1Header`，接在 F0 列后面；关着时整组空）。**开着时交给出口的值和关着逐位相同**（见下面的对照）。

- **实时线程**（`AudioLevelTap.swift`）：`setBandsEnabled(usesAudioAnchor || usesAVFusion)`（融合要 P3 的三频带给「画面不动时仍有节奏」）；
  扩展特征只在融合开着时算（`setFeaturesEnabled(usesAVFusion)`，关着时只多看一个布尔）：`AudioFeatureSplitter` 6 段 RBJ 二阶带通
  （100 / 300 / 800 / 1800 / 3500 / 6000 Hz，Q = 1）每 10 毫秒一帧（均方能量 + 1 毫秒子块峰值），另把单声道一阶低通（3.4 kHz）后按 round(采样率 / 8000) 取平均降采样成 PCM。
  时间按样本计数从这段连续声音的起点推，所以任意切块结果和一次喂完逐位相同；时间接不上（seek）丢掉没满的帧、从新位置起算，拿不到时间（NaN）这段不出帧并计数。
  环形缓冲（特征 512 帧、PCM 16384 个）和 pending（32 / 512）都在 init 时一次分配，写入只在已有的 `os_unfair_lock` 里，回调里不分配、不阻塞。
- **主线程每个完整拍**（`AVFusionEngine.beat`；研究页写的是 utility 队列，F1 先放在主线程：每拍只处理 0.3 秒的新数据，
  FFT 每 20 毫秒一次 1024 点，量级在 1% 单核以内，省掉跨线程交接；真机 Instruments 超预算再挪）：
  - `AudioFeatureExtractor`：起音候选 = ≥ 2 段比前 2 帧最小值高 6 dB（不应期 80 毫秒）；8 帧后评估每段的起音陡度（短 = 峰值 / 能量 + 衰减快）→
    ≥ 4 段短促 = 撞击（`isImpact`），≥ 2 段 = 陡；谐波度（512 点 Hann、补零 1024 点 FFT、Boersma 归一化自相关 70~400 Hz 的局部最大 ρ，
    h = clamp((ρ − 0.35) / 0.5)，最近 100 个不静的帧取中位数）、频谱平坦度、HPSS 简化版（17 帧 × 32 段的打击成分占比）；
  - `AudioBeatGrid`：最近 12 秒的起音（≥ 6 秒、≥ 8 个）做高斯脉冲自相关（30~150 个 10 毫秒），取「最短且 ≥ 最高峰 85%」的周期（只消歧），
    ±12 毫秒细调，落在网格 ±30 毫秒的强度占比 → stable = (share − 0.5) / 0.3；有 2× 细分（踩镲）→ subdivided；value = stable × subdivided；
  - `AudioSceneEvidence`：跨切镜考验（切镜那拍有 stable ≥ 0.5 的网格就记下，之后 2 秒 ≥ 2 次起音、按强度 ≥ 75% 落在原网格 ±30 毫秒 → 跨切镜连续 = 1，保持 10 秒；
    考验期间耦合度挂起不更新）；画面不动（activity = 0）时 P3 声音节奏置信 ≥ 0.4 → 1 秒爬满、保持 10 秒；
    P_music = max(0.4·跨切镜 + 0.3·不动仍有节奏 + 0.2·网格 + 0.1·谐波, 0.8·跨切镜, 0.6·不动仍有节奏)，P_voice = 谐波度 × (1 − 起音陡度)；
  - `AVCouplingEstimator`：C_raw = A_f × A_R × A_n × (1 − P_music) × (1 − P_voice)；A_f = clamp(1 − |ln(f_a / f_v)| / ln 1.15)
    （f_a = 最近 4 秒撞击间隔中位数 × 倍速，f_v = P2 相位锁频率）；A_R = clamp((R − 0.4) / 0.4)（R = 撞击时刻在画面相位上的集中度，**要 P2 相位锁锁着**，
    所以判断耦合要同时开「伸缩跟随动作频率」和「相位脉动」；没锁时状态写「画面相位还没锁上」）；A_n = clamp((n − 2) / 3)；
    C 按 τ = 1 秒 EMA，≥ 0.6 持续 2 秒进入「耦合」，< 0.4 持续 1.5 秒退出。
- **和研究页的出入**（都在 CSV 上可调，F1 只显示）：① A_n 研究页是 (n − 3) / 5：1.6 Hz 的咔哒 4 秒只有 6~7 下，A_n 到不了 1，「4 秒内 C ≥ 0.6」做不到，改成 (n − 2) / 3；
  ② P_music 研究页是纯加权和：加权和里跨切镜只有 0.4、画面不动只有 0.3，同频配乐过了切镜考验 C 也只降到 0.4（要求 ≤ 0.3）、画面静止的配乐 P_music 到不了 0.6，
  按研究页「这两条是最有力的证据 / 强烈上升」加了两个下限 0.8 / 0.6。
- **频带块共用**（`AudioBandBacklog`）：融合和撞击声校正都要 P3 的频带块，电平计只有一个环形缓冲（取走就没了）。融合每拍先取走，校正开着时把取走的存进 backlog
  （只留最新 1024 个），校正下次取的时候接在新取的前面——和校正单独从环形缓冲（满了丢最旧的）取逐位相同；seek / 换视频 / 校正重置时和环形缓冲一起清。
  融合开着时频带一直在分，校正这时才打开要 `restartBands()`（照「频带从关到开」那样丢掉没取走的块、splitter 从头来），校正的输入还是和融合关着时一样。

F1 的测试（`Tests/VisualSyncChecks/main.swift`「av-fusion F1」，固定种子 LCG 合成、24 kHz，都在函数里）：咔哒串和画面同步 → 3.6 秒 C ≥ 0.6、5.7 秒进入耦合；
偏移 +150 毫秒仍耦合；配乐 + 画面同频 → 切镜考验后 P_music 0.8、C 0.2、退出耦合；画面静止 + 配乐 → P_music ≥ 0.6；人声样 / 呻吟样 → 0 次撞击、P_voice ≥ 0.6；
白噪声 / 50 Hz 哼声 → 0 次撞击；画面没锁 → 不耦合；6 段 splitter 1~4096 帧随机切块和一次喂完逐位相同、seek 丢半帧；backlog 200 组随机（含溢出）和单独取逐位相同；
设置默认关 / 键名 / 只在跟随画面生效；调试列列数 / NaN 写空。

#### 融合关着 = f706431 逐位相同（`Tests/FusionOffCompare/run.sh`，PR Checks 里跑）

照 `Tests/P4OffCompare` 的做法，一开始就建好：同一份只用 f706431（v1.8.3）已有接口的整条链模拟——声音模式两组（电平 → `AudioReactiveShaper` → 通道档位 / 出口限速）、
画面 P1 / P2+切镜 / P3（动作识别）/ P3+撞击声相位校正（合成 48 kHz 声音 → `AudioBandSplitter` → `AudioOnsetDetector` → `AudioPhaseAnchor`，含声音偏 80 ms 和同频配乐 + 切镜）/
P4 前瞻——分别和 f706431 的 `VisualSync.swift`、当前分支的 `VisualSync.swift`、当前分支加 `-D AV_FUSION_ON`（融合部件在旁边吃同样的画面 / 声音跟着跑：
6 段特征 → `AVFusionEngine`，P3 频带块照 `VideoSyncPlayer` 经 `AudioBandBacklog` 先给融合再交给撞击声校正）编译（`-O`），
三份输出（每拍输出档位、原值、浮点位模式）必须逐字节相同。CI 的 checkout 改成 `fetch-depth: 0` 才拿得到 f706431。

### av-fusion F2：节奏由声音确认（开关 `bcVisualSyncAVRhythmConfirm`，默认关）+ F1 复审 L1 / L2

研究页 F2 一步。原则：**画面为主、声音作证**——频率和相位永远由画面（P1~P4）决定；声音只在证明了自己和画面说的是同一件事（F1 的「耦合」：
C ≥ 0.6 持续 2 秒进入，C < 0.4 持续 1.5 秒退出；seek / 换视频 / 开关 / 画面侧重置时立刻从头来）之后才说话，而且**只纠正、不发起**：
`activity` 只看画面（声音永远不能让静止的画面动起来）、声音不能开节奏锁，只能在画面已经有候选时加置信度 / 选八度 / 缩短跳变确认。
每个效果都是乘在画面结果上的有界修正；不耦合或开关关着时和现在的跟随画面逐位相同。

#### 开关

| 开关 | 存储键 | 显示条件 | 真正生效 | 关着时 |
| --- | --- | --- | --- | --- |
| 节奏由声音确认（实验） | `bcVisualSyncAVRhythmConfirm` | 「声画融合（实验）」和「伸缩跟随动作频率」都开（只在跟随画面） | `usesAVRhythmConfirm` = `usesAVFusion && rhythmFollow && avRhythmConfirm` | 不投票、窗口副本原样、跟随器 `fastJump = false`、撞击声校正 `coupled = nil`（P3 原样） |

不改 `tickInterval`；不是第三种来源（`VisualSyncSource` / `resolveSource` / 来源选择不动），声音模式一行不改。

#### 状态机（主线程，每个完整拍）

- **S0 关**（开关关 / 不在跟随画面）= main；
- **S1 只有画面**（不耦合 / 没声音 / 时间不可用 / 切镜考验 / 画面这一拍没有块运动候选）= 现在的跟随画面，窗口副本原样（`==` 且位模式相同）；
- **S2 耦合**（**上一拍** `AVFusionBeat.state == .coupled`）= 画面结果 + `AVRhythmVote` 的确认 + 撞击声校正的耦合条件。
  `state == .coupled` 本身就要求时间可用（拿不到时间范围 → 没有频带 / 特征帧 → `no_time`）、声音在场、不在切镜考验，所以没有时间就没有 S2。
  用上一拍的状态是因为 `updateFusion` 照 F1 排在 `rhythmLevel` 之后（读这一拍更新过的相位锁），F1 的显示 / 输出不因此变；滞后 ≤ 1 拍（0.3 秒）。
- S2 → S1 单调退回：耦合一退出，下一拍起窗口原样。

#### 数据流

```
VideoSyncPlayer.rhythmLevel（完整拍）
  window → P4 LookaheadCoordinator.refine → F2 AVRhythmVote.refine（usesAVRhythmConfirm 才走）→ P3 ActionContext.refine
         → RhythmFollower.step(…, fastJumpHz: vote.fastJumpHz) / RhythmPhaseLock.step                      # 出口规则不变
motionTick：updateFusion（F1，不变）→ … → updateAudioAnchor（usesAVRhythmConfirm 时 coupled = 这一拍 state == .coupled）
输出仍只经 tick() → SyncOutputStage.limit → BLEManager.sendTick；pulseSubTick 不变；STOP / 看门狗 / 断连不变
```

#### 类型（`VisualSync.swift`「av-fusion F2」）

- `AVRhythmVote.refine(window, enabled:, coupled:, events:, impactHz:, clock:, followerHz:, followerLocked:)`：只在 S2、这一拍有块运动候选
  （`subjectFrames > 0`、跟随频率在 0.4~4 Hz、置信 > 0）、没切镜 / 保持期、时钟有效时改副本：
  1. **一致**：声音节奏和画面跟随频率差 ≤ 15%（和 F1 的 A_f 同口径）→ `subjectFollowRhythm` + 0.1（夹 0~1）；
  2. **八度消歧**：两边正好差 2 倍 / 一半（八度两边各 15%）、而且声音是**干净的单一脉冲串**（声音节奏和上一拍 F1 的 f_a = 撞击间隔中位数差 ≤ 15%）→
     画面频率乘 2 / 除 2（按画面自己的读数换八度，不直接用声音的频率；幅度按频率反比换算；按错八度拟合的相位作废，相位锁等下一个读数；
     姿态和块运动同一个八度时一起换）；
  3. **跳频确认**：跟随器锁着、画面读数偏离跟随频率 15% 以上、声音同方向也偏了 15% 以上、而且和画面读数差 ≤ 30% → `fastJump`、`fastJumpHz` = 这个画面读数，
     `RhythmFollower` 这一拍**真正用的候选读数**和 `fastJumpHz` 同方向、差 ≤ 30% 时，跳变确认从 2 拍（≥ 0.6 秒 − 半拍）缩成 1 拍（≥ 1 拍 − 半拍）
     （复审 M2：跟随器挑了姿态读数时声音没核对过它，不缩；以前是一个布尔，反方向的姿态读数也会 1 拍就跳）；跳不跳、跳到哪仍由跟随器自己的规则（平均偏离 ≥ 30%、读数彼此一致）决定。
- **声音节奏**（`AVRhythmVote.audioRhythm`）：融合起音里的撞击（`isImpact`）按**幅度**加权（strength 是 6 段上升 dB 之和，换成每段平均上升的幅度倍数）做成脉冲串，
  归一化自相关在 0.4~4 Hz 找局部峰，取「最短且 ≥ 最高峰 85%」的周期——**只用来消歧，不发起**。
  **窗口对齐**：声音的 4 秒窗口和画面 `followEstimate` 的 4 秒窗口按播放器时钟对齐（画面窗口终点 = 最后一个相位拟合的时刻，没有时 = 现在；换成视频时间后往前 4 秒 × 倍速），
  频率乘倍速后再和画面（host 时间上的 Hz）比。跳频方向看同一个对齐窗口里**最后 4 下撞击的间隔中位数**（`recentHz`）：
  4 秒自相关要攒够新节奏才换峰，测试里比画面的 `followEstimate` 晚 1 拍以上，用它就永远赶不上。
- **一下两响（往里 / 往外各一声）的风险**：两响强弱不同时按幅度加权的自相关落在整周期、撞击间隔中位数却是一半周期 → 不干净 → 不改八度（测试：12 dB 差的两响，留在 1 Hz）；
  两响一样强时声音和画面本来就差一倍，F1 的 A_f = 0、进不了耦合——S2 只能在声音和画面**同频**时建立，所以八度消歧实际只纠正「已经耦合以后画面一时读错八度」
  （15 fps 上 2 Hz = 7.5 格，`halvedLag` 时灵时不灵）。画面从头到尾都读错八度时进不了 S2，不纠正（宁可不纠正，也不让声音发起）；
  持续误报时相位锁拿不到读数会在约 1 秒后放开 → C 降、约 1.5 秒后退出耦合 → 退回 S1，最多桥接约 3 秒。
- `RhythmFollower.step(_:dt:active:fastJumpHz:)`：`fastJumpHz` 默认 0（= 不缩），表达式和以前逐位相同（`Self.jumpConfirmSeconds - 0.5 * beat - 1e-9`）。
- `AudioPhaseAnchor.step(…, coupled: Bool? = nil)`：nil = 不看耦合（和以前逐位相同）；false = 这一拍不算「对上」（按条件不满足保持 2 秒后回 0），
  状态行「撞击声校正：声画不耦合（像配乐 / 人声）…」。**和研究页的出入**：研究页写「融合开着（usesAVFusion）就加耦合条件」，但同一页又要求
  「融合开、F2 关 = F1 = f706431 逐位相同」，两条矛盾；这里按后一条，耦合条件跟 `usesAVRhythmConfirm` 走（F2 要求融合开着，所以仍是「只在融合开着时」）。
- 调试列 `AVDebugColumns.f2Header`：`av_vote,av_vote_hz,av_vote_conf,av_vote_clean,av_fast_jump`（接在 F1 列后面；开关关着时整组空）。状态行「节奏确认：…」。

#### F1 复审 L1 / L2（融合关着时行为不变）

- **L1（实时线程在 pushFeatures 里等 `os_unfair_lock`）**：**没做成原子量的无锁 SPSC 环**——工程是 iOS 16 起步、Swift 5 模式，标准库没有带内存序的原子量
  （`Synchronization.Atomic` 要 iOS 18；swift-atomics 要加包依赖 = 改 `project.pbxproj`，不允许；`OSAtomic*` 已废弃），
  用普通 Swift 变量当序号 / 下标在 ARM64（弱内存序）上是数据竞争，消费者可能先看到下标再看到数据，不安全。
  改成**实时线程不等锁**：回调末尾 `os_unfair_lock_trylock`，主线程正拿着锁（`drainFeatures` 拷贝）就把 pending 留到下一次回调再写
  （pending 加到 64 帧 / 4096 个 PCM ≈ 0.6 秒，init 时一次分配）；只有一次回调中途 pending 满了才照旧等锁（不丢数据）。
  另加缓冲代次 `featureEpoch`（开关 / seek / prepare 清缓冲时 +1，锁里读写）：换代后留着的旧 pending 一律丢掉，顺带堵上了「回调中途 reset、
  旧位置的特征写进新缓冲」的老竞态。只动特征那条路：三频带 `pushBands`（P3，融合关着时也在用）一字没改。回调开头 / 末尾那两次已有的锁（电平累加）也没动。
- **L2（融合开着时 6 段带通一直在跑）**：`VideoSyncPlayer.fusionFeaturesWanted = usesAVFusion && Timer 在跑（在联动）&& 画面分析在跑（有画面轨、没发热暂停）`，
  不满足时 `setFeaturesEnabled(false)`、融合自己要的频带也关（`setBandsEnabled(usesAudioAnchor || wanted)`），`updateFusion` 不做（FFT 也不跑），
  在 `startTimer` / `stopTimer` / 画面分析状态变化 / 设置变化时更新。融合关着时 wanted 恒 false，频带开关仍是 `usesAudioAnchor`（= f706431）。
  「撞击声校正这时才打开要 `restartBands()`」的条件改看上一次交给电平计的 `fusionAudioOn`（融合关着时恒 false，和以前一样）。
  纯计算类型一行没改，确定性测试不受影响。

#### 安全不变

- 只改交给跟随器 / 相位锁的窗口副本（锁不锁、用几成仍由 P1 / P2 的门、滞回、`activity` 决定；画面不动时声音再有节奏也不锁）和跟随器这一拍的确认拍数；
  撞击声校正只会因为不耦合**少**对齐（偏移仍有界 ±90°、按时间回 0）。
- 输出仍只经 `tick()` → `SyncOutputStage`（上限、每拍升幅 ≤ 20、归零保持、通道 2 / 3 为 0）→ `sendTick`；没有新的发送路径、没有新的阻塞；STOP 照旧一下就停。
- 新值都夹在有效范围（置信 0~1、频率只乘 2 / 除 2 且仍要过跟随器的 0.4~4 Hz、非有限数不投票）；所有重置点（`resetRhythm` / `resetFusion` / 开关）都清投票。
- `BLEManager.swift` / `SafetyLedger.swift` / `Protocol.swift` / `AIProgram.swift` / `Models.swift` / `project.pbxproj` 都没动；没有新 Swift 文件。

#### 测试（`Tests/VisualSyncChecks/main.swift`「av-fusion F2」，固定种子 LCG、24 kHz，都在函数里）

`AVF2Run` 照播放器的顺序（投票看上一拍融合状态 → 跟随器 / 相位锁 → `AVFusionEngine.beat` → 撞击声校正）跑整条链：
1. 八度消歧（单元）：画面误报 1 Hz + 声音 2 Hz、S2 从 3 秒起 → 副本 2 Hz（幅度减半、相位作废），跟随器 0 秒（≤ 1.5）锁对 2 Hz；不投票一直 1 Hz。
   端到端（真的耦合度）：前 7 秒读数正确 → 5.1 秒进入耦合；之后 3 拍里 2 拍误报 1 Hz → 投票时跟随器一直 2 Hz、一直耦合，不投票 35 拍不在 2 Hz；
   一下两响（12 dB 强弱差）→ 不改八度、留在 1 Hz。
2. 同频配乐（12 秒切镜）：凡是上一拍不耦合的拍，副本 `==` 原窗口、不投票；考验后 P_music 0.8。
3. 画面静止 + 有节奏的声音：强制给耦合、画面有弱候选也不锁（跟随器 / 相位锁）；自然情况不耦合、副本原样。
4. 跳频 1 → 1.6 Hz（真的 `StrokeRhythm` + 相位拟合，咔哒和画面同相）：耦合时 13.5 秒确认、不投票 13.8 秒（早 0.3 秒），跳之前两条链一样。
5. 撞击声校正 + 同频节拍音轨（2 Hz 咔哒跨切镜不断）：F2 关（= P3）15 拍「已对齐」；F2 开时切镜考验认出配乐后不对齐（`uncoupled`）。
6. 开关关着 / 开着但不耦合：3000 组随机窗口（含切镜 / 保持期 / 没帧 / 姿态 / 倍速 2）跟随器、相位锁、撞击声校正（`coupled: nil`）和 P4 的链逐位相同、副本 `==`。
另有设置（默认关 / 键名 / 生效条件 / 不改 Timer）、读回、调试列 5 列 / 状态行。

`Tests/FusionOffCompare/run.sh` 多编一份 `-D AV_FUSION_ON -D AV_F2_ON`（融合开、节奏确认关，F2 接线全走一遍：投票 → `fastJump` → 校正 `coupled`），
四份输出（f706431 / 当前 / 融合 / F2）逐字节相同。`AudioLevelTap.swift` / `VideoSyncView.swift` Linux 编不了，靠 PR Checks（Xcode 16.4）编译确认，再上真机
（`docs/rhythm-calibration.md` 第 12 节）。F2 的结果也决定 F3b 做不做。

## 11. 风险与待定

1. **伸缩档位的真实含义**：0x08 帧里「伸缩」是速度档还是幅度档需要真机确认，决定节奏系数是映射到伸缩还是震动更合理（默认按速度档设计）。rhythm-follow P1 也按速度档设计，P0 标定（`docs/rhythm-calibration.md` 第 1 步）先确认。
2. **帧差 ≠ 语义**：雨、烟、水面、粒子特效、快速闪烁的灯光会被当成「运动」；P2 的平移补偿和覆盖率可以缓解，彻底解决要 P4 或更多语义特征，本设计不承诺。
3. **暗场景对比度低**：同样的动作能量偏低，自适应归一化会部分补回；必要时 P2 可加「按亮度标准差归一」（std 下限 8）。
4. **HDR 片源转换成本**：需实测，超预算时对 HDR 降到 8 Hz。
5. **延迟**：0.3~0.5 s 的体感延迟在快节奏片段可感知，P4 前瞻再处理。
6. **默认值**：来源默认「声音」以保证老用户无感升级；是否在无音轨视频上自动建议切到「画面」（只提示、不自动切）待产品决定。

---

## 附录 A：核心纯逻辑草图（Swift，只依赖 Foundation）

```swift
enum VisualSyncSource: Int, CaseIterable, Identifiable { case audio = 0, motion = 1, mix = 2; var id: Int { rawValue } }

struct MotionSample: Equatable {
    var time: Double          // item 时间（秒）
    var energy: Double        // 主体运动 M_raw（亮度级）
    var coverage: Double      // 0...1
    var globalShift: (dx: Double, dy: Double) // 像素 / 样本
    var signedShift: Double   // 主轴局部位移，P3
    var isCut: Bool
}

struct MotionWindow: Equatable {
    var meanEnergy: Double = 0, peakEnergy: Double = 0
    var frames = 0, cutCount = 0
    static let empty = MotionWindow()
    var representative: Double { frames > 0 ? 0.6 * meanEnergy + 0.4 * peakEnergy : 0 }
}

struct MotionNormalizer {
    static let absoluteGate = 0.5, minSpan = 0.8, targetPercent = 85.0, warmUp: TimeInterval = 3
    static let initialHigh = log(7.0), initialLow = log(1.8)
    private(set) var refHigh = initialHigh, refLow = initialLow, warmElapsed: TimeInterval = 0
    var confidence: Double { min(1, warmElapsed / Self.warmUp) }

    mutating func resetAdaptation() { refHigh = Self.initialHigh; refLow = Self.initialLow; warmElapsed = 0 }

    mutating func step(_ w: MotionWindow, gainDb: Double, auto: Bool, dt: TimeInterval) -> Double {
        let step = dt.isFinite ? min(1, max(0.01, dt)) : 0.3
        let e = w.representative
        guard w.frames > 0, e.isFinite, e >= Self.absoluteGate else { return 0 }
        warmElapsed += step
        let l = log(1 + e)
        if auto, w.cutCount == 0 {
            refHigh += (l - refHigh) * (1 - exp(-step / (l > refHigh ? 2 : 25)))
            refLow  += (l - refLow)  * (1 - exp(-step / (l < refLow ? 1.5 : 20)))
        }
        let lo = auto ? refLow : Self.initialLow
        let hi = auto ? refHigh : log(13.0)
        let g = gainDb.isFinite ? pow(10, min(12, max(-6, gainDb)) / 20) : 1
        let n = (l - lo) / max(Self.minSpan, hi - lo) * g
        let out = n * Self.targetPercent
        return out.isFinite ? min(100, max(0, out)) : 0
    }
}

struct SyncOutputStage {
    static let maxRisePerTick = 20, zeroHoldTicks = 2
    private var last = [0, 0, 0, 0]
    private var zeroAge = [Int](repeating: SyncOutputStage.zeroHoldTicks, count: 4)

    mutating func reset() { last = [0, 0, 0, 0]; zeroAge = [Int](repeating: Self.zeroHoldTicks, count: 4) }

    /// 与 AudioReactiveShaper.step 尾部逐位一致
    static func map(_ v: Double, cap: Double, floor: Double) -> Int {
        let v = v.isFinite ? min(100, max(0, v)) : 0
        if floor >= 1 {
            let scaled = floor + v * (cap - floor) / 100
            return min(Int(cap.rounded(.down)), max(Int(floor.rounded()), Int(scaled.rounded())))
        }
        let scaled = v * cap / 100
        return scaled < 1 ? 0 : min(Int(cap.rounded(.down)), Int(scaled.rounded()))
    }

    /// values：每通道 0~100（[伸缩, 震动]）；hasSignal 决定是否加最低强度
    mutating func step(_ values: [Double], audio s: AudioSyncSettings, hasSignal: Bool) -> [Int] {
        let cap = s.maxPercent
        let floor = hasSignal ? min(cap, s.minPercent) : 0
        let hardCap = min(Int(cap.rounded(.down)), BCProtocol.maxManualLevel)
        var out = [0, 0, 0, 0]
        for ch in 0..<2 {
            var p = Self.map(ch < values.count ? values[ch] : 0, cap: cap, floor: floor)
            p = min(p, last[ch] + Self.maxRisePerTick)                       // 升幅限速
            if p > 0, last[ch] == 0, zeroAge[ch] < Self.zeroHoldTicks { p = 0 } // 归零保持
            p = max(0, min(hardCap, p))                                       // 最终夹紧
            zeroAge[ch] = p == 0 ? (last[ch] == 0 ? zeroAge[ch] + 1 : 0) : Self.zeroHoldTicks
            out[ch] = p
        }
        last = out
        return out   // 索引 2 / 3 恒 0
    }
}
```

> 草图只表达结构与数值，实施时以测试为准（例如 `zeroAge` 的计数口径由 §9.1「归零保持」测试钉住；开播 `reset()` 后 `zeroAge` 视为已满，不推迟第一次升高）。

## 附录 B：`tick()` 正常分支改动草图

```swift
let window = meter?.drain() ?? .silent
let out = shaper.step(window, settings: settings, dt: dt, hasAudio: audioStatus == .ready)   // 不变
level = out.level
let vals: [Int]
switch visualSettings.source {
case .audio:
    intensity = out.percent
    vals = settings.channels.levels(percent: out.percent)                                   // 与现在逐位相同
case .motion, .mix:
    let mw = motionMeter?.drain() ?? .empty
    let target = motionNormalizer.step(mw, gainDb: visualSettings.motionGainDb,
                                       auto: visualSettings.autoMotion, dt: dt)
    let m = motionShaper.step(target: target, dt: dt)
    motionLevel = m.level
    let hasMotion = motionStatus == .ready && mw.frames > 0      // 实施时用「最近 1 s 内有样本」
    let blend = SyncBlender.blend(audio: shaper.smoothed, hasAudio: audioStatus == .ready,
                                  motion: m.smoothed, hasMotion: hasMotion,
                                  warmUp: motionNormalizer.confidence,
                                  rhythm: motionMeter?.latestRhythm, settings: visualSettings,
                                  channels: settings.channels)
    vals = outputStage.step(blend.values, audio: settings, hasSignal: blend.hasSignal)
    intensity = vals.max() ?? 0
}
guard settings.enabled else { return }
let active = ActiveChannels(values: vals)
if needsResync || active != lastActive { /* 不变：ble.sendTick(levels: vals) */ }
```
