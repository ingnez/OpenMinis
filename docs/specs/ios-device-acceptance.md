# OpenMinis 真机验收

## 确认待测包

核对 Actions 产物的 `SOURCE_COMMIT.txt` 和 `SHA256SUMS`。在与产物相同的提交运行 IPA 校验。

```sh
shasum -a 256 -c SHA256SUMS
python3 scripts/check_ipa_promotion.py Minis-unsigned.ipa
python3 scripts/check_ipa_device_install.py --workspace-tools Minis-unsigned.ipa
```

## 签名与安装

用已配置 OpenMinis App ID、共享容器及扩展描述文件的开发团队签名。主 App、分享扩展、文件提供程序和 Widget 使用各自的描述文件，保留原有 App Group 和 iCloud 容器。可从同一提交用 Xcode 导出开发版，或用已有重签流程处理下载的 IPA。校验签名包后安装到专用测试手机，记录系统版本和包的 SHA。若设备上已有相同 Bundle ID，先核对签名团队和测试数据。

```sh
python3 scripts/check_ipa_device_install.py --signed --workspace-tools Minis-signed.ipa
```

官方 [ios-dev](https://github.com/OpenMinis/MinisSkills/tree/164395f193a56e3507ca98415383c7c16780da00/ios-dev) 提供手机重签和安装参考。它的单 App 样例需要为 OpenMinis 的扩展和共享容器分别验证。开发者模式和配对按自有测试设备的配置完成。

## 记录真机结果

使用 [iCTRL 官方配对客户端](https://github.com/OpenMinis/iCTRL/tree/bd053710b614963fe9dfd50862b596ec791bc7f6) 操作专用测试设备。用合成聊天和测试账号，避免截取真实对话和凭据。每个检查点可导出界面树和截图。

```sh
python3 scripts/ios_device_evidence.py capture --client ./ictrl_rpc.py \
  --host <已配对设备地址> --output evidence/01-bot-history --expect 到最新
```

| 检查 | 预期 |
|---|---|
| 冷启动、进入本地和 Bot | 成功进入，缓存历史可打开 |
| 长 Bot 会话甩动、到最新、横滑引用 | 阅读位置稳定，手动返回末尾，引用命中正确消息 |
| 本地长代码块和问题卡、Bot 流式回复 | 子滚动和聊天列表互不抢位，Markdown 完成后表格完整 |
| 本地及 Bot 的报告、磁盘扫描 | HTML 可打开，数字来自输入，软链接和超出扫描上限均有清楚的结果 |
| Bot 提醒草稿 | 修改列表或日期后可以保存，取消后系统提醒事项无变动 |
| 本地与 Bot 快捷指令草稿 | 生成可分享的 XML，开发者签名后在目标设备核验导入 |
| 分享、文件提供程序、Widget、iCloud 同步 | 签名后共享容器和扩展仍可用 |

闪退时用 [CoreDevice 工具](https://github.com/OpenMinis/MinisSkills/tree/71bcfc8/coredevice-toolkit) 导出本应用的 `.ips`，记录时间和操作。可在本地抽取异常与故障线程，不上传原日志。

```sh
python3 scripts/ios_device_evidence.py crash path/to/Minis.ips
```
