local runner = require("autoime.runner")
local Controller = {}
Controller.__index = Controller

function Controller.new(config, callbacks)
	return setmetatable({
		config = config,
		callbacks = callbacks,
		previous_im = config.default_im,
		mode = "insert",
		revision = 0,
		restore_needed = false,
		closed = false,
		error_reported = false,
	}, Controller)
end

function Controller:_error(message)
	if not self.error_reported then
		self.error_reported = true
		pcall(self.callbacks.error, message)
	end
end

function Controller:_success()
	self.error_reported = false
end

function Controller:_complete(token, result)
	-- An old instance can finish cleanup, but cannot mutate a new instance.
	if self.closed or self.in_flight ~= token then
		return
	end
	self.in_flight = nil
	local ok = result.code == 0 and not result.cancelled and not result.timed_out and not result.spawn_error
	local current = token.revision == self.revision
	if token.kind == "query" then
		local input = vim.trim(result.stdout)
		if ok and (input == "" or input:find("%c")) then
			ok = false
			result.stderr = "invalid or empty input method returned"
		end
		if ok and current and self.mode == "normal" then
			-- A failed/pending restore may leave our own default active. Preserve
			-- the user's remembered input instead of capturing it as a selection.
			if not (self.restore_needed and input == self.config.default_im) then
				self.previous_im = input
				pcall(self.callbacks.previous, input)
				if input ~= self.config.default_im then
					self.pending = { kind = "default", revision = self.revision, restore_target = input }
				else
					self.restore_needed = false
					self.restore_target = nil
				end
			end
			if input == self.config.default_im then
				self:_success()
			end
		elseif ok and current and not self.restore_needed then
			self:_success()
		end
	elseif token.kind == "default" then
		if result.spawn_error then
			-- No process started, so this attempt cannot have changed the IM.
			self.restore_needed = token.was_restore_needed
			self.restore_target = token.old_restore_target
		elseif ok and self.mode == "normal" then
			self:_success()
		end
	elseif token.kind == "restore" and ok then
		self.restore_needed = false
		self.restore_target = nil
		if self.mode == "insert" then
			self:_success()
		end
	end
	if not ok and not result.cancelled then
		local reason = result.timed_out and "command timed out" or vim.trim(result.stderr)
		if reason == "" then
			reason = "command exited with code " .. tostring(result.code)
		end
		self:_error(token.kind .. ": " .. reason)
	elseif ok and token.kind ~= "query" then
		pcall(self.callbacks.changed, token.target)
	end
	self:_queue()
end

function Controller:_run(kind, target, request)
	local token = { kind = kind, target = target, revision = request.revision }
	self.in_flight = token
	if kind == "default" then
		token.was_restore_needed = self.restore_needed
		token.old_restore_target = self.restore_target
		self.restore_needed = true
		self.restore_target = request.restore_target
	end
	local argv = { self.config.im_select_path }
	if target then
		argv[#argv + 1] = target
	end
	token.handle = runner.run(argv, {
		async = self.config.async_if_able,
		timeout_ms = self.config.timeout_ms,
	}, function(result)
		self:_complete(token, result)
	end)
end

function Controller:_pump()
	-- Synchronous backends can complete inside _run. The outer loop then
	-- processes follow-up work without recursive waits or replacing its token.
	if self.pumping then
		return
	end
	self.pumping = true
	while not self.closed and not self.in_flight and self.pending do
		local request = self.pending
		self.pending = nil
		if request.revision == self.revision then
			if request.kind == "query" then
				self:_run("query", nil, request)
			elseif request.kind == "restore" and self.restore_needed then
				self:_run("restore", self.restore_target, request)
			elseif request.kind == "default" and self.mode == "normal" then
				self:_run("default", self.config.default_im, request)
			end
		end
	end
	self.pumping = false
end

function Controller:_queue()
	if not self.config.async_if_able then
		self:_pump()
	elseif not self.scheduled then
		self.scheduled = true
		vim.schedule(function()
			self.scheduled = false
			if not self.closed then
				self:_pump()
			end
		end)
	end
end

function Controller:request(mode)
	if self.closed then
		return
	end
	self.mode = mode
	self.revision = self.revision + 1
	self.pending = { kind = mode == "normal" and "query" or "restore", revision = self.revision }
	-- Even process creation happens outside the mode callback. Events arriving
	-- before this scheduled turn replace the pending intent without spawning.
	self:_queue()
end

function Controller:close()
	if self.closed then
		return
	end
	self.closed = true
	self.pending = nil
	local token = self.in_flight
	self.in_flight = nil
	if token and token.handle then
		token.handle:cancel()
	end
end

return Controller
