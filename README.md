# BlueCrystal iOS

给 mizzzee_0032 用的 iOS 控制 App（SwiftUI + CoreBluetooth）。

## 功能

- **手动控制**：四通道强度滑杆（伸缩/震动/吮吸/旋转，0~9 档），官方启动帧快捷按钮，一键停止
- **视频联动**：选本地视频 + 载入时间轴 JSON 脚本，播放时按时间自动发 0x06 帧

## 协议（已验证）

- Service `FFA0` / Write `FFA1`（Write With Response）/ Notify `FFA2`
- 帧：`AA 06 05 <ch0> <ch1> <ch2> <ch3> <00> <checksum>`，共 9 字节
- 启动 `AA06050406050000C4` / 停止 `AA06050000000000B5`（真机实抓）

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
- 0x06 各通道强度语义以真机实测为准，滑杆值仅供测试
