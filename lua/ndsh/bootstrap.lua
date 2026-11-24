--- Managed runtime bootstrap: when no dsh executable is available anywhere,
--- download a pinned Node.js into stdpath("data")/ndsh/bootstrap and use its
--- npm to install a pinned @deepseek-ai/dsh beside it. Pure vim.system +
--- curl/tar/sha256sum — no external Neovim deps (docs/dependencies.md rules).
local M = {}

local NODE_DIST = "https://nodejs.org/dist"

local installing = false

---@return string
local function root()
  return vim.fn.stdpath("data") .. "/ndsh/bootstrap"
end

---@return string|nil plat "linux"|"darwin", string|nil arch "x64"|"arm64", string|nil err
local function detect_platform()
  local sys = vim.uv.os_uname()
  local plat = ({ linux = "linux", darwin = "darwin" })[sys.sysname:lower()]
  local arch = ({ x86_64 = "x64", arm64 = "arm64", aarch64 = "arm64" })[sys.machine:lower()]
  if not plat or not arch then
    return nil, nil, ("unsupported platform %s/%s"):format(sys.sysname, sys.machine)
  end
  return plat, arch
end

---@param cfg table
---@return string|nil dir the managed Node.js installation directory
local function node_dir(cfg)
  local plat, arch = detect_platform()
  if not plat then
    return nil
  end
  return ("%s/node-v%s-%s-%s"):format(root(), cfg.dsh.node_version, plat, arch)
end

---@param cfg table
---@return string|nil path to the managed node binary
local function node_bin(cfg)
  local dir = node_dir(cfg)
  local bin = dir and (dir .. "/bin/node")
  return (bin and vim.uv.fs_stat(bin)) and bin or nil
end

---@return string|nil path to the managed dsh entrypoint
local function dsh_entry()
  local entry = root() .. "/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js"
  return vim.uv.fs_stat(entry) and entry or nil
end

---Managed runtime argv, or nil when the bootstrap has not been installed.
---The npm .bin/dsh shim is avoided on purpose: its env-shebang needs node on
---PATH, while invoking lib/bin.js with the managed node works standalone.
---@param cfg table
---@return string[]|nil
function M.runtime_cmd(cfg)
  local node, entry = node_bin(cfg), dsh_entry()
  if node and entry then
    return { node, entry, "--profile", cfg.dsh.profile }
  end
  return nil
end

---@return string[]|nil argv computing a file's sha256 on stdout
local function sha256_cmd()
  if vim.fn.executable("sha256sum") == 1 then
    return { "sha256sum" }
  end
  if vim.fn.executable("shasum") == 1 then
    return { "shasum", "-a", "256" }
  end
  return nil
end

---Run one async step; on failure call fail(prefix: stderr), else next(res).
---The vim.system callback is a fast event, so next_fn is scheduled: step
---bodies may then use vim.fn/vim.api freely.
local function step(argv, opts, fail, next_fn, prefix)
  vim.system(argv, opts, function(res)
    if res.code ~= 0 then
      fail(("%s: %s"):format(prefix, vim.trim(res.stderr or "")))
    else
      vim.schedule(function()
        next_fn(res)
      end)
    end
  end)
end

---Install Node.js + @deepseek-ai/dsh under stdpath("data")/ndsh/bootstrap.
---Already-installed pieces are skipped. cb receives (ok, err).
---@param cfg table
---@param cb fun(ok: boolean, err: string|nil)
function M.install(cfg, cb)
  if installing then
    return cb(false, "bootstrap already in progress")
  end
  local plat, arch, perr = detect_platform()
  if not plat then
    return cb(false, perr)
  end
  if vim.fn.executable("curl") == 0 or vim.fn.executable("tar") == 0 then
    return cb(false, "curl and tar are required to bootstrap the runtime")
  end
  local hash_cmd = sha256_cmd()
  if not hash_cmd then
    return cb(false, "sha256sum (or shasum) is required to verify the download")
  end

  installing = true
  local done = function(ok, err)
    installing = false
    vim.schedule(function()
      cb(ok, err)
    end)
  end
  local fail = function(err)
    done(false, err)
  end

  local dest = root()
  local runtime_dir = dest .. "/runtime"
  vim.fn.mkdir(runtime_dir, "p")

  local install_dsh ---@type function
  local finish = function()
    if M.runtime_cmd(cfg) then
      done(true)
    else
      fail("install finished but the dsh entrypoint is missing")
    end
  end

  ---npm install the pinned dsh with the managed node (PATH carries node for
  ---npm's own node lookups and any lifecycle scripts).
  install_dsh = function()
    if dsh_entry() then
      return finish()
    end
    local node = node_bin(cfg)
    local dir = node_dir(cfg)
    if not node or not dir then
      return fail("node is missing after the download step")
    end
    local pkg = vim.json.encode({
      name = "ndsh-managed-runtime",
      private = true,
      dependencies = { ["@deepseek-ai/dsh"] = cfg.dsh.version },
    })
    local fd, werr = io.open(runtime_dir .. "/package.json", "w")
    if not fd then
      return fail("cannot write package.json: " .. tostring(werr))
    end
    fd:write(pkg)
    fd:close()
    vim.notify(("ndsh: installing @deepseek-ai/dsh@%s (first run may take a minute)"):format(cfg.dsh.version))
    step({ node, dir .. "/lib/node_modules/npm/bin/npm-cli.js", "install", "--no-audit", "--no-fund", "--loglevel=error" }, {
      cwd = runtime_dir,
      env = { PATH = dir .. "/bin:" .. (vim.env.PATH or "") },
    }, fail, function()
      vim.notify("ndsh: dsh runtime installed")
      finish()
    end, "npm install failed")
  end

  ---Download + verify + extract node, unless a managed node already exists.
  local function ensure_node()
    if node_bin(cfg) then
      return install_dsh()
    end
    local version = cfg.dsh.node_version
    local name = ("node-v%s-%s-%s"):format(version, plat, arch)
    local tarball = dest .. "/" .. name .. ".tar.gz"
    vim.notify(("ndsh: downloading Node.js v%s (%s-%s)"):format(version, plat, arch))
    step({ "curl", "-fSL", "--retry", "3", "-o", tarball, ("%s/v%s/%s.tar.gz"):format(NODE_DIST, version, name) }, {}, fail, function()
      step({ "curl", "-fSLs", "--retry", "3", ("%s/v%s/SHASUMS256.txt"):format(NODE_DIST, version) }, {}, fail, function(res)
        local pattern = "^(%x+)%s+" .. name:gsub("%W", "%%%0") .. "%.tar%.gz$"
        local expected
        for line in (res.stdout or ""):gmatch("[^\r\n]+") do
          expected = line:match(pattern)
          if expected then
            break
          end
        end
        if not expected then
          return fail("no checksum for " .. name .. " in SHASUMS256.txt")
        end
        local hash_argv = vim.list_extend(vim.deepcopy(hash_cmd), { tarball })
        step(hash_argv, {}, fail, function(hash_res)
          local actual = vim.trim(hash_res.stdout or ""):match("^(%x+)")
          if actual ~= expected then
            vim.fn.delete(tarball)
            return fail(("checksum mismatch for %s (expected %s, got %s)"):format(name, expected, tostring(actual)))
          end
          step({ "tar", "-xzf", tarball, "-C", dest }, {}, fail, function()
            vim.fn.delete(tarball)
            install_dsh()
          end, "node extract failed")
        end, "checksum failed")
      end, "checksum download failed")
    end, "node download failed")
  end

  ensure_node()
end

---Offer the managed install when no runtime is resolvable. Confirms first —
---the download is tens of megabytes — then installs and reports via notify.
---@param cfg table
---@param cb fun(ok: boolean, err: string|nil)
function M.ensure(cfg, cb)
  if M.runtime_cmd(cfg) then
    return cb(true)
  end
  vim.ui.select({ "Install", "Cancel" }, {
    prompt = ("ndsh: no dsh runtime found. Download Node.js v%s + @deepseek-ai/dsh@%s into %s?"):format(
      cfg.dsh.node_version,
      cfg.dsh.version,
      root()
    ),
  }, function(choice)
    if choice ~= "Install" then
      return cb(false, "declined")
    end
    M.install(cfg, cb)
  end)
end

return M
