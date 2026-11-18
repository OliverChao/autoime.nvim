-- Read-only benchmark: intercept all setters before loading the controller.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local uv = vim.uv or vim.loop
local runner = require("autoime.runner")
local run = runner.run
local query_times, results, suppressed = {}, {}, 0
runner.run = function(argv, opts, callback)
	if #argv > 1 then
		suppressed = suppressed + 1
		local handle = { done = true, cancel = function() end }
		local result = { code = 0, stdout = "", stderr = "", timed_out = false, cancelled = false }
		if opts.async then
			vim.schedule(function()
				callback(result)
			end)
		else
			callback(result)
		end
		return handle
	end
	local start = uv.hrtime()
	return run(argv, opts, function(result)
		query_times[#query_times + 1] = (uv.hrtime() - start) / 1e6
		results[#results + 1] = result
		callback(result)
	end)
end
local ime = require("autoime")
ime.setup({
	im_select_path = vim.env.AUTOIME_BENCH_PATH or "im-select",
	async_if_able = vim.env.AUTOIME_BENCH_ASYNC ~= "0",
	timeout_ms = 2000,
	notify_on_error = false,
})
assert(ime.config.autoime_enabled, "im-select is not executable")
local samples = {}
local count = tonumber(vim.env.AUTOIME_BENCH_COUNT) or 30
for _ = 1, count do
	local start = uv.hrtime()
	vim.api.nvim_exec_autocmds("InsertLeave", {})
	samples[#samples + 1] = (uv.hrtime() - start) / 1e6
	assert(
		vim.wait(3000, function()
			local c = ime._controller
			return not c.in_flight and not c.pending
		end, 2),
		"benchmark query did not finish"
	)
end
local function stats(label, values)
	table.sort(values)
	print(
		string.format(
			"%s n=%d min=%.2fms median=%.2fms p95=%.2fms max=%.2fms",
			label,
			#values,
			values[1],
			values[math.ceil(#values / 2)],
			values[math.ceil(#values * 0.95)],
			values[#values]
		)
	)
end
stats("InsertLeave callback", samples)
stats("query completion", query_times)
for _, result in ipairs(results) do
	assert(result.code == 0 and vim.trim(result.stdout) ~= "", "query failed: " .. result.stderr)
	assert(result.stderr == "", "query emitted diagnostics; this may distort the benchmark: " .. result.stderr)
end
print("async=" .. tostring(ime.config.async_if_able) .. "; system setters suppressed=" .. suppressed)
ime.disable_autoime()
