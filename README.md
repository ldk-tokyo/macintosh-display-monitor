# 副屏监视器

把一块外接屏变成经典 Macintosh 风格的仪表盘。抬眼看指针，就能读到 CPU、GPU 和内存负载，往下看翻页时刻表，就知道 Codex 和 Claude Code 各剩多少额度、哪一项最先重置。

**[下载 macOS 应用](https://github.com/ldk-tokyo/macintosh-display-monitor/releases/latest)** · macOS 13 或以上 · Apple 芯片与 Intel Mac 通用

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/dashboard-dark.png">
  <img src="docs/images/dashboard-classic.png" alt="经典 Macintosh 副屏仪表盘。上方是三个指针表盘和网络吞吐量，下方按重置时间列出 Codex 与 Claude Code 的剩余额度。">
</picture>

[查看浅色原图](docs/images/dashboard-classic.png) · [查看深色原图](docs/images/dashboard-dark.png)

效果图由应用的副屏页面渲染，采用 16∶9、特大字号和 0% 留白。图中使用示例数据，琥珀色行标出下一次重置。

## 安装与首次使用

1. 在发布页下载文件名以 `macOS-universal.zip` 结尾的压缩包，解压后将 **副屏监视器.app** 拖入「应用程序」。
2. 双击打开。v1.0.0 采用临时签名，未经 Apple 公证。如果 macOS 拦截首次打开，确认下载来源后，在「系统设置 → 隐私与安全性」找到本次拦截记录，选择「仍要打开」。
3. 将外接屏设为扩展显示，在主屏打开监视器设置，选中目标副屏、外观和显示模块，点 **启用专用显示**。
4. 需要每天自动恢复时，打开 **登录时自动启动**。下次登录会沿用上次的副屏和显示模式。

硬件仪表可以单独使用。要显示额度，请在这台 Mac 上安装并登录相应的 Codex CLI 或 Claude Code。

## 经典 Macintosh 外观

浅色模式用同一暖灰底色和深色文字呈现硬件仪表与额度时刻表，两区各有细框。深色模式采用石墨灰底与暖白文字。两种模式均以琥珀色突出最近重置的额度窗口。具体色值见 [显示页面](Resources/Dashboard.html) 顶部的主题变量。

Finder、Dock、菜单栏、主屏设置和副屏标题均使用同一份[表盘矢量源文件](Resources/Gauge.svg)。

## 显示与退出

- 主屏设置中的「画布分辨率」默认跟随所选副屏，例如 1280 × 720。也可选择 4∶3、16∶10、超宽或竖屏等画布，切换后即时等比缩放并居中，系统输出分辨率保持原值。退出专用显示或更换目标屏幕后，画布恢复为跟随副屏。
- 主屏设置的「专用显示」中可开关「登录时自动启动」。开启后，macOS 登录当前账户时会启动监视器；需要系统批准时，设置中会出现「在系统设置中允许」。
- 登录后沿用上次的专用显示开关、目标副屏和外观。原副屏稍后接入时会按 UUID 恢复，主屏和其他副屏不会被当作替代目标。
- 主屏设置的「四边留白」可调 0–10%，默认 0%。副屏字号可选标准、大字（默认）和特大（155%），调整后立即生效。
- 主屏与镜像屏不能被选作目标。外接屏需要处于扩展模式。
- 启用时使用 Core Graphics 独占目标屏幕，仪表窗口位于系统遮罩之上，并将进入副屏的指针送回可操作屏幕。macOS 的显示器设置仍会列出这块物理显示器。
- 主屏设置和菜单栏的指针表盘图标均提供 **退出专用显示**。关闭设置窗口后应用继续运行，点菜单栏图标可重新打开设置。
- 拔下副屏时应用等待原设备重连。退出应用会释放副屏，保持启用偏好以便下次启动时恢复。

## 指标与额度

| 数据 | 读取方式 |
| --- | --- |
| CPU | Mach 处理器计数器，两次采样间的整机忙碌比例 |
| GPU | IOKit 驱动公开的设备利用率，多 GPU 取最高值。驱动未提供时显示横杠 |
| 内存 | Mach VM 内部页、压缩页、有线页和可清除页估算的已用物理内存 |
| 网络 | 已启用的 en 系列接口实际字节增量，按 MB/s 显示上下行 |
| Codex | 本机已登录的 Codex CLI，调用 app-server 的 account/rateLimits/read |
| Claude Code | 本机已登录的 Claude Code，通过本地 /usage 命令获取订阅额度。支持常规安装路径及 Claude 桌面端捆绑的 CLI |

按真实返回的窗口展示剩余百分比、重置时刻及模型专属周额度。按重置先后排序，时区跟随系统。每页行数按可用高度和字号计算，多页时每 12 秒轮换。来源不可用或窗口已过期时显示相应状态。设置中可以立即刷新。

应用要求 Codex CLI 支持 account/rateLimits/read，Claude Code 支持以非交互方式执行 /usage。CLI 的权限与账号由原客户端管理。监视器不读取令牌或保存对话记录。Claude 调用关闭工具、会话保存与项目配置，仅读取零模型轮次的 /usage 报告。

## 本地构建

需要 macOS 13 或以上和含 Swift 编译器的 Xcode Command Line Tools。默认构建当前 Mac 架构的应用。发布用的通用版本可用 `./build.sh --universal` 构建。两种构建都采用临时签名。

```sh
./build.sh
open 'dist/副屏监视器.app'
```

`Tests/run.sh` 检查采样、额度解析及主屏保护。传入 `--display Wokyis` 会短暂占用这块实体副屏，验证后释放。

硬件采集在 `Sources/Metrics.swift`，额度适配在 `Sources/Quota.swift`，设置及数据分发在 `Sources/Monitor.swift`。界面使用包内的 `Resources/Dashboard.html` 和 `Resources/dashboard.js`，没有远程网页依赖。

## 许可证

本项目采用 GNU 通用公共许可证第 3 版，仅适用第 3 版（SPDX 标识 `GPL-3.0-only`）。见[许可证全文](LICENSE)。
