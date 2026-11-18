-- Run inside the user's normal Neovim configuration; system setters are mapped
-- to the fixture after the first InsertEnter loads the local plugin.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local directory, ime, runner, original
local previous_directory = vim.env.AUTOIME_TEST_DIR
local function main()
	local plugin = require("lazy.core.config").plugins["autoime.nvim"]
	assert(
		plugin and vim.fn.fnamemodify(plugin.dir, ":p"):gsub("/$", "") == root,
		"lazy.nvim did not resolve this local checkout"
	)
	local uv = vim.uv or vim.loop
	local start = uv.hrtime()
	vim.api.nvim_exec_autocmds("InsertEnter", {})
	local load_ms = (uv.hrtime() - start) / 1e6
	ime = require("autoime")
	local source = debug.getinfo(ime.setup, "S").source:sub(2)
	assert(source == root .. "/lua/autoime/init.lua", "loaded unexpected implementation: " .. source)
	assert(ime.config.async_if_able and ime.config.autoime_enabled, "configured asynchronous mode is not enabled")
	directory = vim.fn.tempname()
	vim.fn.mkdir(directory, "p")
	vim.env.AUTOIME_TEST_DIR = directory
	local function write(name, value)
		local file = assert(io.open(directory .. "/" .. name, "w"))
		file:write(value)
		file:close()
	end
	local function current()
		local file = assert(io.open(directory .. "/ime", "r"))
		local value = file:read("*a")
		file:close()
		return vim.trim(value)
	end
	write("config.json", vim.json.encode({ query_delay_ms = 150 }))
	write("ime", "ime.chinese\n")
	write("events.jsonl", "")
	runner = require("autoime.runner")
	original = runner.run
	runner.run = function(argv, opts, callback)
		local mapped = vim.deepcopy(argv)
		mapped[1] = root .. "/tests/fixtures/im-select.py"
		return original(mapped, opts, callback)
	end
	local function wait()
		assert(
			vim.wait(3000, function()
				local c = ime._controller
				return not c.in_flight and not c.pending
			end, 2),
			"configured plugin failed to finish"
		)
	end
	start = uv.hrtime()
	vim.api.nvim_exec_autocmds("InsertLeave", {})
	local callback_ms = (uv.hrtime() - start) / 1e6
	wait()
	assert(current() == ime.default_im and ime.pre_im == "ime.chinese")
	vim.api.nvim_exec_autocmds("InsertEnter", {})
	wait()
	assert(current() == "ime.chinese")
	write("ime", "ime.japanese\n")
	vim.api.nvim_exec_autocmds("InsertLeave", {})
	vim.api.nvim_exec_autocmds("InsertEnter", {})
	wait()
	assert(current() == "ime.japanese", "quick reentry overwrote manual selection")
	assert(#vim.api.nvim_get_autocmds({ group = "Autoime", event = "InsertLeave" }) == 1)
	assert(#vim.api.nvim_get_autocmds({ group = "Autoime", event = "InsertEnter" }) == 1)
	print("PASS user configuration loads " .. source)
	print("PASS configured lazy load, switch/restore, quick reentry and single event registration")
	print(string.format("Full configuration: first InsertEnter %.2fms; InsertLeave %.2fms", load_ms, callback_ms))
end
local ok, err = xpcall(main, debug.traceback)
if ime then
	ime.disable_autoime()
end
if runner and original then
	runner.run = original
end
vim.env.AUTOIME_TEST_DIR = previous_directory
if directory then
	vim.fn.delete(directory, "rf")
end
if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
end
