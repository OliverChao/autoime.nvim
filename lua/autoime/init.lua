local defaults = require("autoime.config")
local Controller = require("autoime.controller")
local M = { config = vim.deepcopy(defaults) }

local function notify(message, level)
	pcall(vim.notify, "autoime.nvim: " .. message, level)
end

local function close()
	if M._controller then
		M._controller:close()
		M._controller = nil
	end
end

local function start()
	close()
	M.default_im = M.config.default_im
	M.pre_im = M.default_im
	if vim.fn.executable(M.config.im_select_path) ~= 1 then
		M.config.autoime_enabled = false
		if M.config.notify_on_error then
			notify("im-select path is not executable; automation disabled", vim.log.levels.WARN)
		end
		return
	end
	M._controller = Controller.new(M.config, {
		previous = function(input)
			M.pre_im = input
		end,
		error = function(message)
			if M.config.notify_on_error then
				notify(message, vim.log.levels.WARN)
			end
		end,
		changed = function(input)
			if M.config._notice then
				notify("changed input method to " .. input, vim.log.levels.INFO)
			end
		end,
	})
end

function M.enable_autoime()
	if M.config.autoime_enabled and M._controller then
		return
	end
	M.config.autoime_enabled = true
	start()
end

function M.disable_autoime()
	M.config.autoime_enabled = false
	close()
end

-- Keep the original misspelled public function as a compatibility alias.
M.disable_samrtim = M.disable_autoime

function M.toggle_autoime()
	if M.config.autoime_enabled then
		M.disable_autoime()
	else
		M.enable_autoime()
	end
end

function M.make_ime_default()
	if M.config.autoime_enabled and M._controller then
		M._controller:request("normal")
	end
end

function M.make_ime_previous()
	if M.config.autoime_enabled and M._controller then
		M._controller:request("insert")
	end
end

function M.setup(opts)
	assert(opts == nil or type(opts) == "table", "autoime.nvim: opts must be a table")
	local config = vim.tbl_deep_extend("force", {}, defaults, opts or {})
	for _, key in ipairs({ "im_select_path", "default_im" }) do
		assert(
			type(config[key]) == "string" and config[key] ~= "" and not config[key]:find("%z"),
			"autoime.nvim: invalid " .. key
		)
	end
	for _, key in ipairs({ "autoime_enabled", "async_if_able", "notify_on_error", "_notice" }) do
		assert(type(config[key]) == "boolean", "autoime.nvim: " .. key .. " must be a boolean")
	end
	assert(
		type(config.timeout_ms) == "number"
			and config.timeout_ms > 0
			and config.timeout_ms < math.huge
			and config.timeout_ms == math.floor(config.timeout_ms),
		"autoime.nvim: timeout_ms must be a positive integer"
	)
	close()
	M.config = config
	M.default_im = config.default_im
	M.pre_im = M.default_im
	local group = vim.api.nvim_create_augroup("Autoime", { clear = true })
	vim.api.nvim_create_autocmd("InsertLeave", { group = group, callback = M.make_ime_default })
	vim.api.nvim_create_autocmd("InsertEnter", { group = group, callback = M.make_ime_previous })
	vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.disable_autoime })
	if config.autoime_enabled then
		start()
	end
end

return M
