# MDD Now Playing Bridge

为 macOS 墨督督 MDD 提供独立 Now Playing 桥接。显示当前课程名称和封面，将系统媒体命令转发为 MDD 已有快捷键。桥接不会修改 MDD 安装包。

## 功能

- 实际 OcsPlayer 打开后创建媒体卡片。暂停保留，关闭播放器或退出 MDD 后清除。
- 从当前详情页读取视频 ID、标题和封面，切课时更新。
- 播放和暂停对应空格，系统上一项与下一项对应左右方向键。所测 MDD 版本每次跳转 15 秒。
- 通过窗口事件和日志文件变化监听状态。没有实际播放器时停止页面轮询和日志监听。
- 应用图标在本机构建时从已安装的 MDD 复制，不在仓库中分发。

这是第三方个人工具，与 MDD 官方无关联。仓库不包含 MDD 程序、图标、课程、账号资料或实际播放日志。

## 环境与构建

需要 macOS 13 或更新版本、Xcode Command Line Tools 中的 Swift 编译器，以及已安装的 MDD。只构建当前机器架构，尚未覆盖所有 macOS 和 MDD 版本。

```sh
chmod +x build.sh verify.sh
./verify.sh
./build.sh
```

构建结果位于 `~/Library/Caches/MDDNowPlayingBridge/Build/MDD Now Playing 桥接.app`。缓存路径避免云同步文件夹自动附加元数据而破坏签名，可用 `BRIDGE_BUILD_DIR` 指定其他本机目录。将应用复制到 `~/Applications` 后打开，在系统的辅助功能或设备控制权限列表中添加并启用。重新编译会改变临时签名，macOS 可能需要重新授权。

构建只生成新应用，不覆盖任何已安装版本，不添加登录任务。非默认 MDD 安装位置可用 `MDD_APP_PATH` 指定。

## MDD 本地页面接口

动态元数据需要 MDD 的 Qt WebEngine DevTools 接口已在 `127.0.0.1` 监听。本工具只发现现有接口，不自动开启或重启 MDD。没有接口时不会伪造课程元数据。

需要时，先正常退出 MDD，再从终端以本地调试环境变量启动它。例如默认安装路径为：

```sh
QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9222 /Applications/MDDClass.app/Contents/MacOS/MDDClass
```

Qt 和 MDD 版本可能影响此方式。不要把调试端口监听在公网或局域网地址上。该接口能读取页面内容，同机进程可能访问它。恢复普通启动即可取消本次环境变量。若组织或应用政策不允许调试接口，请不要启用。

## 使用与限制

在 MDD 内打开实际播放器，桥接自动发布课程。仅打开课程详情页不会创建会话。桥接的封面来自当前视频的 `coverUrl`，MDD 返回通用封面时不会生成独立缩略图。

播放状态来自 MDD 日志，实测通常有约一秒刷盘延迟。系统媒体键由 macOS 路由到当前媒体会话。开启标准功能键模式时，可能需要使用 Fn。AirPods 若仍连接到 iPhone，耳机按键不会发送到 Mac。工具不主动连接或切换蓝牙设备，不全局拦截键盘。

元数据依赖当前 MDD 的 React 页面结构，窗口存在性依赖 `OcsPlayer` 标题，播放状态依赖日志格式。上游变化可能需要适配。没有验证或承诺应用检测机制及账号方面的结果。

当前工具没有设置窗口或菜单栏退出入口。需要退出时，在活动监视器中找到 `MDDNowPlayingBridge` 并退出。卸载时退出后删除应用即可，本仓库不安装后台任务。回滚时先备份旧应用，再替换新应用；回滚也可能需要重新授权。

## 结构与验证

| 文件 | 职责 |
| --- | --- |
| NativePlayerMonitor | 监听真实原生播放器窗口创建和销毁 |
| MDDPageClient | 读取当前页面元数据并复用页面缓存图片 |
| PlaybackLogMonitor | 文件事件驱动的增量日志读取 |
| Models | 会话有效期、媒体动作和日志解析 |
| NowPlayingPublisher | 元数据发布和清理 |
| MediaCommands | 系统命令到 MDD 按键的转发 |
| AppDelegate | 生命周期、任务取消和当前图片管理 |

`./verify.sh` 执行十五项行为检查，不操作真实播放器。可选 `./verify.sh --live PID` 只读验证已打开课程的页面缓存。运行时日志写入标准输出，不上传到外部服务。详见 [v1.3.1 验证范围](docs/verification.md)。
