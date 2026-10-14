# BlueCrystal iOS

给 mizzzee_0032 用的 iOS 控制 App（SwiftUI + CoreBluetooth）。

## 功能

- **手动控制**：照官方 App 的三个 tab
  - 技能：官方五个预设（如影随形 / 疾风旋舞 / 幻影随行 / 水光环绕 / 神龙摆尾）
  - 变频：四通道 0~9（0x06 帧）
  - 手动：四通道 0~99（0x08 帧）
  - 一键停止
- **视频联动**：选本地视频 + 载入时间轴 JSON 脚本，播放时按时间自动发 0x06 帧

## 协议（参数取自官方 App 醉清风 3.5.1 源码 + 真机实抓）

- Service `FFA0` / Write `FFA1`（Write With Response）/ Notify `FFA2`（真机 GATT）
- 通用帧（官方 `be()`）：`AA <cmd> <len> <payload> <checksum>`，checksum = 前面所有字节和的低 8 位
- 通道顺序（官方 `getSlideProtocolIndex`）：伸缩 0 / 震动 1 / 吮吸 2 / 旋转 3
- 0x06 模式帧（官方 `Tt()`）：`AA 06 05 <4 通道> 00 <cs>`，技能预设 / 变频（0~9）/ 视频联动用
- 0x08 手动帧（官方 `at()`）：`AA 08 06 <4 通道 0~99> 00 00 <cs>`
- 停止 `AA06050000000000B5`（官方 `be("06",[0,0,0,0,0])`，真机实抓一致）；0x08 模式下先补 `AA0806000000000000B8` 归零帧
- 默认技能"如影随形" `AA06050406050000C4` = 真机实抓的官方启动帧

## 出包（GitHub Actions）

push 到 main 后自动编译 unsigned IPA，在 Actions 页下载 `BlueCrystalIOS-unsigned`。

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
  "commands": [
    {"commandType": "Thrust", "startTimeSeconds": 0, "durationSeconds": 5, "intensityLevel": 5},
    {"commandType": "Vibration", "startTimeSeconds": 5, "durationSeconds": 5, "intensityLevel": 7}
  ]
}
```

- `commandType`：Thrust（伸缩）/ Vibration（震动）/ Suction（吮吸）/ Rotation（旋转）
- `intensityLevel`：默认按十档（0~10，10 夹到设备最高 9 档）；任一值 >10 或写 `"intensityScale": "percent"` 时按 0~100 百分制换算到 0~9 档

## 注意

- 连设备前先断开官方 App（蓝牙独占）
- 0x08 手动帧和 0~99 范围来自官方源码，mizzzee_0032 真机还没抓到过 0x08 帧
- 官方会按设备从服务器下发滑杆范围（slideInfo），0032 的这份配置没拿到，用的是官方默认值
