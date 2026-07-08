local M = {}

local api, treesitter = vim.api, vim.treesitter

local NAMESPACE = api.nvim_create_namespace("markdown-bullets")
local icons = { "✸", "✿", "✦", "✧" }

---Count ancestor list nodes for nesting level
local function list_level(node)
  local n, p = 0, node:parent()
  while p do
    if p:type() == "list" then n = n + 1 end
    p = p:parent()
  end
  return n
end

local function set_mark(bufnr, virt_text, lnum, start_col, end_col, highlight)
  if not virt_text then return end
  pcall(api.nvim_buf_set_extmark, bufnr, NAMESPACE, lnum, start_col, {
    end_col = end_col,
    hl_group = highlight,
    virt_text = virt_text,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    ephemeral = true,
  })
end

local function set_hl(bufnr, lnum, start_col, opts)
  opts.ephemeral = true
  pcall(api.nvim_buf_set_extmark, bufnr, NAMESPACE, lnum, start_col, opts)
end

---Marker handlers: returns { { text, highlight } } for extmark virt_text
local markers = {
  default = function(str, level, hl)
    local icon = icons[(level - 1) % #icons + 1]
    local lead = #str:match("^%s*")
    return { { string.rep(" ", lead) .. icon .. " ", hl } }
  end,
}

local parse = treesitter.query and treesitter.query.parse or treesitter.parse_query

local bullet_query = parse("markdown", [[
  (list_item
    [(list_marker_minus) (list_marker_plus) (list_marker_star)] @bullet)
]])

local codeblock_query = parse("markdown", "(fenced_code_block) @block")
local codefence_query = parse("markdown", "(fenced_code_block_delimiter) @fence")
local heading_marker_query = parse("markdown", [[
  [(atx_h1_marker) (atx_h2_marker) (atx_h3_marker)
   (atx_h4_marker) (atx_h5_marker) (atx_h6_marker)] @marker
]])

local highlight_groups = {
  list_marker_minus = "MdBulletsDash",
  list_marker_plus = "MdBulletsPlus",
  list_marker_star = "MdBulletsStar",
}

local function get_mark_positions(bufnr, start_row, end_row)
  local parser = treesitter.get_parser(bufnr, "markdown", {})
  if not parser then return {} end
  local positions = {}
  parser:for_each_tree(function(tstree, _)
    local root = tstree:root()
    for _, match, _ in bullet_query:iter_matches(root, bufnr, start_row, end_row, { all = true }) do
      for id, nodes in pairs(match) do
        if not vim.startswith(bullet_query.captures[id], "_") then
          for _, node in ipairs(nodes) do
            local row, c0, _, c1 = node:range()

            -- Skip task list / checkbox items
            local parent = node:parent()
            if parent then
              for child in parent:iter_children() do
                local ct = child:type()
                if ct == "task_list_marker_unchecked" or ct == "task_list_marker_checked" then
                  goto continue
                end
              end
            end
            local line = (api.nvim_buf_get_lines(bufnr, row, row + 1, false) or {""})[1]
            if line:sub(c1 + 1):match("^%s*%[.%]") then goto continue end

            local t = node:type()
            positions[#positions + 1] = {
              item = treesitter.get_node_text(node, bufnr),
              type = t,
              level = list_level(node),
              start_row = row,
              start_col = c0,
              end_col = c1,
            }
            ::continue::
          end
        end
      end
    end
  end)
  return positions
end

local ticks = {}

function M.setup(conf)
  if conf and conf.symbols and conf.symbols.list then
    icons = conf.symbols.list
  end

  -- Highlight groups
  for _, hl in pairs(highlight_groups) do
    api.nvim_set_hl(0, hl, { link = "NonText", default = true })
  end
  api.nvim_set_hl(0, "MdBulletsCodeBlock", { link = "CursorLine", default = true })

  -- Smart Enter
  api.nvim_create_autocmd("FileType", {
    pattern = "markdown",
    callback = function(args)
      vim.keymap.set("i", "<CR>", function()
        local cursor = api.nvim_win_get_cursor(0)
        local row, col = cursor[1], cursor[2]
        local line = api.nvim_get_current_line()
        local indent, marker = line:match("^(%s*)([-*+])")
        if not indent then
          local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
          return vim.api.nvim_feedkeys(keys, "n", false)
        end
        local marker_end = #indent + 2
        local after = line:sub(marker_end + 1)
        if after == "" and col >= marker_end then
          api.nvim_set_current_line("")
          api.nvim_win_set_cursor(0, { row, 0 })
        elseif col > marker_end then
          local before = line:sub(1, col)
          local rest = line:sub(col + 1)
          api.nvim_set_current_line(before)
          local new_line = indent .. marker .. " " .. rest
          api.nvim_buf_set_lines(0, row, row, false, { new_line })
          api.nvim_win_set_cursor(0, { row + 1, #new_line })
          vim.schedule(function()
            local p = vim.treesitter.get_parser(0, "markdown")
            if p then p:parse() end
          end)
        else
          local new_line = indent .. marker .. " "
          api.nvim_buf_set_lines(0, row, row, false, { new_line })
          api.nvim_win_set_cursor(0, { row + 1, #new_line })
          vim.schedule(function()
            local p = vim.treesitter.get_parser(0, "markdown")
            if p then p:parse() end
          end)
        end
      end, { buffer = args.buf, desc = "Smart list Enter" })
    end,
  })

  -- Decoration provider
  api.nvim_set_decoration_provider(NAMESPACE, {
    on_start = function(_, tick)
      local buf = api.nvim_get_current_buf()
      if ticks[buf] == tick then return false end
      ticks[buf] = tick
      return true
    end,
    on_win = function(_, _, bufnr, topline, botline)
      if vim.bo[bufnr].filetype ~= "markdown" then return false end

      -- List bullets
      local positions = get_mark_positions(bufnr, topline, botline)
      for _, pos in ipairs(positions) do
        local hl = highlight_groups[pos.type] or "MdBulletsDash"
        set_mark(bufnr, markers.default(pos.item, pos.level, hl), pos.start_row, pos.start_col, pos.end_col)
      end

      -- Code blocks: background + conceal fences
      local parser = treesitter.get_parser(bufnr, "markdown", {})
      if parser then
        parser:parse()
        parser:for_each_tree(function(tstree)
          local root = tstree:root()
          for _, node in codeblock_query:iter_captures(root, bufnr, topline, botline) do
            local srow, _, erow = node:range()
            set_hl(bufnr, srow, 0, {
              end_row = erow,
              hl_group = "MdBulletsCodeBlock",
              hl_eol = true,
            })
          end
          for _, node in codefence_query:iter_captures(root, bufnr, topline, botline) do
            local row, c0, _, c1 = node:range()
            set_hl(bufnr, row, c0, { end_col = c1, conceal = "" })
          end
          for _, node in heading_marker_query:iter_captures(root, bufnr, topline, botline) do
            local row, c0, _, c1 = node:range()
            set_hl(bufnr, row, c0, { end_col = c1, conceal = "" })
          end
        end)
      end
    end,
    on_line = function(_, _, bufnr, row)
      if vim.bo[bufnr].filetype ~= "markdown" then return false end
      local positions = get_mark_positions(bufnr, row, row + 1)
      for _, pos in ipairs(positions) do
        local hl = highlight_groups[pos.type] or "MdBulletsDash"
        set_mark(bufnr, markers.default(pos.item, pos.level, hl), pos.start_row, pos.start_col, pos.end_col)
      end
    end,
  })
end

return M
