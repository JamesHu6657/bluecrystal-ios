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

---

### algo-opt-1：联动算法优化（Notion AI，P1 之上的增量）

只改纯逻辑和取帧 / 电平计的数据通路；`BLEManager.swift` / `SafetyLedger.swift` / `Protocol.swift` / `AIProgram.swift` 不动，
输出仍只经 `VideoSyncPlayer.tick()` → `BLEManager.sendTick`；上限 / 最低强度 / 升幅限速（画面模式）/ 夹紧 [0, min(上限, 99)] 不变，所有新项都在这个范围内。
注意不是每一项都只降不升：近场降权、轻柔声音降权在同一拍里只降不升；稳健去均值在局部变亮 / 变暗时能量可能比按整幅均值去均值略高，
近场窗口不学参考值也会让之后的正常画面比学了时略高。

| 项 | 位置 | 做法 | 默认 |
|---|---|---|---|
| 稳健去均值 | `MotionAnalyzer.analyze` | 平移选择仍按均值去均值；能量 / 覆盖率改减「对齐后帧差的中位数」（511 档直方图），局部变暗不再把整幅算成在动 | 总是 |
| 近场 / 遮挡分数 N | `MotionAnalyzer.updateNearField` → `MotionSample.nearField` → `MotionWindow.nearField` | 遮挡 = s(覆盖率) × max(s(直方图离背景), s(变糊))；贴脸晃动 = s(覆盖率) × s(平移采用率) × s(对齐残差)；背景 τ 4 s、近场时冻结 ≤ 6 s | 总是 |
| 近场降权 | `MotionNormalizer.step` | ratio −= N·max(0, ratio − 0.6·固定尺度)；N ≥ 0.5 的窗口不学参考值 | 总是（单拍只降不升） |
| 内容时间戳 | `MotionDisplayClock` + `VideoMotionTap` | t = host − (播放头 − 帧显示时间)/速率（滞后 0~0.5 s 内），单调、间隔 ≥ min(31 ms, 到 host 的距离)、不晚于 host；静止补样按上一帧滞后换到同一条时间轴；24 fps 片源能量不再一大一小 | 总是 |
| 性能卫生 | `LumaDownscaler` / `MotionAnalyzer` | 裸指针读采样表、每帧临时数组复用、参考帧拷进已有存储；Instruments「Points of Interest」可看 `MotionDownscale` / `MotionAnalyze` | 总是 |
| 轻柔声音降权 | `AudioChannelStats`（512 点块电平，`AudioLevelMeter` 按声道跨 tap 回调接着分块）→ `AudioWindow.block*` → `AudioReactiveShaper` | 起伏度 Dyn、轻柔度 S；电平 ×(1 − 0.4·S̄)，自动增益的放大部分 ×(0.3 + 0.7·Dyn̄) | 视频页开关「轻柔声音降权」，App 默认开；`AudioSyncSettings.init` 默认关（逐位不变） |
| 来源交接 | `SourceHandover` + `VideoSyncPlayer` | 声音→画面：4 s 内用声音补画面热身 / 还没有新鲜画面样本的空档并淡出（≤ max(两来源)）；画面→声音：先经 `SyncOutputStage` 限速追上直出（≤ 10 拍） | 播放中切换时 |

没做（后续）：声音+画面可靠度混合（P2）、节奏 / 投影速度 + 自相关（P3）、亚像素 / 四象限相似变换平移、Vision（P4）。
真机要验证：手贴镜头 / 遮挡片段的输出、24 / 25 fps 片源的平稳度、轻音乐 / 白噪声视频的力度、切换来源时的手感、Instruments 每帧耗时。

## 11. 风险与待定

1. **伸缩档位的真实含义**：0x08 帧里「伸缩」是速度档还是幅度档需要真机确认，决定节奏系数是映射到伸缩还是震动更合理（默认按速度档设计）。
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
