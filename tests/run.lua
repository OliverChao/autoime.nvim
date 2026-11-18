local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
if vim.env.AUTOIME_TEST_PLENARY_PATH then
	vim.opt.runtimepath:append(vim.env.AUTOIME_TEST_PLENARY_PATH)
end
if vim.env.AUTOIME_TEST_BACKEND == "jobstart" then
	vim.system = nil
end
local ime = require("autoime")
local uv = vim.uv or vim.loop
local defaults = "ime.default"
local chinese = "ime.chinese"
local japanese = "ime.japanese"
local tests, directories = {}, {}
local notices = {}
vim.notify = function(message, level)
	notices[#notices + 1] = { message = message, level = level }
end
local function eq(actual, expected, message)
	assert(
		vim.deep_equal(actual, expected),
		(message or "unexpected result")
			.. "\nexpected: "
			.. vim.inspect(expected)
			.. "\nactual: "
			.. vim.inspect(actual)
	)
end
local function write(path, value)
	local f = assert(io.open(path, "w"))
	f:write(value)
	f:close()
end
local function read(path)
	local f = io.open(path, "r")
	if not f then
		return ""
	end
	local value = f:read("*a")
	f:close()
	return value
end
local function wait(predicate, message)
	assert(vim.wait(3000, predicate, 2), message or "operation did not finish")
end
local function event(name)
	vim.api.nvim_exec_autocmds(name, {})
end
local function idle()
	local controller = ime._controller
	return not controller or (not controller.in_flight and not controller.pending)
end
local function context(config, initial, opts)
	ime.disable_samrtim()
	notices = {}
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	directories[#directories + 1] = dir
	vim.env.AUTOIME_TEST_DIR = dir
	write(dir .. "/config.json", vim.json.encode(config or {}))
	write(dir .. "/ime", (initial or chinese) .. "\n")
	write(dir .. "/events.jsonl", "")
	local options = vim.tbl_extend("force", {
		im_select_path = root .. "/tests/fixtures/im-select.py",
		default_im = defaults,
		async_if_able = true,
		autoime_enabled = true,
		timeout_ms = 2000,
	}, opts or {})
	ime.setup(options)
	local ctx = { dir = dir, opts = options }
	function ctx.config(value)
		write(dir .. "/config.json", vim.json.encode(value))
	end
	function ctx.current()
		return vim.trim(read(dir .. "/ime"))
	end
	function ctx.select(value)
		write(dir .. "/ime", value .. "\n")
	end
	function ctx.release(target)
		write(dir .. "/release-" .. (target or "query"), "")
	end
	function ctx.events(kind, target, stage)
		local results = {}
		for line in read(dir .. "/events.jsonl"):gmatch("[^\n]+") do
			local item = vim.json.decode(line)
			if item.kind == kind and (not target or item.target == target) and item.event == (stage or "start") then
				results[#results + 1] = item
			end
		end
		return results
	end
	return ctx
end
local function establish_memory(ctx)
	event("InsertLeave")
	wait(idle)
	eq(ctx.current(), defaults)
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), chinese)
	eq(ime.pre_im, chinese)
end
local function test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

test("async callback returns immediately", function()
	local ctx = context({ query_delay_ms = 150 })
	local ticks = 0
	local timer = uv.new_timer()
	timer:start(
		5,
		5,
		vim.schedule_wrap(function()
			ticks = ticks + 1
		end)
	)
	local start = uv.hrtime()
	event("InsertLeave")
	local elapsed = (uv.hrtime() - start) / 1e6
	timer:stop()
	timer:close()
	assert(elapsed < 20, string.format("InsertLeave blocked for %.2f ms", elapsed))
	timer = uv.new_timer()
	timer:start(
		5,
		5,
		vim.schedule_wrap(function()
			ticks = ticks + 1
		end)
	)
	wait(function()
		return ticks >= 3
	end, "main loop did not respond while query was running")
	assert(not idle(), "slow query should still be running")
	timer:stop()
	timer:close()
	wait(idle)
	eq(ctx.current(), defaults)
	eq(ime.pre_im, chinese)
end)

test("first InsertEnter preserves current selection", function()
	local ctx = context()
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), chinese)
	eq(#ctx.events("query"), 0)
	eq(#ctx.events("set"), 0)
end)

test("normal transitions restore the captured input method", function()
	local ctx = context()
	establish_memory(ctx)
end)

test("default input does not dispatch a setter", function()
	local ctx = context({}, defaults)
	event("InsertLeave")
	wait(idle)
	eq(ime.pre_im, defaults)
	eq(#ctx.events("query"), 1)
	eq(#ctx.events("set"), 0)
end)

test("manual default selection replaces previous memory", function()
	local ctx = context()
	establish_memory(ctx)
	ctx.select(defaults)
	event("InsertLeave")
	wait(idle)
	event("InsertEnter")
	wait(idle)
	eq(ime.pre_im, defaults)
	eq(ctx.current(), defaults)
	eq(#ctx.events("set"), 2)
end)

test("quick reentry does not restore stale memory", function()
	local ctx = context()
	establish_memory(ctx)
	ctx.select(japanese)
	ctx.config({ block_query = true })
	event("InsertLeave")
	wait(function()
		return #ctx.events("query") == 2
	end)
	event("InsertEnter")
	ctx.release()
	wait(idle)
	eq(ctx.current(), japanese)
	eq(#ctx.events("set"), 2)
	ctx.config({})
	event("InsertLeave")
	wait(idle)
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), japanese)
	eq(ime.pre_im, japanese)
end)

test("in-flight default setter cannot overwrite a later restore", function()
	local ctx = context({ block_sets = { defaults } })
	event("InsertLeave")
	wait(function()
		return #ctx.events("set", defaults) == 1
	end)
	event("InsertEnter")
	eq(ime._controller.in_flight.kind, "default")
	ctx.release(defaults)
	wait(idle)
	eq(ctx.current(), chinese)
	eq(ime.pre_im, chinese)
	local events = ctx.events("set", nil, "end")
	eq(events[1].target, defaults)
	eq(events[2].target, chinese)
end)

test("new capture waits until restoration completes", function()
	local ctx = context()
	event("InsertLeave")
	wait(idle)
	ctx.config({ block_sets = { chinese } })
	event("InsertEnter")
	wait(function()
		return #ctx.events("set", chinese) == 1
	end)
	event("InsertLeave")
	eq(ime._controller.in_flight.kind, "restore")
	eq(#ctx.events("query"), 1)
	ctx.release(chinese)
	wait(idle)
	eq(ime.pre_im, chinese)
	eq(ctx.current(), defaults)
	eq(#ctx.events("query"), 2)
end)

test("rapid events keep only the latest pending intent", function()
	local ctx = context({ block_query = true })
	event("InsertLeave")
	wait(function()
		return #ctx.events("query") == 1
	end)
	for _ = 1, 50 do
		event("InsertLeave")
		event("InsertEnter")
	end
	wait(function()
		return #ctx.events("query") == 1
	end)
	ctx.release()
	wait(idle)
	eq(ctx.current(), chinese)
	eq(#ctx.events("query"), 1)
	eq(#ctx.events("set"), 0)
end)

test("events coalesce before starting an external process", function()
	local ctx = context()
	for _ = 1, 50 do
		event("InsertLeave")
		event("InsertEnter")
	end
	wait(idle)
	eq(ctx.current(), chinese)
	eq(#ctx.events("query"), 0)
	eq(#ctx.events("set"), 0)
end)

test("rapid events ending in normal mode capture the latest session", function()
	local ctx = context({ block_query = true })
	for _ = 1, 20 do
		event("InsertLeave")
		event("InsertEnter")
	end
	event("InsertLeave")
	ctx.release()
	wait(idle)
	eq(ctx.current(), defaults)
	eq(ime.pre_im, chinese)
	assert(#ctx.events("query") <= 2, "pending queries accumulated")
end)

for name, config in pairs({
	["nonzero query"] = { query_code = 1, query_stderr = "query failed" },
	["empty query"] = { query_output = "" },
	["multiline query"] = { query_output = "warning\nime.invalid\n" },
}) do
	test(name .. " preserves memory and skips switching", function()
		local ctx = context()
		establish_memory(ctx)
		ctx.config(config)
		event("InsertLeave")
		wait(idle)
		eq(ime.pre_im, chinese)
		eq(ctx.current(), chinese)
		eq(#ctx.events("set"), 2)
		eq(#notices, 1)
		event("InsertLeave")
		wait(idle)
		eq(#notices, 1, "repeated errors should not flood notifications")
	end)
end

test("stderr cannot become part of an input method ID", function()
	local ctx = context({ query_stderr = "diagnostic warning\n" })
	establish_memory(ctx)
end)

test("timeout releases the queue and allows the next event", function()
	local ctx = context()
	establish_memory(ctx)
	ctx.opts.timeout_ms = 100
	ime.setup(ctx.opts)
	ctx.config({ block_query = true })
	local start = uv.hrtime()
	event("InsertLeave")
	wait(idle)
	assert((uv.hrtime() - start) / 1e6 < 1000, "timeout did not release the operation")
	eq(ctx.current(), chinese)
	eq(ime.pre_im, defaults)
	eq(#notices, 1)
	ctx.config({})
	event("InsertLeave")
	wait(idle)
	eq(ctx.current(), defaults)
end)

test("failed default setter keeps a recovery target", function()
	local ctx = context({ set_code = 1, write_on_failure = true })
	event("InsertLeave")
	wait(idle)
	eq(ctx.current(), defaults)
	eq(ime.pre_im, chinese)
	assert(ime._controller.restore_needed)
	ctx.config({})
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), chinese)
	eq(ime._controller.restore_needed, false)
end)

test("failed restoration does not capture plugin default as user memory", function()
	local ctx = context()
	event("InsertLeave")
	wait(idle)
	ctx.config({ set_code = 1 })
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), defaults)
	event("InsertLeave")
	wait(idle)
	eq(ime.pre_im, chinese)
	eq(ctx.current(), defaults)
	ctx.config({})
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), chinese)
end)

test("repeated setup registers one callback per mode event", function()
	local ctx = context()
	ime.setup(ctx.opts)
	event("InsertLeave")
	wait(idle)
	eq(#ctx.events("query"), 1)
	eq(#vim.api.nvim_get_autocmds({ group = "Autoime", event = "InsertLeave" }), 1)
	eq(#vim.api.nvim_get_autocmds({ group = "Autoime", event = "InsertEnter" }), 1)
end)

test("reinitialization invalidates an in-flight capture", function()
	local ctx = context({ block_query = true })
	event("InsertLeave")
	wait(function()
		return #ctx.events("query") == 1
	end)
	local old = ime._controller.in_flight.handle
	ime.setup(ctx.opts)
	ctx.release()
	wait(function()
		return old.done
	end)
	eq(ime.pre_im, defaults)
	eq(#ctx.events("set"), 0)
	ctx.config({})
	event("InsertLeave")
	wait(idle)
	eq(ctx.current(), defaults)
end)

test("disable and enable invalidate old work and preserve first entry", function()
	local ctx = context({ block_query = true })
	event("InsertLeave")
	wait(function()
		return #ctx.events("query") == 1
	end)
	local old = ime._controller.in_flight.handle
	ime.disable_autoime()
	ctx.release()
	wait(function()
		return old.done
	end)
	eq(ime.config.autoime_enabled, false)
	eq(#ctx.events("set"), 0)
	ime.enable_autoime()
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), chinese)
	ctx.config({})
	event("InsertLeave")
	wait(idle)
	eq(ctx.current(), defaults)
	ime.toggle_autoime()
	eq(ime.config.autoime_enabled, false)
	ime.toggle_autoime()
	eq(ime.config.autoime_enabled, true)
end)

test("missing executable disables automation without spawning", function()
	local ctx = context({}, chinese, { im_select_path = "/autoime/missing-command" })
	eq(ime.config.autoime_enabled, false)
	event("InsertLeave")
	eq(ctx.current(), chinese)
	eq(#notices, 1)
end)

test("executable disappearing after setup releases a failed query", function()
	local ctx = context()
	local path = ctx.dir .. "/im-select"
	local fixture = read(root .. "/tests/fixtures/im-select.py")
	write(path, fixture)
	assert(uv.fs_chmod(path, 493))
	ctx.opts.im_select_path = path
	ime.setup(ctx.opts)
	assert(os.remove(path))
	event("InsertLeave")
	wait(idle)
	eq(ctx.current(), chinese)
	eq(ime.pre_im, defaults)
	eq(#notices, 1)
	write(path, fixture)
	assert(uv.fs_chmod(path, 493))
	event("InsertLeave")
	wait(idle)
	eq(ctx.current(), defaults)
end)

test("failed setter spawn does not create an unnecessary restore", function()
	local ctx = context({ block_query = true })
	local path = ctx.dir .. "/im-select"
	write(path, read(root .. "/tests/fixtures/im-select.py"))
	assert(uv.fs_chmod(path, 493))
	ctx.opts.im_select_path = path
	ime.setup(ctx.opts)
	event("InsertLeave")
	wait(function()
		return #ctx.events("query") == 1
	end)
	assert(os.remove(path))
	ctx.release()
	wait(idle)
	eq(ime.pre_im, chinese)
	eq(ime._controller.restore_needed, false)
	eq(#notices, 1)
	event("InsertEnter")
	wait(idle)
	eq(ctx.current(), chinese)
	eq(#notices, 1)
end)

test("setup starts from fresh defaults and accepts nil options", function()
	context({}, chinese, { _notice = true, timeout_ms = 123 })
	ime.setup()
	eq(ime.config._notice, false)
	eq(ime.config.timeout_ms, 1000)
	ime.disable_autoime()
end)

test("executable paths containing spaces are preserved", function()
	local ctx = context()
	local path = ctx.dir .. "/im select"
	write(path, read(root .. "/tests/fixtures/im-select.py"))
	assert(uv.fs_chmod(path, 493))
	ctx.opts.im_select_path = path
	ime.setup(ctx.opts)
	establish_memory(ctx)
end)

test("explicit synchronous mode completes work before returning", function()
	local ctx = context({ query_delay_ms = 30 }, chinese, { async_if_able = false })
	event("InsertLeave")
	eq(ctx.current(), defaults)
	assert(idle())
	eq(ime.pre_im, chinese)
	event("InsertEnter")
	eq(ctx.current(), chinese)
	assert(idle())
end)

test("VimLeavePre closes the controller without a new setter", function()
	local ctx = context()
	event("VimLeavePre")
	eq(ime.config.autoime_enabled, false)
	event("InsertLeave")
	eq(#ctx.events("query"), 0)
end)

local failures, total = 0, 0
for _, item in ipairs(tests) do
	if not vim.env.AUTOIME_TEST_CASE or item.name == vim.env.AUTOIME_TEST_CASE then
		total = total + 1
		local ok, err = xpcall(item.fn, debug.traceback)
		if ok then
			print("PASS " .. item.name)
		else
			failures = failures + 1
			print("FAIL " .. item.name .. "\n" .. err)
		end
	end
end
ime.disable_samrtim()
vim.wait(100, function()
	return true
end)
for _, dir in ipairs(directories) do
	vim.fn.delete(dir, "rf")
end
print(
	string.format("%d/%d tests passed (%s backend)", total - failures, total, vim.env.AUTOIME_TEST_BACKEND or "native")
)
if failures > 0 then
	vim.cmd("cquit 1")
end
