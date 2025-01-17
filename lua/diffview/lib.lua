local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local FileHistoryView = lazy.access("diffview.scene.views.file_history.file_history_view", "FileHistoryView") ---@type FileHistoryView|LazyModule
local Rev = lazy.access("diffview.git.rev", "Rev") ---@type Rev|LazyModule
local RevType = lazy.access("diffview.git.rev", "RevType") ---@type ERevType|LazyModule
local StandardView = lazy.access("diffview.scene.views.standard.standard_view", "StandardView") ---@type StandardView|LazyModule
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local config = lazy.require("diffview.config") ---@module "diffview.config"
local git = lazy.require("diffview.git.utils") ---@module "diffview.git.utils"
local logger = lazy.require("diffview.logger") ---@module "diffview.logger"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

---@type PathLib
local pl = lazy.access(utils, "path")

local M = {}

---@type View[]
M.views = {}

function M.diffview_open(args)
  local default_args = config.get_config().default_args.DiffviewOpen
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local rev_arg = argo.args[1]
  local paths = {}

  logger.info("[command call] :DiffviewOpen " .. table.concat(vim.tbl_flatten({
    default_args,
    args,
  }), " "))

  for _, path_arg in ipairs(argo.post_args) do
    local magic, pattern = git.pathspec_split(pl:vim_expand(path_arg))
    pattern = pl:readlink(pattern) or pattern
    table.insert(paths, magic .. pattern)
  end

  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile
  ---@type string
  local cpath = argo:get_flag("C", { no_empty = true, expand = true })

  local top_indicators = {
    cpath and pl:realpath(cpath) or (
      vim.bo.buftype == ""
      and pl:absolute(cfile)
      or nil
    ),
  }

  if not cpath then
    table.insert(top_indicators, pl:realpath("."))
  end

  local err, git_toplevel = M.find_git_toplevel(top_indicators)

  if err then
    utils.err(err)
    return
  end

  ---@cast git_toplevel string
  logger.lvl(1).s_debug(("Found git top-level: %s"):format(utils.str_quote(git_toplevel)))

  local cwd = cpath or vim.loop.cwd()
  paths = vim.tbl_map(function(pathspec)
    return git.pathspec_expand(git_toplevel, cwd, pathspec)
  end, paths) --[[@as string[] ]]

  local left, right = M.parse_revs(git_toplevel, rev_arg, {
    cached = argo:get_flag({ "cached", "staged" }),
    imply_local = argo:get_flag("imply-local"),
  })

  if not (left and right) then
    return
  end

  logger.lvl(1).s_debug(("Parsed revs: left = %s, right = %s"):format(left, right))

  ---@type DiffViewOptions
  local options = {
    show_untracked = arg_parser.ambiguous_bool(
      argo:get_flag({ "u", "untracked-files" }, { plain = true }),
      nil,
      { "all", "normal", "true" },
      { "no", "false" }
    ),
    selected_file = argo:get_flag("selected-file", { no_empty = true, expand = true })
      or (vim.bo.buftype == "" and pl:vim_expand("%:p"))
      or nil,
  }

  local git_ctx = {
    toplevel = git_toplevel,
    dir = git.git_dir(git_toplevel),
  }

  if not git_ctx.dir then
    utils.err(
      ("Failed to find the git dir for the repository: %s")
      :format(utils.str_quote(git_ctx.toplevel))
    )
    return
  end

  ---@type DiffView
  local v = DiffView({
    git_ctx = git_ctx,
    rev_arg = rev_arg,
    path_args = paths,
    left = left,
    right = right,
    options = options,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  logger.lvl(1).s_debug("DiffView instantiation successful!")

  return v
end

---@param range? { [1]: integer, [2]: integer }
---@param args string[]
function M.file_history(range, args)
  local default_args = config.get_config().default_args.DiffviewFileHistory
  local argo = arg_parser.parse(vim.tbl_flatten({ default_args, args }))
  local paths = {}
  local rel_paths

  logger.info("[command call] :DiffviewFileHistory " .. table.concat(vim.tbl_flatten({
    default_args,
    args,
  }), " "))

  for _, path_arg in ipairs(argo.args) do
    local magic, pattern = git.pathspec_split(pl:vim_expand(path_arg))
    pattern = pl:readlink(pattern) or pattern
    table.insert(paths, magic .. pattern)
  end

  ---@type string
  local cpath = argo:get_flag("C", { no_empty = true, expand = true })
  local cfile = pl:vim_expand("%")
  cfile = pl:readlink(cfile) or cfile

  local top_indicators = {}
  for _, path in ipairs(paths) do
    if git.pathspec_split(path) == "" then
      table.insert(top_indicators, pl:absolute(path, cpath))
      break
    end
  end

  table.insert(top_indicators, cpath and pl:realpath(cpath) or (
      vim.bo.buftype == ""
      and pl:absolute(cfile)
      or nil
    ))

  if not cpath then
    table.insert(top_indicators, pl:realpath("."))
  end

  local err, git_toplevel = M.find_git_toplevel(top_indicators)

  if err then
    utils.err(err)
    return
  end

  ---@cast git_toplevel string
  logger.lvl(1).s_debug(("Found git top-level: %s"):format(utils.str_quote(git_toplevel)))

  rel_paths = vim.tbl_map(function(v)
    return v == "." and "." or pl:relative(v, ".")
  end, paths)

  local cwd = cpath or vim.loop.cwd()
  paths = vim.tbl_map(function(pathspec)
    return git.pathspec_expand(git_toplevel, cwd, pathspec)
  end, paths) --[[@as string[] ]]

  ---@type string
  local range_arg = argo:get_flag("range", { no_empty = true })
  if range_arg then
    local ok = git.verify_rev_arg(git_toplevel, range_arg)
    if not ok then
      utils.err(("Bad revision: %s"):format(utils.str_quote(range_arg)))
      return
    end

    logger.lvl(1).s_debug(("Verified range rev: %s"):format(range_arg))
  end

  local log_flag_names = {
    { "follow" },
    { "first-parent" },
    { "show-pulls" },
    { "reflog" },
    { "all" },
    { "merges" },
    { "no-merges" },
    { "reverse" },
    { "max-count", "n" },
    { "L" },
    { "diff-merges" },
    { "author" },
    { "grep" },
    { "base" },
  }

  ---@type LogOptions
  local log_options = { rev_range = range_arg }
  for _, names in ipairs(log_flag_names) do
    local key, _ = names[1]:gsub("%-", "_")
    local v = argo:get_flag(names, {
      expect_string = type(config.log_option_defaults[key]) ~= "boolean",
      expect_list = names[1] == "L",
    })
    log_options[key] = v
  end

  if range then
    paths, rel_paths = {}, {}
    log_options.L = {
      ("%d,%d:%s"):format(range[1], range[2], pl:relative(pl:absolute(cfile), git_toplevel))
    }
  end

  log_options.path_args = paths

  local ok, opt_description = git.file_history_dry_run(git_toplevel, log_options)

  if not ok then
    utils.info({
      ("No git history for the target(s) given the current options! Targets: %s")
        :format(#rel_paths == 0 and "':(top)'" or table.concat(vim.tbl_map(function(v)
          return "'" .. v .. "'"
        end, rel_paths) --[[@as vector ]], ", ")),
      ("Current options: [ %s ]"):format(opt_description)
    })
    return
  end

  local git_ctx = {
    toplevel = git_toplevel,
    dir = git.git_dir(git_toplevel),
  }

  if not git_ctx.dir then
    utils.err(
      ("Failed to find the git dir for the repository: %s")
      :format(utils.str_quote(git_ctx.toplevel))
    )
    return
  end

  ---@type FileHistoryView
  local v = FileHistoryView({
    git_ctx = git_ctx,
    log_options = log_options,
  })

  if not v:is_valid() then
    return
  end

  table.insert(M.views, v)
  logger.lvl(1).s_debug("FileHistoryView instantiation successful!")

  return v
end

---Try to find the top-level of a working tree by using the given indicative
---paths.
---@param top_indicators string[] A list of paths that might indicate what working tree we are in.
---@return string? err
---@return string? toplevel # The absolute path to the git top-level.
function M.find_git_toplevel(top_indicators)
  local toplevel
  for _, p in ipairs(top_indicators) do
    if not pl:is_dir(p) then
      p = pl:parent(p)
    end

    if p and pl:readable(p) then
      toplevel = git.toplevel(p)

      if toplevel then
        return nil, toplevel
      end
    end
  end

  return (
    ("Path not a git repo (or any parent): %s")
    :format(table.concat(vim.tbl_map(function(v)
      local rel_path = pl:relative(v, ".")
      return utils.str_quote(rel_path == "" and "." or rel_path)
    end, top_indicators) --[[@as vector ]], ", "))
  )
end

---Parse a given rev arg.
---@param git_toplevel string
---@param rev_arg string
---@param opt table
---@return Rev? left
---@return Rev? right
function M.parse_revs(git_toplevel, rev_arg, opt)
  ---@type Rev?
  local left
  ---@type Rev?
  local right

  local head = git.head_rev(git_toplevel)
  ---@cast head Rev

  if not rev_arg then
    if opt.cached then
      left = head or Rev.new_null_tree()
      right = Rev(RevType.STAGE, 0)
    else
      left = Rev(RevType.STAGE, 0)
      right = Rev(RevType.LOCAL)
    end
  elseif rev_arg:match("%.%.%.") then
    left, right = git.symmetric_diff_revs(git_toplevel, rev_arg)
    if not (left or right) then
      return
    elseif opt.imply_local then
      ---@cast left Rev
      ---@cast right Rev
      left, right = M.imply_local(left, right, head)
    end
  else
    local rev_strings, code, stderr = git.exec_sync(
      { "rev-parse", "--revs-only", rev_arg }, git_toplevel
    )
    if code ~= 0 then
      utils.err(utils.vec_join(
        ("Failed to parse rev %s!"):format(utils.str_quote(rev_arg)),
        "Git output: ",
        stderr
      ))
      return
    elseif #rev_strings == 0 then
      utils.err("Bad revision: " .. utils.str_quote(rev_arg))
      return
    end

    local is_range = git.is_rev_arg_range(rev_arg)

    if is_range then
      local right_hash = rev_strings[1]:gsub("^%^", "")
      right = Rev(RevType.COMMIT, right_hash)
      if #rev_strings > 1 then
        local left_hash = rev_strings[2]:gsub("^%^", "")
        left = Rev(RevType.COMMIT, left_hash)
      else
        left = Rev.new_null_tree()
      end

      if opt.imply_local then
        left, right = M.imply_local(left, right, head)
      end
    else
      local hash = rev_strings[1]:gsub("^%^", "")
      left = Rev(RevType.COMMIT, hash)
      if opt.cached then
        right = Rev(RevType.STAGE, 0)
      else
        right = Rev(RevType.LOCAL)
      end
    end
  end

  return left, right
end

---@param left Rev
---@param right Rev
---@param head Rev
---@return Rev, Rev
function M.imply_local(left, right, head)
  if left.commit == head.commit then
    left = Rev(RevType.LOCAL)
  end
  if right.commit == head.commit then
    right = Rev(RevType.LOCAL)
  end
  return left, right
end

---@param view View
function M.add_view(view)
  table.insert(M.views, view)
end

---@param view View
function M.dispose_view(view)
  for j, v in ipairs(M.views) do
    if v == view then
      table.remove(M.views, j)
      return
    end
  end
end

---Close and dispose of views that have no tabpage.
function M.dispose_stray_views()
  local tabpage_map = {}
  for _, id in ipairs(api.nvim_list_tabpages()) do
    tabpage_map[id] = true
  end

  local dispose = {}
  for _, view in ipairs(M.views) do
    if not tabpage_map[view.tabpage] then
      -- Need to schedule here because the tabnr's don't update fast enough.
      vim.schedule(function()
        view:close()
      end)
      table.insert(dispose, view)
    end
  end

  for _, view in ipairs(dispose) do
    M.dispose_view(view)
  end
end

---Get the currently open Diffview.
---@return View?
function M.get_current_view()
  local tabpage = api.nvim_get_current_tabpage()
  for _, view in ipairs(M.views) do
    if view.tabpage == tabpage then
      return view
    end
  end

  return nil
end

function M.tabpage_to_view(tabpage)
  for _, view in ipairs(M.views) do
    if view.tabpage == tabpage then
      return view
    end
  end
end

---Get the first tabpage that is not a view. Tries the previous tabpage first.
---If there are no non-view tabpages: returns nil.
---@return number|nil
function M.get_prev_non_view_tabpage()
  local tabs = api.nvim_list_tabpages()
  if #tabs > 1 then
    local seen = {}
    for _, view in ipairs(M.views) do
      seen[view.tabpage] = true
    end

    local prev_tab = utils.tabnr_to_id(vim.fn.tabpagenr("#")) or -1
    if api.nvim_tabpage_is_valid(prev_tab) and not seen[prev_tab] then
      return prev_tab
    else
      for _, id in ipairs(tabs) do
        if not seen[id] then
          return id
        end
      end
    end
  end
end

function M.update_colors()
  for _, view in ipairs(M.views) do
    if view:instanceof(StandardView.__get()) then
      ---@cast view StandardView
      if view.panel:buf_loaded() then
        view.panel:render()
        view.panel:redraw()
      end
    end
  end
end

return M
