# 洪大流量中心 加密部署命令

在原 Bash 安装器的 v0.1 安全补丁上增加 Vision 选项，保留原菜单 1–9。原来的服务商广告与推广链接已从新版界面移除；上游来源说明保留。

## 使用

在 Debian/Ubuntu、使用 systemd 的 VPS 交互式终端运行本目录的 [一键安装命令.txt](一键安装命令.txt)，选择 **10：VLESS + TCP + REALITY + Vision**。命令固定到代码提交 `8557a8afa884f132426cd3d610ee68e81c7cfdc8`，先核对安装器 SHA256 再执行。完成后复制生成的链接到客户端。以后可输入 `menu` 管理。

- 默认监听 IPv4 TCP 443；占用时显示另一个可用端口，不停止占用者。云防火墙和系统防火墙需允许最终显示的 TCP 端口；安装器不扩大现有防火墙规则。
- 每次新建节点生成独立 UUID、REALITY 密钥及 16 位十六进制 short ID，不包含开发者或其他用户的凭据。
- 默认候选握手域名为 `www.kernel.org`，可输入其他域名。安装器从当前 VPS 连续测试 TLS 1.3、X25519、证书及域名验证、h2 协商；失败即停止新增。三次即时探测不代表长期稳定，也不能证明域名难以识别。
- 新安装继续使用原安装器固定 SHA256 校验的 sing-box 1.14.3。已有受管理的核心不自动升级，先用该核心校验合并后的完整配置。
- 服务设置开机自启。退出 SSH 不会停止已经启动的代理。

## 客户端

分享链接包含 `flow=xtls-rprx-vision`、`fp=ios`、REALITY 公钥、short ID 和 SNI。导入后核对 VLESS、TCP、REALITY、Vision 和 iOS 指纹；关闭多路复用、TCP 快速打开、分片、允许不安全，保持 ECH 未配置。这些客户端开关不能全部依赖通用分享链接强制设置。

服务端显式关闭多路复用与 TCP Fast Open，不配置 ECH 或分片。Vision 是流控及传输方案，不表示把 TLS 加密强度再提高一档。功能字段参考 [sing-box VLESS 文档](https://sing-box.sagernet.org/configuration/inbound/vless/)及 [TLS 文档](https://sing-box.sagernet.org/configuration/shared/tls/)。

## 已有节点与回退

新的 Vision 节点使用独立分片 `conf/11_vless_tcp_reality_vision.json` 和独立密钥文件，保留原 Reality、VMess、Shadowsocks 分片及凭据。相同 Vision 节点不应通过重复安装来更新；端口与 UUID 使用菜单 5、6 的 Vision 子选项修改，菜单 8 重新显示链接。

本安装器管理的所有分片共用 `sing-box.service`，新增/修改会重启该服务，已有连接可能短暂中断。变更前备份、配置检查及失败回退沿用原安全补丁；失败后的恢复流程也可能重启旧服务，包括前期探测失败。通常最多保留 5 份完整备份，需人工恢复的备份受保护。未知安装目录或外部服务不自动接管。

本次发布仅更新安装器，没有重新部署已有 VPS，也没有改动 R3S 节点、分流、DNS 或设备配置。原 v0.1 文件及历史测试记录不变；新版本验证记录单独保存，不把旧测试结果当作本版验收。

## 验证范围

见本目录 [validation.json](validation.json) 及仓库 [回归测试](../../tests/test_vision_installer.py)。18 项检查全部完成：配置生成、旧节点及入口 IP 保留、链接导出、探测失败、端口冲突、失败回退、菜单品牌及固定下载命令；使用真实 sing-box 1.14.3 Darwin 核心检查生成配置，其余系统操作在临时目录模拟。

[可选真实协议测试](../../tests/test_vision_loopback.py) 在 macOS 本机运行真实服务端和 iOS 指纹客户端，REALITY 目标为 `www.kernel.org`，通过 Vision 隧道访问本地 HTTP 回显得到 200；所有监听仅在 127.0.0.1，测试进程及临时凭据已清理。该测试不等于新安装器的 Linux/systemd 完整部署，也不等于 Shadowrocket 分享链接导入验收。实际安装及客户端仍需在目标 VPS 上验收；本版不承诺跨网络长期可用或账号运营结果。

## 来源

基于 [v0.1 补丁](../original-v0.1/README.md)，上游固定快照为 [dabadabader/install@9efdde64](https://github.com/dabadabader/install/blob/9efdde64cb1de338aa7392fa0394c37ed25876c6/installer.sh)。此前的 `releases/v0.3` 重写版仍维持撤回使用推荐的状态。
