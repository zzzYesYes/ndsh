if vim.g.loaded_ndsh then
  return
end
vim.g.loaded_ndsh = 1

vim.api.nvim_create_user_command("NDSHToggle", function()
  require("ndsh").toggle()
end, { desc = "Toggle the ndsh panel" })

vim.api.nvim_create_user_command("NDSHOpen", function()
  require("ndsh").open()
end, { desc = "Open the ndsh panel" })

vim.api.nvim_create_user_command("NDSHClose", function()
  require("ndsh").close()
end, { desc = "Close the ndsh panel" })

vim.api.nvim_create_user_command("NDSHDemo", function()
  require("ndsh").demo()
end, { desc = "Play a scripted ndsh session" })

vim.api.nvim_create_user_command("NDSHStop", function()
  require("ndsh").stop_session()
end, { desc = "Stop the ndsh runtime" })

vim.api.nvim_create_user_command("NDSHRestart", function()
  require("ndsh").restart_session()
end, { desc = "Restart the ndsh runtime" })

vim.api.nvim_create_user_command("NDSHInstallRuntime", function()
  require("ndsh").install_runtime()
end, { desc = "Install the managed dsh runtime (Node.js + @deepseek-ai/dsh)" })

vim.api.nvim_create_user_command("NDSHLog", function()
  require("ndsh").show_logs()
end, { desc = "Show the ndsh runtime log" })

vim.api.nvim_create_user_command("NDSHConnect", function()
  require("ndsh").connect()
end, { desc = "Connect a model provider" })

vim.api.nvim_create_user_command("NDSHModel", function()
  require("ndsh").select_model()
end, { desc = "Select the active model" })

vim.api.nvim_create_user_command("NDSHNew", function(args)
  require("ndsh").new_session(args.args ~= "" and args.args or nil)
end, { desc = "New ndsh session (optional name)", nargs = "?" })

vim.api.nvim_create_user_command("NDSHResume", function()
  require("ndsh").resume_last()
end, { desc = "Resume the most recently active ndsh session" })

vim.api.nvim_create_user_command("NDSHSessions", function()
  require("ndsh").sessions()
end, { desc = "Navigate ndsh sessions" })

vim.api.nvim_create_user_command("NDSHMessages", function()
  require("ndsh").messages()
end, { desc = "Scan transcript messages and jump to one" })

vim.api.nvim_create_user_command("NDSHRename", function(args)
  require("ndsh").rename(args.args ~= "" and args.args or nil)
end, { desc = "Rename the current session", nargs = "?" })

vim.api.nvim_create_user_command("NDSHDelete", function()
  require("ndsh").delete_session()
end, { desc = "Delete the current session" })
