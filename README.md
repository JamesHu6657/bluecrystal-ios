# BlueCrystal iOS

给 mizzzee_0032 用的 iOS 控制 App（SwiftUI + CoreBluetooth）。

## 功能

- **手动控制**：照官方 App 的三个 tab
  - 技能：官方五个预设（如影随形 / 疾风旋舞 / 幻影随行 / 水光环绕 / 神龙摆尾）
  - 变频：伸缩 / 震动 / 吮吸 0~9（0x06 帧）
  - 手动：伸缩 / 震动 / 吮吸 0~99（0x08 帧）
  - 一键停止
- **视频联动**：选本地视频 + 载入时间轴 JSON 脚本，播放时按时间自动发官方 0x08 帧
- 旋转通道不显示、恒发 0：官方面板默认滑杆只有伸缩/震动/吮吸，内置 mizzzee 配置和技能预设都没用到它

## 安全机制（数值照搬 legacy `src/safety/limits.py`）

- 单次连续输出最长 300 秒，到点自动停止
- 滚动 30 分钟内最多输出 600 秒；每次停止后冷却 max(60 秒, 本次时长 × 0.5)，冷却/额度不够时拒绝开始，界面显示剩余秒数
- 手动、技能、视频的每一帧都经过同一个准入检查；冷却和额度跨 App 重启保留
- 停止 = 0x08 归零帧 → 100ms → 0x06 停止帧（官方全屏视频页退出时的顺序），两帧都收到写入回执才算停；
  失败整对重发，1→2→4→8→16→30 秒退避一直重试；30 秒仍未确认会锁定输出，需关机后点「已物理关机，解除锁定」
- 断开前必须确认停止；确认不了时可以「强制断开」（会再次警告）
- 界面心跳丢失 5 秒、退后台、App 退出、重新连上时都会发停止帧对

## 协议（参数取自官方 App 醉清风 3.5.1 源码 + 真机实抓）

- Service `FFA0` / Write `FFA1`（Write With Response）/ Notify `FFA2`（真机 GATT）
- 通用帧（官方 `be()`）：`AA <cmd> <len> <payload> <checksum>`，checksum = 前面所有字节和的低 8 位
- 通道顺序（官方 `getSlideProtocolIndex`）：伸缩 0 / 震动 1 / 吮吸 2 / 旋转 3
- 0x06 模式帧（官方 `Tt()`）：`AA 06 05 <4 通道> 00 <cs>`，技能预设 / 变频（0~9）用
- 0x08 帧（官方 `at(arr, t)`）：`AA 08 06 <4 通道 0~99> <t 高> <t 低> <cs>`，手动 tab 和视频联动用，t 恒为 0
- 视频联动强度照官方 video.js（迷姬 devType 2）：`status = 十档值 × 10`（百分制直接用），取整，非零 +10，最高 99，再 `at(…, 0)`
- 停止帧对：`AA0806000000000000B8`（官方 `at([0,0,0,0],0)`）→ 100ms → `AA06050000000000B5`（官方 `Tt([0,0,0,0])`，真机实抓一致）
- FFA2 通知会订阅并原样显示 HEX（含义未知，只记录）
- 默认技能"如影随形" `AA06050406050000C4` = 真机实抓的官方启动帧

## 出包（GitHub Actions）

push 到 main 后先跑 `Tests/ProtocolChecks`（钉住帧字节、官方换算、安全上限），再编译 unsigned IPA，
在 Actions 页下载 `BlueCrystalIOS-unsigned`。App 里「最后一帧」区块显示版本号和构建提交。
Publish Release 会核对运行结果、构建提交、sha256 和 tag 与版本号是否一致。

## 安装到 iPhone（自签）

unsigned 包不能直接装，需要自签（二选一）：

**AltStore**（推荐，有自动续签）：
1. 电脑装 AltServer，手机装 AltStore
2. 把 IPA 拖进 AltStore 安装

**Sideloadly**（Windows 也行）：
1. 打开 Sideloadly，选 IPA，填 Apple ID
2. 点 Start 安装（免费账号证书 7 天过期，到期重装一次）

## 时间轴脚本格式

```json
{
  "intensityScale": "ten",
  "commands": [
    {"commandType": "Thrust", "startTimeSeconds": 0, "durationSeconds": 5, "intensityLevel": 5},
    {"commandType": "Vibration", "startTimeSeconds": 5, "durationSeconds": 5, "intensityLevel": 7}
  ]
}
```

- `commandType`：Thrust（伸缩）/ Vibration（震动）/ Suction（吮吸）；Rotation（旋转）会被忽略
- `intensityScale`：`"ten"`（0~10，官方格式）或 `"percent"`（0~100）。请务必写上：
  不写时只有出现 >10 的值才能确定是百分制；所有值都 ≤10 时分不清，会按较弱的百分制处理并提示
- 换算成 0x08 强度：十档 5 → 60、10 → 99；百分制 50 → 60（见上面的官方公式）
- 短于 0.1 秒的命令也至少发一次

## 注意

- 连设备前先断开官方 App（蓝牙独占）
- 0x08 帧和 0~99 范围来自官方源码，mizzzee_0032 真机还没抓到过 0x08 帧（视频联动和每次停止都会发它）
- 官方会按设备从服务器下发滑杆范围（slideInfo），0032 的这份配置没拿到，用的是官方默认值
