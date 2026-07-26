# UI 皮肤系统 — 实现方案存档

> 状态：**已实现但已撤回**。代码可用，等需要时按本文档重新落地。
> 撤回原因：本轮先聚焦监看页功能，皮肤留作后续独立迭代。

## 2026-07 更新：皮肤只影响按钮 + 程序化纹理

实际落地版与下文原方案有两点关键差异（现有 3 款皮肤：毛玻璃/皮革/木纹）：

1. **token 拆分**：`AppColors` 新增 4 个按钮专属 token——`buttonSurface` /
   `buttonHighlightTop` / `buttonHighlightBottom` / `buttonSheen`。`GlassButton`
   改读 button*；面板/弹窗/提示条（含 `GlassSurface`）继续读 glass*。皮革/木纹
   工厂**只覆写这 4 个 button* token**，不再碰 glass*——换皮肤只换按钮材质，
   设置卡片、弹层、提示条在三款皮肤下逐字节一致。默认皮肤下 button* 与
   glass* 同值，视觉零变化。
2. **程序化纹理**（`ui/theme/SkinTexture.kt`）：不用图片资源，运行时按
   (皮肤, 深浅) 生成一张 128×128 无缝平铺 tile（木纹=整数频率正弦条痕 +
   周期扰动；皮革=环面 Worley 荔枝纹），透明度烘焙进像素（深色 0.35/0.40，
   浅色 0.22/0.25），进程级缓存。经 `LocalButtonTexture`（`Brush?`）由
   `ZTransferTheme` 下发，仅 `GlassButton` 在底色与高光之间叠加一层；
   毛玻璃皮肤为 null，面板永远无纹理。

---

## 为什么这个功能很便宜

App 现有架构已经完全为此准备好了：

- `AppColors` 是一个 **25 个语义 token** 的 `@Immutable data class`
- 所有 UI 元素通过 `AppTheme.colors.xxx` 取色，**从不硬编码颜色值**
- `GlassButton` / `GlassSurface` 的毛玻璃渲染逻辑是 **token 无关的**——它只是把 token 组合成渐变，不关心具体色值

所以「加一套皮肤」= 「给同样这些 token 提供另一组值」，渲染代码一行不用改。

### 毛玻璃效果的本质

```
毛玻璃 = glassSurface 底色
       + 自上而下高光渐变 (glassHighlightTop → glassHighlightBottom)
       + 上亮下暗描边   (glassBorderTop → glassBorderBottom)
       + glassSheen 顶部叠层
```

换成**皮革**就是把这几个 token 换成暖棕/奶油色调的透明度组合；换成**木纹**换成琥珀/金色调。质感差异完全由 token 值表达。

---

## 改动范围

| 文件 | 改什么 | 约行数 |
|---|---|---|
| `ui/theme/Color.kt` | `SkinPreset` enum + `skinAppColors()` + 7 个工厂对象 | ~250 |
| `ui/theme/Theme.kt` | `ZTransferTheme` 加 `skinPreset` 参数 + 分发 | ~3 |
| `viewmodel/TransferViewModel.kt` | 状态字段 + SharedPreferences 持久化 + setter | ~12 |
| `MainActivity.kt` | 传 `skinPreset = transferState.skinPreset` | ~1 |
| `ui/screen/SettingsScreen.kt` | 「界面」卡片内加皮肤选择器 | ~22 |
| `res/values*/strings.xml` × 3 | 6 个 key × 3 语言 | ~18 |

**零改动的文件**：`GlassButton.kt`、`RemoteScreen.kt`、`FileListScreen.kt`、`HomeScreen.kt`、`TransferScreen.kt`、`PhotoPreview.kt`、`LicenseDialogs.kt`、`PurchaseDialog.kt`、`AnchorPopup.kt`、`AppUpdateDialog.kt` —— 全部页面自动生效。

---

## 五套皮肤设计

| 皮肤 | 中文名 | 色调 | 毛玻璃不透明度 | 高光色 | 备注 |
|---|---|---|---|---|---|
| `FROSTED_GLASS` | 毛玻璃 | 中性灰 | 0.45 / 0.85 | 纯白 | 现有默认，不变 |
| `LEATHER` | 皮革 | 暖棕 `#1A1510` | 0.55 / 0.88 | 暖奶油 `#F5E6D0` | 哑光质感，略不透 |
| `WOOD` | 木纹 | 琥珀 `#1E1810` | 0.48 / 0.88 | 金色 `#FFE082` | 中等透明 |
| `SOLID` | 纯色 | 同默认 | 0.88 / 0.95 | 极淡白 (0.04) | 弱化玻璃感，实色面板 |
| `NIGHT` | 暗夜 | 近黑 `#080808` | 0.35 | 微光 (0.04) | 仅深色，遮罩加深到 0.55 |

---

## 落地步骤

### 1. `Color.kt` — 枚举 + 分发 + 工厂

```kotlin
import com.ztransfer.R   // ← 必须加，enum 引用了 R.string

/** 皮肤预设枚举，每种皮肤对应一组 AppColors（深色 + 浅色，NIGHT 仅深色）。 */
enum class SkinPreset(val displayNameResId: Int) {
    FROSTED_GLASS(R.string.skin_frosted_glass),
    LEATHER(R.string.skin_leather),
    WOOD(R.string.skin_wood),
    SOLID(R.string.skin_solid),
    NIGHT(R.string.skin_night)
}

fun skinAppColors(skin: SkinPreset, dark: Boolean): AppColors = when (skin) {
    SkinPreset.FROSTED_GLASS -> if (dark) DarkAppColors else LightAppColors
    SkinPreset.LEATHER -> if (dark) DarkLeatherColors else LightLeatherColors
    SkinPreset.WOOD -> if (dark) DarkWoodColors else LightWoodColors
    SkinPreset.SOLID -> if (dark) DarkSolidColors else LightSolidColors
    SkinPreset.NIGHT -> if (dark) DarkNightColors else LightAppColors
}
```

七个工厂对象的完整代码见文末附录。

### 2. `Theme.kt`

```kotlin
fun ZTransferTheme(
    themeMode: ThemeMode = ThemeMode.SYSTEM,
    skinPreset: SkinPreset = SkinPreset.FROSTED_GLASS,   // ← 新增
    content: @Composable () -> Unit
) {
    // ...
    val appColors = skinAppColors(skinPreset, darkTheme)  // ← 替换原来的 if/else
```

### 3. `TransferViewModel.kt`

```kotlin
import com.ztransfer.ui.theme.SkinPreset

// TransferState 内：
val skinPreset: SkinPreset = SkinPreset.FROSTED_GLASS,

// init 读取：
skinPreset = runCatching {
    SkinPreset.valueOf(prefs.getString("skin_preset", SkinPreset.FROSTED_GLASS.name)!!)
}.getOrDefault(SkinPreset.FROSTED_GLASS),

// setter：
fun setSkinPreset(skin: SkinPreset) {
    prefs.edit().putString("skin_preset", skin.name).apply()
    _state.update { it.copy(skinPreset = skin) }
}
```

### 4. `MainActivity.kt`

```kotlin
ZTransferTheme(
    themeMode = transferState.themeMode,
    skinPreset = transferState.skinPreset,   // ← 新增
) { ... }
```

### 5. `SettingsScreen.kt` — 「界面」卡片内，语言选择器之后

```kotlin
// UI 皮肤
SectionLabel(
    stringResource(R.string.cd_skin),
    modifier = Modifier.padding(bottom = 8.dp)
)
SkinPreset.entries.chunked(3).forEachIndexed { rowIndex, rowItems ->
    if (rowIndex > 0) Spacer(Modifier.height(8.dp))
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        rowItems.forEach { skin ->
            SelectionChip(
                label = stringResource(skin.displayNameResId),
                selected = state.skinPreset == skin,
                onClick = { viewModel.setSkinPreset(skin) },
                compact = true,
                modifier = Modifier.weight(1f)
            )
        }
    }
}
```

5 个皮肤按 `chunked(3)` 排成 3+2 两行，复用现有的 `SelectionChip` 和 `SectionLabel`。

### 6. 字符串（3 个语言文件）

| key | EN | zh | zh-Hant |
|---|---|---|---|
| `skin_frosted_glass` | Frosted Glass | 毛玻璃 | 毛玻璃 |
| `skin_leather` | Leather | 皮革 | 皮革 |
| `skin_wood` | Wood | 木纹 | 木紋 |
| `skin_solid` | Solid | 纯色 | 純色 |
| `skin_night` | Night | 暗夜 | 暗夜 |
| `cd_skin` | UI Skin | 界面皮肤 | 介面皮膚 |

---

## 已知坑

1. **`Color.kt` 必须 `import com.ztransfer.R`** —— enum 引用了 `R.string.*`，同包内也要显式导入，否则 `Unresolved reference: R`。
2. **NIGHT 无浅色变体** —— `skinAppColors` 在浅色模式下回退 `LightAppColors`。若想更严谨，可在设置里把 NIGHT 标注为「仅深色」，或选中时自动切到深色模式。
3. **`SelectionChip` 的实际签名要核对** —— 本方案基于它接受 `label` / `selected` / `onClick` / `compact` / `modifier`。落地前先读一遍 `SettingsScreen.kt` 确认。

---

## 后续可扩展方向

- **真实纹理**：现在皮革/木纹只是色调差异。若要真纹理，可在 `AppColors` 加一个 `surfaceTexture: Painter?` token，`GlassSurface` 里叠一层低透明度的可平铺纹理图。这会引入 drawable 资源和额外一层绘制开销。
- **强调色也跟皮肤走**：目前所有皮肤共用同一套 accent 色。若想皮革配铜色强调、木纹配深绿，把 `accentBlue` 等也纳入皮肤差异即可（改动仍在同一批工厂对象内）。
- **用户自定义**：token 全在一个 data class 里，理论上可以做「自定义皮肤」让用户调几个关键色再派生出整套 token。

---

## 附录：七个工厂对象完整代码

```kotlin
// ================================================================================================
// 皮肤系统：皮革 (LEATHER) — 暖棕色调，略带不透，哑光质感
// ================================================================================================

/**
 * 皮革·深色：暖棕深底，表面带暖奶油高光/描边，哑光质感。
 * background 使用较默认主题更暖的深棕，毛玻璃基色改为暖棕并提高不透明度。
 */
val DarkLeatherColors = AppColors(
    background = Color(0xFF1A1510),
    backgroundTop = Color(0xFF201A14),
    backgroundBottom = Color(0xFF100C08),
    surface = Color(0xFF241E16),
    surfaceVariant = Color(0xFF2E2820),
    onBackground = DarkOnBackground,
    onSurfaceVariant = DarkOnSurfaceVariant,
    accentBlue = AccentBlue,
    accentOrange = AccentOrange,
    accentYellow = AccentYellow,
    accentPurple = AccentPurple,
    statusConnected = StatusConnected,
    statusError = StatusError,
    statusWaiting = StatusWaiting,
    onAccent = Color(0xFF1A1510),
    glassSurface = Color(0xFF241E16).copy(alpha = 0.55f),
    glassSurfaceHeavy = Color(0xFF241E16).copy(alpha = 0.92f),
    glassHighlightTop = Color(0xFFF5E6D0).copy(alpha = 0.10f),
    glassHighlightBottom = Color(0xFFF5E6D0).copy(alpha = 0.03f),
    glassBorderTop = Color(0xFFF5E6D0).copy(alpha = 0.25f),
    glassBorderBottom = Color(0xFFF5E6D0).copy(alpha = 0.06f),
    glassPanelBorder = Color(0xFFF5E6D0).copy(alpha = 0.10f),
    glassSheen = Color(0xFFF5E6D0).copy(alpha = 0.05f),
    scrim = Color.Black.copy(alpha = 0.4f),
    thumbPlaceholder = Color(0xFF241E16),
    cardHairline = Color.Transparent,
)

/** 皮革·浅色：沙色/米色底，暖调毛玻璃面板。 */
val LightLeatherColors = AppColors(
    background = Color(0xFFF5EDE0),
    backgroundTop = Color(0xFFFAF4EB),
    backgroundBottom = Color(0xFFEDE2D0),
    surface = Color(0xFFFFFBF5),
    surfaceVariant = Color(0xFFF0E8D8),
    onBackground = LightOnBackground,
    onSurfaceVariant = LightOnSurfaceVariant,
    accentBlue = LightAccentBlue,
    accentOrange = LightAccentOrange,
    accentYellow = LightAccentYellow,
    accentPurple = LightAccentPurple,
    statusConnected = LightStatusConnected,
    statusError = LightStatusError,
    statusWaiting = LightStatusWaiting,
    onAccent = Color.White,
    glassSurface = Color(0xFFFFF5E8).copy(alpha = 0.88f),
    glassSurfaceHeavy = Color(0xFFFFF5E8).copy(alpha = 0.95f),
    glassHighlightTop = Color(0xFFF5E6D0).copy(alpha = 0.55f),
    glassHighlightBottom = Color(0xFFF5E6D0).copy(alpha = 0.08f),
    glassBorderTop = Color(0xFFF5E6D0).copy(alpha = 0.90f),
    glassBorderBottom = Color(0xFF8D6E4F).copy(alpha = 0.06f),
    glassPanelBorder = Color(0xFF8D6E4F).copy(alpha = 0.08f),
    glassSheen = Color(0xFFF5E6D0).copy(alpha = 0.45f),
    scrim = Color.Black.copy(alpha = 0.32f),
    thumbPlaceholder = Color(0xFFEBE0D0),
    cardHairline = Color(0xFF8D6E4F).copy(alpha = 0.06f),
)

// ================================================================================================
// 皮肤系统：木纹 (WOOD) — 琥珀/金色调，中等透明度
// ================================================================================================

/** 木纹·深色：琥珀深棕底，金色高光/描边。 */
val DarkWoodColors = AppColors(
    background = Color(0xFF1E1810),
    backgroundTop = Color(0xFF261F15),
    backgroundBottom = Color(0xFF160F08),
    surface = Color(0xFF281F14),
    surfaceVariant = Color(0xFF32291E),
    onBackground = DarkOnBackground,
    onSurfaceVariant = DarkOnSurfaceVariant,
    accentBlue = AccentBlue,
    accentOrange = AccentOrange,
    accentYellow = AccentYellow,
    accentPurple = AccentPurple,
    statusConnected = StatusConnected,
    statusError = StatusError,
    statusWaiting = StatusWaiting,
    onAccent = Color(0xFF1E1810),
    glassSurface = Color(0xFF281F14).copy(alpha = 0.48f),
    glassSurfaceHeavy = Color(0xFF281F14).copy(alpha = 0.92f),
    glassHighlightTop = Color(0xFFFFE082).copy(alpha = 0.10f),
    glassHighlightBottom = Color(0xFFFFE082).copy(alpha = 0.03f),
    glassBorderTop = Color(0xFFFFE082).copy(alpha = 0.28f),
    glassBorderBottom = Color(0xFFFFE082).copy(alpha = 0.07f),
    glassPanelBorder = Color(0xFFFFE082).copy(alpha = 0.10f),
    glassSheen = Color(0xFFFFE082).copy(alpha = 0.05f),
    scrim = Color.Black.copy(alpha = 0.4f),
    thumbPlaceholder = Color(0xFF281F14),
    cardHairline = Color.Transparent,
)

/** 木纹·浅色：淡木色调面板，金色微光。 */
val LightWoodColors = AppColors(
    background = Color(0xFFF5F0E5),
    backgroundTop = Color(0xFFFAF6EE),
    backgroundBottom = Color(0xFFEDE4D5),
    surface = Color(0xFFFFFBF2),
    surfaceVariant = Color(0xFFF0E8D8),
    onBackground = LightOnBackground,
    onSurfaceVariant = LightOnSurfaceVariant,
    accentBlue = LightAccentBlue,
    accentOrange = LightAccentOrange,
    accentYellow = LightAccentYellow,
    accentPurple = LightAccentPurple,
    statusConnected = LightStatusConnected,
    statusError = LightStatusError,
    statusWaiting = LightStatusWaiting,
    onAccent = Color.White,
    glassSurface = Color(0xFFFFF6E8).copy(alpha = 0.88f),
    glassSurfaceHeavy = Color(0xFFFFF6E8).copy(alpha = 0.95f),
    glassHighlightTop = Color(0xFFFFE082).copy(alpha = 0.55f),
    glassHighlightBottom = Color(0xFFFFE082).copy(alpha = 0.08f),
    glassBorderTop = Color(0xFFFFE082).copy(alpha = 0.90f),
    glassBorderBottom = Color(0xFF8D6E3F).copy(alpha = 0.06f),
    glassPanelBorder = Color(0xFF8D6E3F).copy(alpha = 0.08f),
    glassSheen = Color(0xFFFFE082).copy(alpha = 0.45f),
    scrim = Color.Black.copy(alpha = 0.32f),
    thumbPlaceholder = Color(0xFFEBE0D0),
    cardHairline = Color(0xFF8D6E3F).copy(alpha = 0.06f),
)

// ================================================================================================
// 皮肤系统：纯色 (SOLID) — 高不透明度，弱化毛玻璃通透感，更接近传统实色面板
// ================================================================================================

/** 纯色·深色：面板近乎不透明，高光/描边极淡，呈现实心深色面板。 */
val DarkSolidColors = AppColors(
    background = DarkBackground,
    backgroundTop = Color(0xFF181818),
    backgroundBottom = Color(0xFF0D0D0D),
    surface = DarkSurface,
    surfaceVariant = DarkSurfaceVariant,
    onBackground = DarkOnBackground,
    onSurfaceVariant = DarkOnSurfaceVariant,
    accentBlue = AccentBlue,
    accentOrange = AccentOrange,
    accentYellow = AccentYellow,
    accentPurple = AccentPurple,
    statusConnected = StatusConnected,
    statusError = StatusError,
    statusWaiting = StatusWaiting,
    onAccent = DarkBackground,
    glassSurface = DarkSurface.copy(alpha = 0.88f),
    glassSurfaceHeavy = DarkSurface.copy(alpha = 0.98f),
    glassHighlightTop = Color.White.copy(alpha = 0.04f),
    glassHighlightBottom = Color.White.copy(alpha = 0.01f),
    glassBorderTop = Color.White.copy(alpha = 0.18f),
    glassBorderBottom = Color.White.copy(alpha = 0.05f),
    glassPanelBorder = Color.White.copy(alpha = 0.10f),
    glassSheen = Color.White.copy(alpha = 0.03f),
    scrim = Color.Black.copy(alpha = 0.4f),
    thumbPlaceholder = DarkSurface,
    cardHairline = Color.Transparent,
)

/** 纯色·浅色：面板近乎全白，玻璃感极弱。 */
val LightSolidColors = AppColors(
    background = LightBackground,
    backgroundTop = Color(0xFFF8F8FB),
    backgroundBottom = Color(0xFFEBEBF1),
    surface = LightSurface,
    surfaceVariant = LightSurfaceVariant,
    onBackground = LightOnBackground,
    onSurfaceVariant = LightOnSurfaceVariant,
    accentBlue = LightAccentBlue,
    accentOrange = LightAccentOrange,
    accentYellow = LightAccentYellow,
    accentPurple = LightAccentPurple,
    statusConnected = LightStatusConnected,
    statusError = LightStatusError,
    statusWaiting = LightStatusWaiting,
    onAccent = Color.White,
    glassSurface = Color.White.copy(alpha = 0.95f),
    glassSurfaceHeavy = Color.White.copy(alpha = 0.98f),
    glassHighlightTop = Color.White.copy(alpha = 0.40f),
    glassHighlightBottom = Color.White.copy(alpha = 0.08f),
    glassBorderTop = Color.White.copy(alpha = 0.80f),
    glassBorderBottom = Color.Black.copy(alpha = 0.06f),
    glassPanelBorder = Color.Black.copy(alpha = 0.08f),
    glassSheen = Color.White.copy(alpha = 0.30f),
    scrim = Color.Black.copy(alpha = 0.32f),
    thumbPlaceholder = Color(0xFFE6E6EB),
    cardHairline = Color.Black.copy(alpha = 0.06f),
)

// ================================================================================================
// 皮肤系统：夜景 (NIGHT) — 极暗，微光，仅深色变体
// ================================================================================================

/**
 * 夜景·深色：近乎全黑底，极通透玻璃纹理，微弱高光/描边，更深遮罩。
 * 无对应浅色变体——skinAppColors 在浅色模式下自动回退到 LightAppColors。
 */
val DarkNightColors = AppColors(
    background = Color(0xFF080808),
    backgroundTop = Color(0xFF0C0C0C),
    backgroundBottom = Color(0xFF040404),
    surface = Color(0xFF141414),
    surfaceVariant = Color(0xFF1E1E1E),
    onBackground = DarkOnBackground,
    onSurfaceVariant = DarkOnSurfaceVariant,
    accentBlue = AccentBlue,
    accentOrange = AccentOrange,
    accentYellow = AccentYellow,
    accentPurple = AccentPurple,
    statusConnected = StatusConnected,
    statusError = StatusError,
    statusWaiting = StatusWaiting,
    onAccent = Color(0xFF080808),
    glassSurface = Color(0xFF141414).copy(alpha = 0.35f),
    glassSurfaceHeavy = Color(0xFF141414).copy(alpha = 0.85f),
    glassHighlightTop = Color.White.copy(alpha = 0.04f),
    glassHighlightBottom = Color.White.copy(alpha = 0.01f),
    glassBorderTop = Color.White.copy(alpha = 0.12f),
    glassBorderBottom = Color.White.copy(alpha = 0.03f),
    glassPanelBorder = Color.White.copy(alpha = 0.06f),
    glassSheen = Color.White.copy(alpha = 0.02f),
    scrim = Color.Black.copy(alpha = 0.55f),
    thumbPlaceholder = Color(0xFF141414),
    cardHairline = Color.Transparent,
)
```
