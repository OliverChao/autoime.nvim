# autoime.nvim 性能优化实施方案

本方案基于 2026-11-18 的代码分析、真实输入法只读测量与临时原型验证。对应实现、本地 Neovim 配置与测试现已完成，结果见 [performance-results.md](performance-results.md)。以下保留实施前的设计依据与验收目标。

## 目标与范围

第一轮同时解决三个问题：异步模式下事件回调等待外部命令、快速模式切换时命令覆盖、重复 setup 与错误处理导致额外等待。保留“退出插入模式切默认输入法，重新进入时恢复”的使用习惯，以及用户手动选择输入法的能力。

已测基线：普通权限下，当前 InsertLeave 回调中位数 57.77 ms，临时原生异步原型中位数 0.48 ms；查询立即非零退出时，当前错误处理可导致约 5003 ms 等待。前两个测量各 15 次，真实输入法只读、切换替换为空函数。

验收关注两个独立指标：事件回调返回时间，以及系统输入法实际完成切换的时间。第一轮优化主要改善前者。异步不会消除 im-select 和 macOS 的处理时间，首个字符仍可能早于输入法切换完成。

## 模块与接口

| 文件 | 职责 |
| --- | --- |
| lua/autoime/init.lua | setup、启停 API、autocmd、配置入口；将事件转交 controller |
| lua/autoime/config/init.lua | 默认配置；setup 每次从默认值重新合并，不累积上一轮 opts |
| lua/autoime/runner.lua（新增） | 直接执行参数列表，统一异步/兼容同步结果、超时与取消；不决定切哪个输入法 |
| lua/autoime/controller.lua（新增） | 输入法记忆、单进程调度、最新模式、请求失效与恢复判断 |
| README.md | 配置与异步语义、版本兼容、首字延迟边界；修正示例中的 autoime_default 为 default_im |
| tests/ 与 scripts/bench.lua（实施时新增） | 行为回归与独立性能测量，正常使用时不加载 |

runner 内部接口建议为 run(argv, opts, done) -> handle。结果统一包含 code、stdout、stderr、timed_out、spawn_error；handle 支持 cancel。完成通知只能交付一次，并先完成任务清理，避免通知或调用方异常让进程永远处于 busy 状态。

异步后端优先检测 vim.system，使用 vim.system({path, ...}, {text=true, timeout=...}, on_exit)。没有 vim.system 时用列表形式 jobstart，缓冲 stdout/stderr，并用 timer + jobstop 实现超时。无需为异步加载 Plenary，不经 shell 拼接命令。vim.system/原生 job 回调涉及状态变更与通知时统一 schedule 到主循环。

async_if_able=false 保留为显式同步兼容模式；其等待仅存在于该分支，并同样有超时与结果校验。现代后端可 wait(timeout)，兼容后端可等待 jobstart 的完成标记。异步分支禁止 sync、wait、vim.fn.system 等阻塞等待。同步模式仍会等待查询和切换，文档应明确这一点。

## 配置与公开 API

第一轮保持 async_if_able 默认 false，避免未配置用户的时序语义突然变化；你已设置 true，会直接启用完整异步路径。把默认值改成 true 可在后续明确宣布兼容变化时进行。

建议用户配置：

```lua
opts = {
  im_select_path = "im-select",
  default_im = "com.apple.keylayout.ABC",
  autoime_enabled = true,
  async_if_able = true,
  timeout_ms = 1000,
  notify_on_error = true,
  _notice = false,
}
```

保留已有字段，新增 timeout_ms（每条命令，默认 1000 ms）与 notify_on_error（默认 true）。1 秒是超时预算，不是防抖或每次操作增加的等待。校验 opts 可为空、路径和默认输入法为非空字符串、timeout_ms 为正数、开关为布尔值。

保留 setup、enable_autoime、toggle_autoime、make_ime_default、make_ime_previous。增加正确拼写的 disable_autoime；旧 disable_samrtim 作为别名兼容。两个 make_ime 函数在异步模式下提交意图并返回，不承诺返回时系统切换完成。

M.pre_im、M.default_im、M.config 可保留为兼容状态视图。M.job、M.require_current、M.change_ime 目前承担内部实现职责，没有文档承诺；实施前搜索仓库用法，避免外部引用意外破坏。不要用这些可变字段作为新 controller 的唯一状态来源。

## 状态与调度不变量

每次 setup 创建独立 controller，建议维护以下状态：

| 状态 | 用途 |
| --- | --- |
| enabled / generation | 判断 controller 生命周期；旧实例回调只能清理，不能提交新状态 |
| mode / revision | 最新模式意图与版本；模式事件递增 revision |
| previous_im | 上一次有效捕获的用户输入法；初始为 default_im |
| in_flight | 一个正在执行的 query 或 setter，含 token、revision、target、handle |
| pending | 一个待处理的最新意图；新事件替换旧意图 |
| restore_needed / restore_target | 插件已发起切默认输入法后，是否仍需恢复，以及该次恢复应使用的输入法 |
| restoration_confirmed | 区分正常完成恢复的插入会话与仍可能停留在插件默认输入法的会话 |

全局最多一个外部进程、一个待处理意图。query 和 setter 都必须经过同一调度器。回调先释放当前 token，再处理结果和派生任务；递归或同步完成也不能覆盖新 in_flight。既有 setter 的完成不能被新的模式事件解释为用户手动选择。

generation 与 revision 分别处理生命周期和模式变化。generation 失效的结果不改变任何新实例状态；revision 过期的 query 不派生旧模式的 setter。给回调加版本判断不能撤销已经发出的 macOS 输入法请求，因此 setter 本身也必须串行。

previous_im 用作用户输入法记忆，不视为系统实时缓存。跨插入会话不能仅因为 previous_im 等于 default_im 就省略必要查询。

## 事件流程与关键边界

正常 InsertLeave：记录最新 normal 意图；等待已有进程结束，再查询。有效查询更新 previous_im；若当前仍是相同的 normal 意图且查询值不同于 default_im，发起默认 setter，并固定 restore_target。默认 setter 发起后记录 restore_needed；明确的启动失败证明进程未执行，可撤销该标记。运行后失败或超时的实际切换结果可能不确定，应保留恢复信息。

正常 InsertEnter：记录 insert 意图。只有 restore_needed 为真才需要恢复 restore_target；若默认 setter 在途，等待它结束后再恢复。恢复成功清理 restore_needed；恢复失败保留记忆与修复状态，等待后续真实事件驱动，不立即自旋重试。

### 查询未完成，快速 Esc -> i

如果插件尚未发起默认 setter，输入法还没有被插件改变，此时进入插入模式无需恢复。取消待执行的默认 setter，等查询回调清理，保持当前输入法。

这是正式方案必须补齐的边界：临时原型只有最新事件合并，没有 restore_needed 判断。补充测试显示，旧记忆为中文、当前手动选择日文时，查询未完成就重新进入会恢复旧中文。该原型不能直接作为正式补丁使用。

### 默认 setter 在途，快速 Esc -> i

已经发出的切换可能产生系统副作用，无法只靠忽略回调撤销。先等待该 setter 完成，再根据最新 insert 意图恢复固定的 restore_target。保证最终目标正确，但不承诺中间绝无短暂切换。

### 恢复 setter 在途，再次退出

等待恢复完成再进行新查询，避免读到插件尚未恢复的 ABC，并错误覆盖中文记忆。恢复失败时，若查询仍返回 default_im，应保护旧记忆，避免把可能由插件留下的默认输入法当成用户选择。若查询得到有效非默认输入法，可接受它为新的用户选择。

正常完成恢复的插入会话中，用户手动选择 ABC 后退出，应将 previous_im 更新为 ABC，下一次进入不强制切回旧中文。恢复失败时，插件无法区分“仍由插件留下的 ABC”与“用户此时手动选择 ABC”，采用保护旧记忆的策略并说明该边界。要彻底消除这种歧义，需要额外系统输入法通知或查询能力。

### 短时间出现很多事件

替换 pending 意图，保留最终 mode，避免 FIFO 队列不断积压。在途 query 尚未结束且最终回到 insert、没有默认 setter 发起时，可以仅完成这一条查询，不再执行无效切换。若最终停留在 normal，再按最新会话判断是否需要查询/默认切换。命令数量取决于执行期间的事件时序，验收首先保证队列长度有界与最终状态正确。

## 错误与生命周期

- 启动失败、非零退出、空输出、多行非法查询输出：保留 previous_im，不使用该输出发起默认 setter。
- stdout/stderr 分离。code=0、合法单行 stdout 时，stderr 可作为诊断信息，不能拼进输入法 ID；不对所有平台使用 macOS ID 格式的正则。
- setter 失败或超时：不能假定系统输入法完全没变。保留 restore_target；下一次模式事件按最新意图收敛，不无限重试。
- 通知使用主循环中的 vim.notify，替换 vim.warn。连续失败期间只提示首次错误，成功后重置提示状态；_notice 默认关闭。
- 每条命令超时后清理 timer、句柄和 busy 状态，只交付一次完成结果。超时不允许永久阻塞 pending。
- setup 使用具名 augroup(clear=true)，旧 controller 失效并尝试取消旧任务。新 controller 不接收旧回调。
- disable 停止派生新任务、清理 pending、尝试终止在途进程。已发出的 macOS 请求可能仍生效；不承诺取消可以撤销系统副作用。重新 enable 从当前模式重新建立有效状态，首个 InsertEnter 不强制使用失效的旧恢复意图。
- VimLeavePre 只做任务与资源清理，避免新增同步输入法操作。第一轮保持现有 InsertEnter/InsertLeave 事件范围，不增加 FocusGained/FocusLost、逐字符事件或后台轮询。
- lazy.nvim 在 InsertEnter 加载时，setup 只初始化和注册事件，不主动查询或切换；首次进入保持当前输入法。

## 实施顺序与可审查提交

1. 修复错误报告、配置初始化与重复 setup。用缺失命令、非零退出、空输出、setup 两次场景验证；记录现有同步基线。此阶段只解决错误与重复注册，不声称解决同步延迟。
2. 引入 runner 与 controller，一次交付完整异步查询、串行 setter、最新事件合并和 restore_needed 判断。上线可用的异步路径必须同时具备这些保护，不能先把查询改成异步、随后再修竞态。
3. 完成启停/重建/退出清理、同步兼容分支、原生与 jobstart 后端验证，以及公开 API 兼容。对新增的“旧记忆与当前输入法不同”场景优先补回归验证。
4. 完成基准、README 和本机集成验收。在本地配置启用 dir 指向工作区验证，正式实施时再修改 dotfile；当前方案不会改变它。

## 验收清单

| 场景 | 预期 |
| --- | --- |
| 初次 InsertEnter，当前中文 | 不强制切 ABC |
| 中文 -> Leave -> Enter | normal 收敛到 ABC，insert 收敛到中文 |
| 当前已经是 ABC，正常 Leave | 合法查询后不发 setter |
| 手动中文改 ABC，正常 Leave -> Enter | 记忆 ABC，不恢复旧中文 |
| 旧记忆中文、当前日文，query 在途时快速 Leave -> Enter | 保持日文，不发旧中文恢复 setter |
| 默认 setter 在途时 Enter | 串行恢复，最终中文 |
| 恢复 setter 在途时 Leave | 新查询等待 setter；记忆不被插件默认值覆盖 |
| 100 次快速模式事件 | pending 有界，最终状态符合最后事件 |
| 非零退出、空输出、非法多行输出 | 不覆盖记忆、不派生默认 setter、无 5 秒异常等待 |
| 启动失败、超时、setter 不确定失败 | 释放 busy，保护恢复信息，后续事件可继续执行 |
| setup 两次 | 每个事件只有一组业务回调 |
| disable/re-enable、在途时 setup、退出 | 无新实例状态污染或任务继续派生 |
| 含空格的可执行路径 | 参数列表正确启动，无字符串拆分错误 |
| 显式 async_if_able=false | 同步兼容行为可用，错误与超时受控 |
| vim.system 与 jobstart 两种后端 | 同样的输出解析、取消与一次完成语义 |

controller 测试通过受控 runner 回调模拟完成顺序，稳定验证状态变化；headless 集成验证真实外部进程、模式事件与定时器响应，避免仅测试浅层函数。真实 im-select 的性能基准仍只读查询；真实输入法切换与首字行为在日常 Neovim 会话中验收。

异步性能目标：本机普通权限下 warm 回调 p95 小于 5 ms；注入 120–500 ms 查询延迟时，回调仍在 20 ms 内返回，主循环定时器可以继续响应。基准等待上一轮任务完成后再采样下一轮，另设 burst 场景测合并效果，防止把进程减少与单次回调改善混为一谈。

首字验收分别记录 Esc 后 normal 操作、进入 insert 后第一个中文字符，以及快速 Esc -> i 的行为。系统切换耗时单独报告，不能拿 0.48 ms 的回调时间代表系统已切换完成。

## 后续方向

如果第一轮消除编辑器等待后，首字切换延迟仍显著，再评估常驻辅助进程或 macOS 原生输入法通知/接口，减少进程启动与重复查询。需要先测端到端切换耗时，再决定是否增加原生组件、平台维护和分发成本。第一轮不增加固定防抖、轮询或未经系统通知验证的跨会话输入法缓存。
