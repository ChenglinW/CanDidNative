# 模拟沟通 · 原型阶段

首轮先交付可交互 HTML，确认入口和层级后接入 App。用户已确认：语音为主同时支持打字；结束后统一复盘，过程中主动点提示才给指导。

入口：首页会前准备常驻“模拟练习”（空态也可达）；准备包“模拟这一场”；空间菜单“模拟这次沟通”；FAQ“练这道题”。不增加第四个 Tab，不占用输入下方工作区／复盘位置。

流程：主页 → 场景准备 → 整场模拟 → 练后复盘／重练。销售和面试分别带入相关资料，少填表。原型以演示数据呈现，不启用麦克风、不调用模型、不保存真实记忆。

## Direction contract

THESIS: 在现有会前准备中提供一次可立即开始的场景演练，保留普通助手和真实沟通的层级。
OWN-WORLD: 沿用 Warm 米白、近白色面、紫色动作、淡紫准备区域、暖橙主要按钮、系统圆角字体、原 Mascot；页内实色分段，主导航保留原生液态玻璃意图。
STORY: 自动带入对象目标资料，进入角色问答，结束后只聚焦具体改进并可重练。
FIRST VIEWPORT: 原型首页常驻模拟入口与准备卡，不挤占工作区和上一场复盘；练习页是独立返回层级、对话区和固定语音控制。
FORM: code-led extension of the approved CanDid HTML and native design, existing-world reuse; no new world or concept seed.
FINISH: bounded browser interaction and visual review, corrections if needed, screenshot evidence and honest prototype-only handoff. No App implementation or production deployment is claimed.

## 原型确认后的原生实现

用户已批准 HTML，授权完成 SwiftUI、独立模拟引擎、记忆库选题、真实语音、测试及 master／服务器／iPhone 交付。保留旧单题逐轮点评入口。语音复用 VoiceCapture、WebRTC VAD、VoiceASRSegment 与现有 DashScope TTS，练习模型沿用百炼 DeepSeek V4 Pro。
