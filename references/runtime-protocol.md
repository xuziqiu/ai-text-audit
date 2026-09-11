# XZQ文本审计流程 Harness

本协议只约束任务怎样冻结、分阶段保存、恢复、评分、验证和结束。它证明审计责任已经处理，不规定Agent必须从哪些角度发现问题；评分只在综合之后发生。

## 运行模式

- `即时运行`：无需保存或恢复时直接完成，不创建运行目录。
- `持久运行 compact`：保存原文、工作索引、来源、综合稿、报告、状态和验证结果。
- `持久运行 full_trace`：在compact基础上保存所有阶段稿和动态调查文件。

用户只要求导出最终报告，不自动等于持久运行。用户要求完整中间文件、Harness测试或跨上下文续作时使用full_trace。

## 初始化

使用：

```powershell
& scripts/manage-audit-run.ps1 -Action Init -RunPath <运行目录> -SourcePath <正文文件> -ArtifactProfile full_trace -FactCheck when_material
```

初始化必须：

- 冻结正文副本及SHA-256；
- 记录本Skill目录哈希；
- 建立`run.json`和阶段状态；
- 建立独立测试或运行目录；
- 不预先生成假装已完成的分析内容。

## 阶段顺序

1. `intake`
2. `first_read`
3. `reconstruction`
4. `open_scan`
5. `focused_review`
6. `fact_check`
7. `synthesis`
8. `report`（完成前必须生成评分卡）
9. `validation`

事实核查可以与重点复核交错执行，但必须在报告完成前处于`completed`、`partial`或`not_applicable`。其他阶段按依赖顺序完成。

## full_trace规定产物

```text
working/00-initial-core-judgment.md
working/01-writing-structure.md
working/02-content-function-map.md
working/03-open-scan.md
working/04-focused-review.md
working/05-report-coverage-draft.md
working/06-report-editorial-review.md
```

允许新增`working/investigations/*.md`，不得要求固定数量。`sources.md`、`synthesis.md`、`scorecard.json`、`report.md`和`validation.md`位于运行目录根部。

阶段完成时管理脚本记录对应产物哈希。初读快照和全面扫描稿尤其不得在后续阶段回写；若需解释变化，在重点复核或综合稿中追加说明。完整文本的`working/03-open-scan.md`必须含至少50个唯一的`OBS-###`候选观察编号，完成门与验证器都检查这一条件。

## 恢复

续作前执行：

```powershell
& scripts/manage-audit-run.ps1 -Action VerifyResume -RunPath <运行目录>
```

正文哈希或Skill哈希变化时停止自动续作。旧运行可以作为历史证据，但不能冒充当前Skill的结果。

## 完成门

- 没有初读快照，不得完成`first_read`；
- 没有行文骨架和内容作用地图，不得完成`reconstruction`；
- 没有开放扫描稿，或完整文本的扫描稿少于50条唯一候选观察，不得完成`open_scan`；
- 没有重点复核稿，不得完成`focused_review`；
- 需要事实核查时，没有来源稿不得解决`fact_check`；
- 没有独立综合稿，不得完成`synthesis`；
- 报告完成前，分析、核查和综合必须解决，且`scorecard.json`必须通过结构、十分制计算、质量带、核心任务裁决、门槛与把握度检查；
- full_trace没有覆盖稿和报告审校稿，不得完成`report`；
- 没有实质验证结果，不得完成`validation`或整个运行。

完成后运行：

```powershell
& scripts/validate-audit-run.ps1 -RunPath <运行目录>
```

运行验证依赖Python 3和`jsonschema`包，用于真正执行`run-manifest.schema.json`与`scorecard.schema.json`，而不是只检查少数字段。缺少依赖、Schema不合法或实例不合规时验证失败，不得降级成跳过。

将`validation`阶段标为完成时，管理脚本会先亲自运行验证器，成功后才冻结`validation.md`；将整个运行标为`completed`时会再次执行身份、产物、Schema和报告一致性验证。手工放置验证文件或只修改阶段状态不能绕过完成锁。

## 状态与限制

阶段状态使用`pending`、`in_progress`、`completed`、`partial`、`needs_input`、`not_applicable`或`failed`。整个运行使用`in_progress`、`partial`、`needs_input`、`superseded`、`failed`或`completed`。

`partial`、`needs_input`、`not_applicable`和`failed`必须记录具体原因。事实核查部分受限但文本内部判断仍可靠时可以partial交付；原文不完整或关键对象无法确定时才needs_input。

不要把隐藏思维链写入运行目录。中间文件保存可复核的观察、证据、判断、竞争解释和状态变化，不保存逐token推理过程。

## 评分产物

持久运行使用`assets/scorecard.schema.json`规定的结构。评分契约标识为`xzq-text-audit-score-v1`，维度和总分统一使用十分制，六维默认权重为25、20、20、12、10、13。运行清单记录评分契约和默认权重，`scorecard.json`分别记录综合质量分、核心任务裁决、内部硬门槛、本次适用维度、分数、把握度和详细依据；公开报告只投射读者需要看到的字段。

报告阶段完成时同时冻结`scorecard.json`、`working/05-report-coverage-draft.md`、`working/06-report-editorial-review.md`和`report.md`。续作验证必须检查这些产物哈希；修改评分或裁决后需要重新打开报告阶段或新建运行，不能静默改写已完成内容。
