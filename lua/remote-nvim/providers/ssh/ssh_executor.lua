local Executor = require("remote-nvim.providers.executor")
local utils = require("remote-nvim.utils")

---@class remote-nvim.providers.ssh.SSHExecutor: remote-nvim.providers.Executor
---@field super remote-nvim.providers.Executor
---@field ssh_conn_opts string Connection options for SSH command
---@field scp_connection_options string Connection options to SCP command
---@field remote_is_windows boolean Whether the remote host runs Windows (commands are then sent as PowerShell scripts)
---@field ssh_binary string Binary to use for SSH operations
---@field scp_binary string Binary to use for SCP operations
---@field private _ssh_prompts remote-nvim.config.PluginConfig.SSHConfig.SSHPrompt[] SSH prompts registered for processing for input
---@field private _job_prompt_responses table<string,string> Responses for prompts provided by user during the job
---@field private _prompt_tail string Recent output retained to match prompts split across callbacks
local SSHExecutor = Executor:subclass("SSHExecutor")

---Wrap a PowerShell script so that it runs identically under cmd, Windows PowerShell and PowerShell 7 login shells
---@param script string PowerShell script
---@return string command Command line which can be passed to the remote shell
local function wrap_powershell(script)
  script = ("$ProgressPreference='SilentlyContinue'; %s; if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }"):format(
    script
  )
  local encoded = vim.base64.encode(vim.iconv(script, "utf-8", "utf-16le"))
  return ("powershell -NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand %s"):format(
    encoded
  )
end

---Convert a Windows path to the form understood by the sftp/scp server (e.g. /C:/Users/me)
---@param path string
---@return string
local function to_scp_windows_path(path)
  path = path:gsub("\\", "/")
  if path:match("^%a:") then
    path = "/" .. path
  end
  return path
end

---Initialize SSH executor instance
---@param host string Host name
---@param conn_opts string Connection options
function SSHExecutor:init(host, conn_opts)
  SSHExecutor.super.init(self, host, conn_opts)

  self.ssh_conn_opts = self.conn_opts
  self.scp_conn_opts = self.conn_opts == "" and "-r" or self.conn_opts:gsub("%-p", "-P") .. " -r"

  local remote_neovim = require("remote-nvim")
  self.ssh_binary = remote_neovim.config.ssh_config.ssh_binary
  self.scp_binary = remote_neovim.config.ssh_config.scp_binary
  self._ssh_prompts = vim.deepcopy(remote_neovim.config.ssh_config.ssh_prompts)

  self.remote_is_windows = false
  self._job_prompt_responses = {}
  self._prompt_tail = ""
end

---Reset ssh executor
function SSHExecutor:reset()
  SSHExecutor.super.reset(self)

  self._job_prompt_responses = {}
  self._prompt_tail = ""
end

---Upload data from local path to remote path
---@param localSrcPath string Local path
---@param remoteDestPath string Remote path
---@param job_opts remote-nvim.provider.Executor.JobOpts
function SSHExecutor:upload(localSrcPath, remoteDestPath, job_opts)
  job_opts = job_opts or {}
  job_opts.compression = job_opts.compression or {}

  if job_opts.compression.enabled or false then
    local paths = vim.split(localSrcPath, " ")
    local parent_dir, subdirs = utils.find_common_parent(paths)
    assert(
      parent_dir ~= "",
      ("All directories to be uploaded from local should share a common ancestor. Passed paths: %s"):format(
        table.concat(paths, " ")
      )
    )

    local remote_extract_cmd = ("tar xvzf - -C %s && chown -R $(whoami) %s"):format(remoteDestPath, remoteDestPath)
    if self.remote_is_windows then
      -- Not wrapped in PowerShell so that the tar archive on stdin reaches tar.exe untouched
      remote_extract_cmd = ('tar xzf - -C "%s"'):format(to_scp_windows_path(remoteDestPath):gsub("^/(%a:)", "%1"))
    end
    local ssh_command = self:_build_run_command(remote_extract_cmd, job_opts, self.remote_is_windows)
    local tar_command = ("tar czf - --no-xattrs %s %s --numeric-owner --no-acls --no-same-owner --no-same-permissions -C %s %s"):format(
      utils.os_name() == "macOS" and "--disable-copyfile" or "",
      table.concat(job_opts.compression.additional_opts or {}, " "),
      parent_dir,
      table.concat(subdirs, " ")
    )
    local command = ("%s | %s"):format(tar_command, ssh_command)
    return self:run_executor_job(command, job_opts)
  else
    local remotePath = ("%s:%s"):format(
      self.host,
      self.remote_is_windows and to_scp_windows_path(remoteDestPath) or remoteDestPath
    )
    local scp_command = ("%s -q %s %s %s"):format(self.scp_binary, self.scp_conn_opts, localSrcPath, remotePath)

    return self:run_executor_job(scp_command, job_opts)
  end
end

---Download data from remote path to local path
---@param remoteSrcPath string Remote path
---@param localDescPath string Local path
---@param job_opts remote-nvim.provider.Executor.JobOpts
function SSHExecutor:download(remoteSrcPath, localDescPath, job_opts)
  job_opts = job_opts or {}
  local remotePath = ("%s:%s"):format(
    self.host,
    self.remote_is_windows and to_scp_windows_path(remoteSrcPath) or remoteSrcPath
  )
  local scp_command = ("%s -q %s %s %s"):format(self.scp_binary, self.scp_conn_opts, remotePath, localDescPath)

  return self:run_executor_job(scp_command, job_opts)
end

---@private
---Build the SSH command to be run on the remote host
---@param command string Command to be run on the remote host
---@param job_opts remote-nvim.provider.Executor.JobOpts
---@param raw boolean? Send the command as is, even for Windows remotes
---@return string generated_command The SSH command that should be run on local to run the passed command on remote
function SSHExecutor:_build_run_command(command, job_opts, raw)
  job_opts = job_opts or {}

  if self.remote_is_windows and not raw then
    command = wrap_powershell(command)
  end

  -- Append additional connection options (if any)
  local conn_opts = job_opts.additional_conn_opts == nil and self.ssh_conn_opts
    or (self.ssh_conn_opts .. " " .. job_opts.additional_conn_opts)

  -- Generate connection details (conn_opts + host)
  local host_conn_opts = conn_opts == "" and self.host or conn_opts .. " " .. self.host

  -- Shell escape the passed command
  return ("%s %s %s"):format(self.ssh_binary, host_conn_opts, vim.fn.shellescape(command))
end

---Run command on the remote host
---@param command string Command to be run on the remote host
---@param job_opts remote-nvim.provider.Executor.JobOpts
function SSHExecutor:run_command(command, job_opts)
  job_opts = job_opts or {}
  return self:run_executor_job(self:_build_run_command(command, job_opts), job_opts)
end

---@private
---Handle when the SSH job requires a job input
---@param prompt remote-nvim.config.PluginConfig.SSHConfig.SSHPrompt
function SSHExecutor:_process_prompt(prompt)
  local prompt_response

  -- If it is a "static" value prompt, use cached input values, unless values were passed in config
  -- If prompt's value would not change during the session ("static"), use cached values unless they are unset (denoted
  -- by "" string)
  if prompt.value_type == "static" and prompt.value ~= "" then
    prompt_response = prompt.value
  else
    local job_output = self:job_stdout()
    local label = prompt.input_prompt or ("%s "):format(job_output[#job_output])
    prompt_response = require("remote-nvim.providers.utils").get_input(label, prompt.type)

    -- Saving these prompt responses is handle in the job exit handler
    if prompt.value_type == "static" then
      self._job_prompt_responses[prompt.match] = prompt_response
    end
  end
  vim.api.nvim_chan_send(self._job_id, prompt_response .. "\n")
end

---@private
---Process job output
---@param output_chunks string[]
---@param cb function? Callback to call on job output
function SSHExecutor:process_stdout(output_chunks, cb)
  SSHExecutor.super.process_stdout(self, output_chunks, cb)

  local pending_search_str = self._prompt_tail .. table.concat(output_chunks, ""):gsub("\r", "\n")
  local max_prompt_length = 1
  for _, prompt in ipairs(self._ssh_prompts) do
    max_prompt_length = math.max(max_prompt_length, #prompt.match)
  end
  -- Only a suffix can form a new prompt with the next callback's output.
  self._prompt_tail = max_prompt_length > 1 and pending_search_str:sub(-(max_prompt_length - 1)) or ""
  for _, prompt in ipairs(self._ssh_prompts) do
    if pending_search_str:find(prompt.match, 1, true) then
      self._prompt_tail = ""
      self:_process_prompt(prompt)
      break
    end
  end
end

---@private
---Process job completion
---@param exit_code number Exit code of the job that was just running on the executor
function SSHExecutor:process_job_completion(exit_code)
  SSHExecutor.super.process_job_completion(self, exit_code)

  if self._job_exit_code == 0 then
    -- If the job has successfully concluded, we have the correct prompt values at hand for "static" prompts
    for idx, prompt in ipairs(self._ssh_prompts) do
      if prompt.value_type == "static" and self._job_prompt_responses[prompt.match] ~= nil then
        self._ssh_prompts[idx].value = self._job_prompt_responses[prompt.match]
      end
    end
  end
end

return SSHExecutor
