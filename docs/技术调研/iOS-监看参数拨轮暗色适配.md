# iOS 监看参数拨轮暗色适配

## Android 行为依据

- 监看页参数拨轮使用主题 `glassSurface`、上下高光和自适应描边；标签、数值、AUTO 角标和只读状态全部读取深浅色 token，不使用固定白底。

## iOS 修正

- 移除 `RemoteExposureTile` 的固定 `Color.white.opacity(0.88)` 卡片和白色 AUTO 底色，改用共享 `ZTransferGlassSurface(kind: .button)`。
- 描边、投影、AUTO 未启用底色根据 `colorScheme` 调整；数值和标签继续使用自适应主/次文字色。浅色模式保持原有轻玻璃观感，暗色模式不再出现突兀白块。
- 拖动档位、触感、只读压暗、自动 ISO 和点击打开完整列表的业务逻辑未改动。

## 验证

- 2026-09-18：与 AP 信号及队列 Liquid Glass 适配一起完成 Debug 模拟器构建，`BUILD SUCCEEDED`。
