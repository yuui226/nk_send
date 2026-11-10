# 照片效果预览素材来源

- 日期：2026-10-22
- 目标文件：`site/assets/effects-coast.webp`，1200 × 800（3:2），WebP quality 88。
- 生成模式：OpenAI 内置 `image_gen` 工具，遵循已读取的 imagegen 技能；未使用 CLI/API 回退或程序绘图。
- 使用目的：官网照片效果区的新预览照片，替换用户家中室内照片，独立于五组真实 App 控件。
- 画面：海边白墙、紫红三角梅、前景枝叶、蓝海与柔和日光阴影。没有 UI、文字、水印或边框；不指向特定真实景点。
- 后处理：仅用 `cwebp` 等比例缩放和 WebP 编码；未进行照片内容编辑、局部重绘或调色。
- 原始生成文件：`/Users/orys/.codex/generated_images/01a15f27-f1b8-7231-963f-ca3b6274907e/exec-f0047c9e-1af1-41f5-b2b2-833c399b01a7.png`。
- 检查：已目视确认前景花枝、墙面纹理、海面与天空，画面简洁，未见多余文字或界面元素。
- 来源界限：AI 生成的概念摄影素材，不是用户真实摄影作品、相机实拍样张或 App 效果处理结果。

## 完整生成提示词

```text
Use case: photorealistic-natural
Asset type: 3:2 landscape photograph for the photo-effects preview area of a photography application website. The output must be the photograph alone.
Primary request: A clean, beautifully composed coastal scene with a sunlit white plaster wall and blooming deep magenta bougainvillea. A small number of clear bougainvillea branches and green leaves form the foreground. Beyond the white wall, an airy turquoise-blue sea recedes to a simple distant horizon.
Style/medium: refined editorial travel photography, authentic natural textures and lens rendering, sophisticated but believable. This is a fictional coastal scene, not documentary photography of a named landmark.
Composition/framing: horizontal 3:2. Minimal, spacious composition, one elegant cascade of magenta flowers toward the left and upper-left, a low white plaster wall across the lower foreground, clean blue sea visible across the middle and right, generous unbusy sky. Clear visual hierarchy with enough wall and sea to reveal subtle color adjustments. No crowded or messy details.
Lighting/mood: gentle Mediterranean-like sunlight, luminous whites with preserved texture, soft leaf shadows on the white wall, calm cheerful atmosphere, balanced exposure. Natural subtle color and a restrained palette, not overprocessed.
Materials/textures: slightly textured matte white plaster, delicate papery bougainvillea petals, small glossy green leaves, distant fine shimmering seawater.
Constraints: a single photographic image only. No people, no animals, no furniture, no clutter, no signage, no letters, no numbers, no logo, no watermark, no frame, no border, no camera, no phone, no app UI. Avoid HDR, excessive saturation, fantasy buildings, artificial illustration or 3D rendering.
```

