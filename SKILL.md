---
name: ai-text-audit-two-pass
description: Audit Chinese or English prose for visible AI-like and structural writing patterns using an observation-first two-pass method. Use for AI 文本审计, Quinn card revision, V11/V12-style quality review, anti-AI-feel analysis, or any request requiring first-pass observations, contextual calibration, and a user decision gate before rewriting.
---

# AI Text Audit Two Pass

## When to use

- Use when the task is an AI text audit, Quinn methodology card design/revision, article-quality review, or a similar request where visible phenomena must be separated from later explanation.
- Use when the user wants a first-pass scan, a second-pass contextual calibration, or a decision gate before revision.
- Use when the task includes anti-AI-feel revision planning after the audit.
- Do not use for unrelated coding, browsing, or generic writing tasks that do not depend on observation-first audit logic.

## Inputs / context to gather

1. Identify the exact text, card set, or article under review.
2. Check whether background context exists and keep it out of pass 1.
3. Confirm whether the task is only audit/archival or includes a user-facing revision decision.
4. If prior audit notes exist, search for `两遍制`, `候选升级级联漏判`, `Quinn`, `高密度关系管理`, `决策门`, and `V12质量审计与AI感修订决定`.

## Procedure

1. Run pass 1 with no project background.
   - Record only visible phenomena.
   - Do not cancel a hit because it seems semantically reasonable, functional, mature, or institutionally normal.
   - Mark a card as not hit only when the phenomenon is absent, the text is insufficient to observe it, or the relationship under test is already established.
2. Record candidates separately instead of collapsing them early.
   - For each important candidate, log four axes: `现象强度`, `功能支付`, `AI感贡献`, `来源贡献`.
   - Preserve borderline but visible candidates so they can participate in cross-card pattern checks later.
3. Run pass 2 after reading background.
   - Keep all pass-1 hits.
   - Use context only to adjust severity, diagnosis framing, remedy, and source explanation.
   - Check for whole-text patterns such as `显性导航`, `否定—转折—限定句群`, `平衡补丁`, `递进式复述`, `同构验证`, `段落自动闭环`, and `高密度关系管理`.
4. Produce the audit output.
   - State the original text or reviewed object.
   - Summarize the diagnosis.
   - Include reasons for and against modification.
   - State consequences of each path.
   - Present concrete options for the user.
5. Stop at the decision gate unless the user explicitly asks for a rewrite.
   - Do not auto-generate a new version just because the audit found issues.
6. If the task includes anti-AI-feel revision planning, keep the target explicit.
   - Reduce visible whole-text artifacts such as `高密度关系管理`, `显性导航`, `同构闭环`, `平衡补丁`, and `全文任务完成感`.
   - Do not frame the work as detector evasion or mechanical score reduction.
   - Preserve valid short judgments and colloquial phrasing; trim overfull intensity and redundant heading-echo navigation such as `回到`, `再看`, and `绕一圈`.

## Efficiency plan

- Start by freezing pass-1 observations in compact bullets; do not spend time debating source explanations before the visible pattern inventory exists.
- Reuse the same keyword set when searching memory: `观察`, `第二遍不得删除第一遍命中`, `级联漏判`, `四轴`, `决策门`, `V12质量审计与AI感修订决定`.
- If a known regression case is relevant, compare against `V11世界杯AI预测稿` before inventing new methodology.
- Stop early if the task clearly asks for audit archival only; do not drift into rewriting.

## Pitfalls and fixes

- Symptom: pass 1 misses obvious issues.
  - Likely cause: benign explanation was applied too early.
  - Fix: restore observation-first logging and defer explanation to pass 2.
- Symptom: whole-document AI patterning never becomes visible.
  - Likely cause: local candidates were downgraded too early.
  - Fix: keep candidates alive through synthesis and check cross-card accumulation.
- Symptom: audit output becomes an implicit publish approval.
  - Likely cause: the decision gate was skipped.
  - Fix: present options and wait for the user's explicit choice.
- Symptom: anti-AI-feel edits flatten the article or chase detector scores.
  - Likely cause: the revision target was defined as "lower AI" instead of reducing visible whole-text artifacts.
  - Fix: target the named artifact classes, preserve useful human phrasing, and keep self-audit separate from publish approval.

## Verification checklist

- Pass 1 was done without project background or clearly separated from contextual reasoning.
- No pass-1 hit was deleted in pass 2.
- Important candidates include the four-axis record or an equivalent separation.
- The output distinguishes visible phenomena from source/function explanation.
- The final deliverable includes a decision gate rather than an automatic rewrite.
- If anti-AI-feel revision is in scope, the plan explicitly targets visible artifact classes and does not promise detector evasion.
