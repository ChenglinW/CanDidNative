# 首轮产品页面约定

本轮为现有 SwiftUI App 的功能扩展，视觉依据是用户提供的《CanDid 场景流程与界面草图》及现有紫色、米白设计。原型的业务层级与随后用户确认优先于一般设计建议；不采用新的视觉方向、图片或字体依赖。

## Direction contract

THESIS：让下一场沟通、项目进展和已有依据在手机上随时可达。主路径为首页下一场 → 项目场次 → 会前、现场、会后；录音始终保存在全局库。

OWN-WORLD：沿用 Warm.paper、Warm.purple、Warm.lavender、Warm.orange，系统圆角字体和 SF Symbols。现场录音采用草图的深色专注界面，其余页面维持浅色温暖界面。深层页面使用原生导航与返回，首页底部采用四个导航目的地。

STORY：用户看到下一场和准备状态；按客户机会或岗位机会切换独立上下文；通过原文时间点核对准备包、复盘与行动。AI 自动整理与已确认个人事实有明确区分，新增跨场个人结论集中核对一次。

FIRST VIEWPORT：首页顶部用户头像和录音入口，下方场景筛选、下一场、进行中项目；固定输入位于系统导航栏上方。项目页呈现阶段、目标、参与方和横向场次时间线；问 Candid 显示当前范围与连续语音入口。

FORM：原生 SwiftUI Operate，扩展既有视觉体系。用户的 PDF 和已确认计划固定页面方向，不使用随机概念或替代布局。iPhone 与 iPad 均检查导航、输入可达性、长内容滚动和字号变化。

FINISH：unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## 实施与验收边界

首轮完成销售和面试流程、项目追踪与导出；飞书后置。软件测试使用隔离数据库、供应商替身和模拟器。真实手机安装暂停，录音豆按钮、回声抑制、实际 ASR 延迟与分人准确性另行验收。已有 mascot 图片不新增或替换，本轮没有生成或下载图片。
