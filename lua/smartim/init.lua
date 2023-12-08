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

local function change_ime(ime)
	local name = M.config.im_select_path .. " " .. ime
	vim.fn.system(name)
end

function M.make_ime_default()
	M.pre_im = vim.trim(vim.fn.system(M.config.im_select_path) or M.pre_im)
	if not M.config.smartim_enabled or M.pre_im == M.default_im then
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
	M.default_im = M.config.default_im
	M.pre_im = M.default_im
	create_autocmd()
end
return M
