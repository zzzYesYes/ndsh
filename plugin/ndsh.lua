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
