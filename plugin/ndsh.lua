if vim.g.loaded_ndsh then
  return
end
vim.g.loaded_ndsh = 1

vim.api.nvim_create_user_command("NDSHToggle", function()
  require("ndsh").toggle()
end, { desc = "Toggle the ndsh panel" })

vim.api.nvim_create_user_command("NDSHOpen", function(args)
  require("ndsh").open({ full = args.bang })
end, { desc = "Open the ndsh panel (!: full tab)", bang = true })

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

vim.api.nvim_create_user_command("NDSHLog", function()
  require("ndsh").show_logs()
end, { desc = "Show the ndsh runtime log" })
