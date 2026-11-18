local M = {}
local uv = vim.uv or vim.loop

-- Every backend delivers one result, after releasing its timer and handles.
function M.run(argv, opts, callback)
	local handle = { done = false }
	local timer, cancelled, timed_out
	local asynchronous = opts.async
	local timeout = opts.timeout_ms

	local function finish(result)
		if handle.done then
			return
		end
		handle.done = true
		if timer then
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
			timer = nil
		end
		result.stdout = result.stdout or ""
		result.stderr = result.stderr or ""
		result.timed_out = timed_out or result.code == 124 or false
		result.cancelled = cancelled or false
		handle.result = result
		local function deliver()
			local ok, err = xpcall(function()
				callback(result)
			end, debug.traceback)
			if not ok then
				pcall(vim.notify, "autoime.nvim callback failed: " .. err, vim.log.levels.ERROR)
			end
		end
		if asynchronous then
			vim.schedule(deliver)
		else
			deliver()
		end
	end

	function handle:cancel()
		if self.done then
			return
		end
		cancelled = true
		local ok
		if self.process then
			ok = pcall(self.process.kill, self.process, 15)
		elseif self.job_id then
			ok = pcall(vim.fn.jobstop, self.job_id)
		end
		if not ok then
			finish({ code = -1, stderr = "command cancelled" })
		end
	end

	if vim.system then
		local ok, result = pcall(function()
			handle.process = vim.system(argv, { text = true, timeout = timeout }, asynchronous and finish or nil)
			if not asynchronous then
				return handle.process:wait(timeout)
			end
		end)
		if not ok then
			finish({ code = -1, spawn_error = not handle.process, stderr = tostring(result) })
		elseif not asynchronous then
			finish(result)
		end
		return handle
	end

	local stdout, stderr = "", ""
	local ok, job = pcall(vim.fn.jobstart, argv, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			stdout = stdout .. table.concat(data, "\n")
		end,
		on_stderr = function(_, data)
			stderr = stderr .. table.concat(data, "\n")
		end,
		on_exit = function(_, code)
			finish({ code = timed_out and 124 or code, stdout = stdout, stderr = stderr })
		end,
	})
	if not ok or job <= 0 then
		finish({ code = -1, spawn_error = true, stderr = ok and "unable to start command" or tostring(job) })
		return handle
	end
	handle.job_id = job
	timer = uv.new_timer()
	timer:start(timeout, 0, function()
		if handle.done then
			return
		end
		timed_out = true
		vim.schedule(function()
			if not handle.done then
				vim.fn.jobstop(job)
			end
		end)
	end)
	if not asynchronous then
		local completed = vim.wait(timeout + 100, function()
			return handle.done
		end, 5)
		if not completed then
			timed_out = true
			pcall(vim.fn.jobstop, job)
			-- jobstop may require another event-loop iteration to deliver on_exit.
			vim.wait(100, function()
				return handle.done
			end, 5)
			finish({ code = 124, stdout = stdout, stderr = stderr })
		end
	end
	return handle
end

return M
