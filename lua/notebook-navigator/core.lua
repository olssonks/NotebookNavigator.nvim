local commenter = require "notebook-navigator.commenters"
local get_repl = require "notebook-navigator.repls"
local miniai_spec = require("notebook-navigator.miniai_spec").miniai_spec

local ts = vim.treesitter

local tsquery = [[
(
    (comment) @cmt (#eq? @cmt "# %%") (#offset! @cmt)
)
	]]

local query = ts.query.parse("python", tsquery)

local function overlaps_range(range, other)
  return range.from[1] <= other.to[1] and other.from[1] <= range.to[1]
end

local function get_start_lines(bufnr)
  local parser = ts.get_parser(bufnr, "python")
  local tree = parser:parse()
  local root = tree[1]:root()

  local line_starts = { 0 }

  for _, captures, metadata in query:iter_matches(root, bufnr) do
    local line_num = metadata[1].range[1]
    table.insert(line_starts, line_num)
  end

  table.insert(line_starts, vim.api.nvim_buf_line_count(bufnr))

  return line_starts
end

local function get_all_cells(cell_starts)
  local column = 0
  local num_starts = #cell_starts
  local cell_ranges = {}
  for i = 1, num_starts - 1, 1 do
    cell_ranges[i] = {
      range = { from = { cell_starts[i], column }, to = { cell_starts[i + 1], column } },
    }
  end
  return cell_ranges
end

local function get_range(direction)
  local cursor_pos = vim.api.nvim_win_get_cursor(0)
  local cursor_row = cursor_pos[1]
  local lastline = vim.api.nvim_buf_line_count(0)
  local range = {}
  if direction == "above" then
    range = { from = { 1, 0 }, to = { cursor_row, 0 } }
  elseif direction == "below" then
    range = { from = { cursor_row, 0 }, to = { lastline, 0 } }
  elseif direction == "all" then
    range = { from = { 1, 0 }, to = { lastline, 0 } }
  end
  return range
end

local function get_cells_to_run(direction, buf_nr)
  local start_lines = get_start_lines(buf_nr)
  local cells = get_all_cells(start_lines)
  local run_range = get_range(direction)
  local cells_to_run = {}
  for _, cell in ipairs(cells) do
    if overlaps_range(run_range, cell.range) then
      table.insert(cells_to_run, cell)
    end
  end
  return cells_to_run
end

local function look_at(this)
  vim.notify(vim.inspect(this))
end
local buf_nr = 10
local lines = get_start_lines(buf_nr)
local starts = get_all_cells(lines)

local M = {}

M.move_cell = function(dir, cell_marker)
  local search_res
  local result

  if dir == "d" then
    search_res = vim.fn.search("^" .. cell_marker, "W")
    if search_res == 0 then
      result = "last"
    end
  else
    search_res = vim.fn.search("^" .. cell_marker, "bW")
    if search_res == 0 then
      result = "first"
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
    end
  end

  return result
end

M.swap_cell = function(dir, cell_marker)
  local buf_length = vim.api.nvim_buf_line_count(0)
  local should_insert_marker = false

  -- Get cells in their future order
  local starting_cursor = vim.api.nvim_win_get_cursor(0)
  local first_cell
  local second_cell
  if dir == "d" then
    second_cell = miniai_spec("a", cell_marker)
    if second_cell.to.line + 1 > buf_length then
      return
    end
    vim.api.nvim_win_set_cursor(0, { second_cell.to.line + 2, 0 })
    first_cell = miniai_spec("a", cell_marker)
  else
    first_cell = miniai_spec("a", cell_marker)
    if first_cell.from.line - 1 < 1 then
      return
    end
    vim.api.nvim_win_set_cursor(0, { first_cell.from.line - 1, 0 })
    second_cell = miniai_spec("a", cell_marker)

    -- The first cell may not have a marker. If this is the case and we attempt to
    -- swap it down we will be in trouble. In that case we first insert a marker at
    -- the top.
    -- If the line does not start with the cell_marker with set a marker to add
    -- the line later on.
    local first_cell_line =
      vim.api.nvim_buf_get_lines(0, second_cell.from.line - 1, second_cell.from.line, false)[1]

    if string.sub(first_cell_line, 1, string.len(cell_marker)) ~= cell_marker then
      should_insert_marker = true
    end
    --
  end

  -- Combine cells and set in place
  local first_lines = vim.api.nvim_buf_get_lines(0, first_cell.from.line - 1, first_cell.to.line, false)
  local second_lines = vim.api.nvim_buf_get_lines(0, second_cell.from.line - 1, second_cell.to.line, false)

  local final_lines = {}

  for _, v in ipairs(first_lines) do
    table.insert(final_lines, v)
  end

  -- This extra marker protects us agains malformed notebooks that don't have a cell
  -- marker at the top of the file. See the "up" case a few lines above.
  if should_insert_marker then
    table.insert(final_lines, cell_marker)
  end
  for _, v in ipairs(second_lines) do
    table.insert(final_lines, v)
  end
  vim.api.nvim_buf_set_lines(0, second_cell.from.line - 1, first_cell.to.line, false, final_lines)

  -- Put cursor in previous position
  local new_cursor = starting_cursor
  if dir == "d" then
    new_cursor[1] = new_cursor[1] + (first_cell.to.line - first_cell.from.line + 1)
  else
    new_cursor[1] = new_cursor[1] - (second_cell.to.line - second_cell.from.line + 1)
  end
  vim.api.nvim_win_set_cursor(0, new_cursor)
end

M.run_cell = function(cell_marker, repl_provider, repl_args)
  repl_args = repl_args or nil
  repl_provider = repl_provider or "auto"
  local cell_object = miniai_spec("i", cell_marker)

  -- protect ourselves against the case with no actual lines of code
  local n_lines = cell_object.to.line - cell_object.from.line + 1
  if n_lines < 1 then
    return nil
  end

  local repl = get_repl(repl_provider)
  return repl(cell_object.from.line, cell_object.to.line, repl_args, cell_marker)
end

M.run_and_move = function(cell_marker, repl_provider, repl_args)
  local success = M.run_cell(cell_marker, repl_provider, repl_args)

  if success then
    local is_last_cell = M.move_cell("d", cell_marker) == "last"

    -- insert a new cell to replicate the behaviour of jupyter notebooks
    if is_last_cell then
      vim.api.nvim_buf_set_lines(0, -1, -1, false, { cell_marker, "" })
      -- and move to it
      M.move_cell("d", cell_marker)
    end
  end
end

M.run_all_cells = function(repl_provider, repl_args, cell_marker)
  local repl = get_repl(repl_provider)
  local buf_nr = 0
  local cells_to_run = get_cells_to_run("all", buf_nr)
  for _, cell in ipairs(cells_to_run) do
    repl(cell.range.from, cell.range.to, repl_args, cell_marker)
  end
end

M.run_cells_below = function(cell_marker, repl_provider, repl_args)
  local repl = get_repl(repl_provider)
  local cells_to_run = get_cells_to_run("below", buf_nr)
  for _, cell in ipairs(cells_to_run) do
    repl(cell.range.from, cell.range.to, repl_args, cell_marker)
  end
end

M.run_cells_above = function(cell_marker, repl_provider, repl_args)
  local repl = get_repl(repl_provider)
  local cells_to_run = get_cells_to_run("above", buf_nr)
  for _, cell in ipairs(cells_to_run) do
    repl(cell.range.from, cell.range.to, repl_args, cell_marker)
  end
end

M.merge_cell = function(dir, cell_marker)
  local search_res
  local result

  if dir == "d" then
    search_res = vim.fn.search("^" .. cell_marker, "nW")
    vim.api.nvim_buf_set_lines(0, search_res - 1, search_res, false, { "" })
  else
    search_res = vim.fn.search("^" .. cell_marker, "nbW")
    if search_res == 0 then
      return "first"
    else
      vim.api.nvim_buf_set_lines(0, search_res - 1, search_res, false, { "" })
    end
  end

  return result
end

M.comment_cell = function(cell_marker)
  local cell_object = miniai_spec("i", cell_marker)

  -- protect against empty cells
  local n_lines = cell_object.to.line - cell_object.from.line + 1
  if n_lines < 1 then
    return nil
  end
  commenter(cell_object)
end

M.add_cell_below = function(cell_marker)
  local cell_object = miniai_spec("a", cell_marker)

  vim.api.nvim_buf_set_lines(0, cell_object.to.line, cell_object.to.line, false, { cell_marker, "" })
  M.move_cell("d", cell_marker)
end

M.add_cell_above = function(cell_marker)
  local cell_object = miniai_spec("a", cell_marker)

  -- What to do on malformed notebooks? I.e. with no upper cell marker? are they malformed?
  -- What if we have a jupytext header? Code doesn't start at top of buffer.
  vim.api.nvim_buf_set_lines(
    0,
    cell_object.from.line - 1,
    cell_object.from.line - 1,
    false,
    { cell_marker, "" }
  )
  M.move_cell("u", cell_marker)
end

-- We keep this two for backwards compatibility but the prefered way is to use
-- the above/below functions for consistency with jupyter nomenclature
M.add_cell_before = function(cell_marker)
  M.add_cell_above(cell_marker)
end

M.add_cell_after = function(cell_marker)
  M.add_cell_below(cell_marker)
end

M.split_cell = function(cell_marker)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_buf_set_lines(0, cursor_line - 1, cursor_line - 1, false, { cell_marker })
  vim.api.nvim_win_set_cursor(0, { cursor_line + 1, 0 })
end

return M
