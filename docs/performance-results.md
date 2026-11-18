# 性能优化验证记录

2026-11-18，使用本机 Neovim v0.13.0-dev 与 macOS im-select 完成。真实系统测量在普通权限下运行，排除了沙箱中输入法服务连接错误造成的耗时放大。

实现已完成：查询和切换使用原生异步后端，兼容 jobstart；模式回调只更新意图并排队；一个在途进程与一个最新待执行意图；恢复标记保护用户手动选择；错误、超时、启停与重复 setup 有统一清理。

用户配置 `/Users/bytedance/dotfile/nvim/lua/plugins/tools/others.lua` 已启用 `dir = vim.fn.expand("~/code/lua/autoime.nvim")`。原有 enabled=true、ABC 默认输入法和 async_if_able=true 均保留。lazy-lock.json 无改动。

## 回归验证

- 原实现的慢查询回归在真实 InsertLeave 回调中失败，记录到 734.96 ms 同步等待。
- 最终 vim.system 后端：28/28 通过。
- 最终 jobstart 后端：28/28 通过，包括显式同步模式。
- 覆盖首次进入、正常切换、手动 ABC、不同旧记忆下快速重入、setter 在途、事件合并、查询错误和非法输出、超时、运行时可执行文件消失、恢复失败、重复 setup、启停和退出。
- 真实用户配置集成测试通过，确认实际加载源文件是本工作区的 `lua/autoime/init.lua`。
- 真实系统拼音 → ABC → 拼音往返测试通过，结束后确认原来的 ABC 已恢复。

## 性能结果

| 测量 | 样本 | 中位数 | p95 / 说明 |
| --- | ---: | ---: | --- |
| 优化前，async_if_able=true 的 InsertLeave 回调 | 15 | 57.77 ms | 范围 48.12–86.77 ms |
| 最终异步模式 InsertLeave 回调 | 30 | 0.02 ms | p95 0.02 ms，最大 0.03 ms |
| 最终异步模式真实查询完成 | 30 | 57.35 ms | p95 66.52 ms |
| 同步兼容模式 InsertLeave 回调 | 30 | 57.01 ms | p95 72.91 ms |

基准逐次等待上一查询完成，拦截所有 setter，因此数据不依赖事件合并，也不会改变系统输入法。回调耗时降低主要来自移除等待和把进程启动放到后续主循环。

整套用户配置的首次 InsertEnter 在一次集成测量中为 117.53 ms，包含同一事件触发的其他插件懒加载；该值不能归因于 autoime 本身。之后 InsertLeave 为 0.02 ms。

真实系统往返测试中，整套配置的 Leave/Enter 回调分别为 0.03/9.63 ms，包含其他事件处理器；切到 ABC 和恢复拼音的命令链完成分别为 109.70/72.46 ms。系统完成时间包括调度、外部命令和操作系统服务，独立于短回调时间。首个中文字符可能仍早于系统恢复完成，本次没有自动验证 GUI 中的输入法组词行为。

## 复现命令

在项目根目录执行：

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
AUTOIME_TEST_BACKEND=jobstart nvim --headless -u NONE -i NONE -l tests/run.lua
nvim --headless -u NONE -i NONE -l scripts/bench.lua
AUTOIME_BENCH_ASYNC=0 nvim --headless -u NONE -i NONE -l scripts/bench.lua
nvim --headless -i NONE -c "lua dofile('tests/configured.lua')" -c 'qa!'
stylua --check lua tests scripts
```

configured.lua 使用用户正常配置，确认本地插件路径后把命令映射到 fixture，不切换系统输入法。该测试应在独立 Neovim 中运行，会在结束时禁用该测试进程中的插件。

真实系统往返测试的驱动与输出保存在 `/private/tmp/autoime-perf-analysis`。驱动在 finally 中恢复测试前输入法，往返测量使用实际用户配置和真实 im-select，没有命令替换。
