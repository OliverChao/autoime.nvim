local M = {}

M.config = require("smartim.config")

function M.enable_smartim()
	M.config.smartim_enabled = true
end

function M.disable_samrtim()
	M.config.smartim_enabled = false
end
function M.toggle_smartim()
	M.config.smartim_enabled = not M.config.smartim_enabled
end

local split_command = function(command)
	local cmd = {}
	for word in command:gmatch("%S+") do
		table.insert(cmd, word)
	end
	return cmd
end

local function plenary_change(_cmd)
	local cmd = split_command(_cmd)
	M.job
		:new({
			command = cmd[1],
			args = vim.list_slice(cmd, 2, #cmd),
		})
		:start()
end

local function system_change(_cmd)
	vim.fn.system(_cmd)
end

local function change_ime(ime)
	local cmd = M.config.im_select_path .. " " .. ime
	M.change_ime(cmd)
end

function M.make_ime_default()
	if not M.config.smartim_enabled then
		return
	end

	M.require_current()
	if M.pre_im == M.default_im then
		return
	end

	if M.config._notice then
		vim.notify("change to default ime " .. M.default_im)
	end
	change_ime(M.default_im)
end

function M.make_ime_previous()
	if not M.config.smartim_enabled or M.pre_im == M.default_im then
		return
	end

	if M.config._notice then
		vim.notify("change to previous ime " .. M.pre_im)
	end

	change_ime(M.pre_im)
end

local function create_autocmd()
	vim.api.nvim_create_autocmd("InsertLeave", {
		callback = function()
			M.make_ime_default()
		end,
	})
	vim.api.nvim_create_autocmd("InsertEnter", {
		callback = function()
			M.make_ime_previous()
		end,
	})
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("keep", opts, M.config)
	if vim.fn.executable(M.config.im_select_path) ~= 1 then
		vim.notify("im-select path is not executable\nsmartim.nvim diasbled", vim.log.levels.WARN)
		M.config.smartim_enabled = false
	end

	local status, _ = pcall(require, "plenary")
	if M.config.async_if_able and status then
		M.job = require("plenary.job")
		M.change_ime = plenary_change
		M.require_current = function()
			M.job
				:new({
					command = M.config.im_select_path,
					-- args = vim.list_slice(cmd, 2, #cmd),
					on_exit = function(j, exit_code)
						if exit_code ~= 0 then
							vim.warn("im-select exits with some errors")
							return
						end
						M.pre_im = vim.trim(j:result()[1] or M.pre_im)
					end,
				})
				:sync()
		end
	else
		M.change_ime = system_change
		M.require_current = function()
			M.pre_im = vim.trim(vim.fn.system(M.config.im_select_path) or M.pre_im)
		end
	end

	M.default_im = M.config.default_im
	M.pre_im = M.default_im
	create_autocmd()
end
return M
