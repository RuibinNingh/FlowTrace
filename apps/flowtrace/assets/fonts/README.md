# 内置字体来源

此目录保存未修改、未子集化的官方Noto Sans CJK简体中文Regular字体，用于离线中文显示。下载日期：2026-10-22（Asia/Shanghai）。字体接入与实际页面渲染由应用主题和资源配置另行验证；文件校验通过不能代替浏览器/平台显示验收。

## 固定来源与摘要

官方仓库：[notofonts/noto-cjk](https://github.com/notofonts/noto-cjk)。通过[GitHub公开提交API](https://api.github.com/repos/notofonts/noto-cjk/commits/main)解析到提交`f8d157532fbfaeda587e826d4cd5b21a49186f7c`，提交时间为2024-09-19T09:26:59Z；随后使用该提交的内容API和raw地址下载，未使用浮动main作为字体下载版本。

| 本地文件 | 上游位置 | 字节数 | SHA256 |
|---|---|---:|---|
| [NotoSansCJKsc-Regular.otf](NotoSansCJKsc-Regular.otf) | `Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf` | 16437364 | `2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b` |
| [LICENSE/Sans-LICENSE.txt](LICENSE/Sans-LICENSE.txt) | `Sans/LICENSE`原字节 | 4301 | `6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2` |
| [LICENSE/OFL.txt](LICENSE/OFL.txt) | 字体nameID0版权声明＋两个换行＋上述完整官方LICENSE | 4346 | `af55b908a0ccf969b7bdd0e6cac6f4866a7ed0d1aeb9c7b29516ca0d24422981` |

- [固定字体raw源](https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf)、[固定字体内容API](https://api.github.com/repos/notofonts/noto-cjk/contents/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf?ref=f8d157532fbfaeda587e826d4cd5b21a49186f7c)。Git blob SHA1为`dc15562470b4f842321894787a0d066879ccff8b`。
- [固定许可证raw源](https://raw.githubusercontent.com/notofonts/noto-cjk/f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/LICENSE)。Git blob SHA1为`d952d62c065f3f35fb83a173496e90b21525aef3`。

本地字体和`Sans-LICENSE.txt`均验证了字节数及Git对象`SHA1("blob " + bytes + NUL + content)`与公开API一致。为标准许可页显示版权，`OFL.txt`前置了从未修改字体nameID0提取的版权声明，官方LICENSE正文完整保留并验证后缀原字节相等。没有转换字体格式、替换版权信息或修改字形，没有复制操作系统闭源字体，也不依赖运行时下载中文字体。

## 内嵌名称、版权与许可

字体name表记录：family为`Noto Sans CJK SC`，style为`Regular`，PostScript名为`NotoSansCJKsc-Regular`，版本为`Version 2.004;hotconv 1.0.118;makeotfexe 2.5.65603`。

字体内嵌版权原文为：`© 2014-2021 Adobe (http://www.adobe.com/).`。本字体以SIL Open Font License 1.1发布，官方完整条文原字节存于[Sans-LICENSE.txt](LICENSE/Sans-LICENSE.txt)，应用应打包并注册含版权声明和完整条文的[OFL.txt](LICENSE/OFL.txt)。随软件嵌入和再分发时应保留版权与许可证并供用户查阅；不能将字体单独销售。OFL对字体的条件不将应用代码改为OFL授权。

## 标准库静态验证

2026-10-22使用Python标准库`struct/hashlib/json`完成以下验证，没有安装字体解析依赖：

- 文件头为`OTTO`，17个SFNT表的偏移/长度均在文件范围内，存在CFF、name、cmap、maxp等必要表；maxp声明65535个glyph。
- name表中的family/style/版本及版权记录存在，名称与上述值相符。
- Unicode cmap同时包含format4和format12（platform0及Windows平台3的Unicode映射），逐项检查66个不重复字符均映射到有效非0字形编号。
- 覆盖文字为“流迹净资产负债借入借出信用卡可用额度合计账户银行卡现金收入支出预算退款报销统计历史资金分组隐藏应还余额手续费”、数字0–9以及小数点、负号、币种符号和中文常用标点。代表字形：净11032、负38982、债10344、借10298、资39019、产9714，均不是`.notdef`。

这项验证证明文件完整和所测字符存在；字体资源注册、fallback顺序、CanvasKit和三端实际渲染仍由对应应用构建与页面验收确认。

## Roboto Regular与Medium

2026-10-22从现有官方Flutter SDK复制两份未修改的Roboto静态TTF，作为应用可离线打包的Roboto族资源；CJK继续使用上文的本地fallback。没有安装新字体、下载可变字体替换本机版本或改变任何字体字节。

本机Flutter SDK为`3.38.3`，`git describe --tags --exact-match`确认标签，git HEAD为`19074d12f7eaf6a8180cd4036a430c1d76de904e`。本机源目录为`C:/Ruibin_Ningh/app/FlutterSDK/flutter/engine/src/flutter/txt/third_party/fonts/`。两个源文件相对SDK HEAD无修改；源文件Git blob、本地复制品与同提交的Flutter官方公开内容API逐项相同：

| 本地文件 | 字节数 | SHA256 | Git blob SHA1 |
|---|---:|---|---|
| [Roboto-Regular.ttf](Roboto-Regular.ttf) | 171676 | `79e851404657dac2106b3d22ad256d47824a9a5765458edb72c9102a45816d95` | `2c97eeadffe1a34bd67d3ff1c3887fd53e22c2ca` |
| [Roboto-Medium.ttf](Roboto-Medium.ttf) | 172064 | `f205cc511821ea56078a105557fcea6253129404d411c997e1866fbd006abb68` | `1a7f3b0bba45b7470a4240c3ec67595eeeb02192` |

官方固定源：[Regular](https://raw.githubusercontent.com/flutter/flutter/19074d12f7eaf6a8180cd4036a430c1d76de904e/engine/src/flutter/txt/third_party/fonts/Roboto-Regular.ttf)、[Medium](https://raw.githubusercontent.com/flutter/flutter/19074d12f7eaf6a8180cd4036a430c1d76de904e/engine/src/flutter/txt/third_party/fonts/Roboto-Medium.ttf)；公开API为对应`https://api.github.com/repos/flutter/flutter/contents/engine/src/flutter/txt/third_party/fonts/`路径并带`ref=19074d12f7eaf6a8180cd4036a430c1d76de904e`。

两字体name表均明确记载`Version 2.137; 2017`、`Copyright 2011 Google Inc. All Rights Reserved.`和`Licensed under the Apache License, Version 2.0`，并指向Apache 2.0官方许可证URL。Regular的family为`Roboto`、style为`Regular`；Medium的family为`Roboto Medium`、style为`Regular`，其OS/2 weight class为500，不能仅凭name表style字符串把它误登记为400。两文件各有18个有效SFNT表、TrueType签名`00010000`、1294个glyph及Unicode cmap4/12；分别用标准库验证35个应用Latin/数字/金额标点字符均有非0字形，Regular的OS/2 weight class为400。

许可并非从文件名猜测：除字体内部的明确许可记录外，另以官方[googlefonts/roboto-2](https://github.com/googlefonts/roboto-2)固定提交`38062f4b4a0be4346d07a928408da21602545e9e`的[完整LICENSE](https://raw.githubusercontent.com/googlefonts/roboto-2/38062f4b4a0be4346d07a928408da21602545e9e/LICENSE)佐证。原`googlefonts/roboto`地址现重定向到该旧版Roboto仓库；没有把后续其他Roboto版本的许可套用到这两份TTF。

| 许可文件 | 内容 | 字节数 | SHA256 |
|---|---|---:|---|
| [LICENSE/Roboto-LICENSE.txt](LICENSE/Roboto-LICENSE.txt) | 官方Apache 2.0 LICENSE完整原字节 | 11357 | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |
| [LICENSE/Roboto.txt](LICENSE/Roboto.txt) | 两字体共同nameID0版权声明＋两个换行＋完整官方LICENSE | 11406 | `6e22432ba5eda75defb312cb88be7aebd4647c86d93d036ea2b75229e58afcd1` |

官方LICENSE Git blob SHA1为`261eeb9e9f8b2b4b0d119366dda99c6fd7d35c64`，本地原文与公开API一致。应用应打包并向标准许可页注册含Google版权及完整Apache 2.0条文的`Roboto.txt`；同时保留上述原始LICENSE来源记录。本次字体文件验证不能证明新FontManifest、离线网络请求或CanvasKit页面已经验收，这些由集成构建后另验。
