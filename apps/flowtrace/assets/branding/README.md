# 流迹应用图标

用户于 2026-10-25（Asia/Shanghai）选定“流线 F”：蓝底白色流带结合 FlowTrace 的 F 与流水轨迹。

![流线 F](flowtrace-icon.png)

## 源文件

- [flowtrace-icon.png](flowtrace-icon.png)：选定的内置 ImageGen 原图，1254 × 1254 PNG，原字节保留。
- SHA-256：`b95c998693851cd6daec39d8a5cc59a76697dc99b977a9fd98fdd7a3ffa9edff`。
- [source.json](source.json)：原始生成提示词、生成路线和选择信息。
- [icon-manifest.json](icon-manifest.json)：实际导出尺寸、目标路径和 SHA-256。

本目录是平台资源的构建输入，无需在 Flutter pubspec 中登记为运行时资源。

## 确定性导出

在仓库根目录使用 Windows PowerShell 或 PowerShell：

```powershell
./apps/flowtrace/tool/app_icons/Export-AppIcons.ps1 -OutputDirectory ./outputs/branding/flow-f
# 加 -Apply 将输出复制到工程既有平台图标路径，并更新 icon-manifest.json。
./apps/flowtrace/tool/app_icons/Export-AppIcons.ps1 -OutputDirectory ./outputs/branding/flow-f -Apply
```

脚本使用 Windows 自带 System.Drawing 做尺寸转换，不依赖新增 Flutter 包。保持源图和渲染环境一致时，导出内容可重复；原图不会被覆盖。导出包内含独立 1024 PNG 和以下平台资源。

| 平台 | 资源 | 尺寸 |
|---|---|---|
| Android | 既有 mipmap 启动图标 | 48、72、96、144、192 |
| Web | favicon.png | 32 |
| Web | 普通图标 | 192、512 |
| Web | maskable 图标 | 192、512，每侧增加 8% 背景边距 |
| Windows | 多帧 app_icon.ico | 16、24、32、48、64、128、256 |

maskable 输出完整缩放选定图形，并把最外圈蓝色背景像素延展到边距；不重画 F。[W3C maskable 安全区](https://w3c.github.io/manifest/#icon-masks)规定中心圆半径为图宽的 40%。Windows ICO 的小帧使用 32-bit DIB，256 帧使用 PNG，标准尺寸参考 [Microsoft 图标资源说明](https://learn.microsoft.com/en-us/windows/win32/menurc/about-icons)。

## 发布边界

2026-10-25只更新工程资源和本地导出包，应用版本仍为 0.1.1+2。尚未重新构建 Windows/APK/Web 安装或发布包，也未替换生产部署。Android 沿用现有单层 mipmap 图标，本包未新增自适应前景或单色图层。平台安装后的图标缓存及真实桌面显示需要在下一次构建分发时核对。

本次范围和验证见 [任务记录](../../../../AI/logs/2026-10-25_app-icon-integration.md)。
