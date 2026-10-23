# 2026-10-24 M1 Alpha候选冻结

> **任务**
> - 标识：alpha-candidates
> - 状态：已交付（仅M1候选，不代表最终Alpha或服务上线）

## 背景

用户在了解M1后要求“那执行吧”。本包仅盘点/筛选现有普通Windows、Web、APK，核对来源/版本/完整性/现成启动证据，缺件才构建。开始`git status --short --branch`为干净main，已有本地恢复提交0926681。沿用额度受控里程碑，每包返回后等待用户下一步决定。

## 行为变化

冻结现有Windows普通local-test ZIP、Web a3d9静态资源与普通Android debug APK；三端不重编。现成7个后端wheel均缺本地测试入口、最高迁移0006，不能供当前部署工具使用，因此仅补建现有head0016源码wheel。产物复制到新的`outputs/releases/alpha/m1-20261024/`，全hash复核后保存CANDIDATES.json，不覆盖原包。

Windows与Web业务输入一致，APK是较早普通候选，明确功能/签名/平台边界。未把静态检查称为真实数据库联调或持久部署，具体产物见[候选清单](../plans/flowtrace/alpha-candidates.md)。

## 影响文件

新增本日志和候选清单；在包完成时一次同步Alpha里程碑/进度、workspace及Windows/Web/client/server模块的产物状态。既有业务源码未改、旧日志和失败回执未改。新的二进制、完整源hash、审计与运行回执均在ignored outputs/server/dist中，未纳入Git。

实际委派两个单一工作包：m1_windows_audit只核普通Windows包，m1_android_audit只核现成APK；均不运行SDK/设备/原生UI、不改文档/业务代码。root负责Web、唯一缺件wheel、冻结与整合。

## 已执行验证

- Windows：26个ZIP文件CRC/安全集合/逐成员SHA及既有bundle一致；EXE NotSigned，CRT三DLL签名Valid/14.50.35719.0。同轮source与Web的144个lib/资源/pub项一致，只有Web壳不同。只读旧DB header为schema3；没有借用当前schema5回归。
- Android：aapt badging/xml、apksigner v2、ZIP和161成员QA标记检查。APK与normal-main保留包/历史安装和构建stamp同hash，普通lib/main.dart，0.1.0+1/ARM64/min24/target36；debug签名和明文HTTP策略明确。没有ADB或新安装。
- Web：生产verified_web对a3d9和c5e8各41文件及worker/manifest绑定全hash通过，最终选a3d9；读取既有普通Chrome地址/冷开离线回执，不重复相同旅程。新冻结Web再次全hash通过。
- 后端：首构建命令因server工作目录下误加server/前缀未运行Python，立即改正确相对路径；没有业务故障调查。`.venv/Scripts/python.exe -m build --no-isolation --wheel --outdir dist/alpha-m1-20261024`成功，425738B。220成员与构建前源hash全部一致、222 RECORD成员/所有Python编译通过；源码基线0926681。
- 以展开wheel为首import目录执行一次6项ASGI启动/静态smoke，5项200与未知404，静态字节hash及隔离响应头通过；开发venv依赖复用、无DB联调/独立安装。回执wheel-startup-smoke.json，未完整回归。
- 三个文件复制后SHA复核、Web41文件全核、CANDIDATES.json冻结回执；源包未改。开始额度接口7天已用0%，接收前已用1%，额外积分0。Git差异只含本包文档，提交后保存恢复点，无推送/生产部署。

## 未执行验证

未新编三端、未原生桌面/设备/新浏览器完整旅程，未三端对新wheel真实数据库联调，未Web ZIP封包、独立venv安装、持久数据库/服务安装、登录自启或重启验证。以上分别属于待用户决定的M2/M3；M1交付为冻结候选及明确缺口。非阻断/已知严重问题集中在workspace，不追加无关功能。
