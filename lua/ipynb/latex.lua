-- ipynb/latex.lua - Render LaTeX to PNG images with latex, dvisvgm and rsvg-convert
-- Sources requested in the same tick are typeset as one document, one page each

local M = {}

-- Executables the pipeline needs
M.tools = { 'latex', 'dvisvgm', 'rsvg-convert' }

-- Part of every cache key: bump when the document or rasterization changes
local TEMPLATE_VERSION = '1'

-- showonlyrefs: no automatic equation numbers, like Jupyter's MathJax
local PREAMBLE = [[
\documentclass{article}
\usepackage{amsmath,amssymb,mathtools,xcolor}
\mathtoolsset{showonlyrefs}
\pagestyle{empty}
\setlength{\parindent}{0pt}
\begin{document}]]

-- Inline math: preview crops each page to its strut, one terminal row tall
local INLINE_PREAMBLE = [[
\documentclass{article}
\usepackage{amsmath,amssymb,mathtools,xcolor}
\usepackage[active,tightpage]{preview}
\setlength\PreviewBorder{0pt}
\begin{document}]]

-- rsvg-convert processes running at once per batch
local MAX_RASTERIZERS = 8

local tools_found = nil ---@type boolean|nil
local failed = {} ---@type table<string, string> Error of each failed render, by key
local waiting = {} ---@type table<string, fun()[]> Callbacks of renders in flight, by key
local queue = {} ---@type table[] Renders requested since the last flush
local flush_scheduled = false
local pruned = false
local builds = 0

---Whether LaTeX rendering is enabled and its tools are installed. Warns once
---about missing tools, so only call it when there is LaTeX to render.
---@return boolean
function M.is_available()
  local config = require('ipynb.config').get()
  if config.latex and config.latex.enabled == false then
    return false
  end
  if tools_found == nil then
    local missing = vim.tbl_filter(function(tool)
      return vim.fn.executable(tool) == 0
    end, M.tools)
    tools_found = #missing == 0
    if not tools_found then
      vim.notify(
        'ipynb.nvim: LaTeX is shown as text, ' .. table.concat(missing, ', ') .. ' not found. '
          .. 'Install TeX Live (latex, dvisvgm) and librsvg (rsvg-convert), see :checkhealth ipynb, '
          .. 'or set latex = { enabled = false } to silence this',
        vim.log.levels.WARN
      )
    end
  end
  return tools_found
end

---Get the LaTeX source of an output's text/latex entry
---@param output table Output object
---@return string|nil source
function M.get_source(output)
  if output.output_type ~= 'execute_result' and output.output_type ~= 'display_data' then
    return nil
  end
  local data = output.data and output.data['text/latex']
  if not data then
    return nil
  end
  local source = vim.trim(type(data) == 'table' and table.concat(data) or data)
  return source ~= '' and source or nil
end

-- Environments LaTeX rejects inside math, but Jupyter's MathJax accepts there
local DISPLAY_ENVIRONMENTS = {}
for _, name in ipairs({ 'align', 'alignat', 'eqnarray', 'equation', 'flalign', 'gather', 'multline' }) do
  DISPLAY_ENVIRONMENTS[name] = true
  DISPLAY_ENVIRONMENTS[name .. '*'] = true
end

---Strip math delimiters around a lone display environment
---@param source string
---@return string
local function unwrap_environment(source)
  local inner = vim.trim(source)
  for _, delimiters in ipairs({ { '^%$%$', '%$%$$' }, { '^%$', '%$$' }, { '^\\%[', '\\%]$' } }) do
    if inner:match(delimiters[1]) and inner:match(delimiters[2]) then
      inner = vim.trim(inner:gsub(delimiters[1], ''):gsub(delimiters[2], ''))
      break
    end
  end
  inner = vim.trim(inner:gsub('^\\displaystyle', ''))
  local name = inner:match('^\\begin{([%a]+%*?)}')
  if name and DISPLAY_ENVIRONMENTS[name] and inner:match('\\end{' .. vim.pesc(name) .. '}$') then
    return inner
  end
  return source
end

---Text color for rendered math, as RRGGBB
---@param group string Highlight group to take the color from
---@return string
local function foreground(group)
  for _, name in ipairs({ group, 'Normal' }) do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    if hl.fg then
      return string.format('%06X', hl.fg)
    end
  end
  return vim.o.background == 'light' and '000000' or 'FFFFFF'
end

---Rendering geometry: one 12pt line of the 10pt document is one terminal row
---@return number dpi
---@return number cell_width Pixels
---@return number cell_height Pixels
---@return number scale latex.scale
local function geometry()
  local cell_width, cell_height = require('ipynb.images').cell_size()
  local scale = (require('ipynb.config').get().latex or {}).scale or 1
  return cell_height * 72.27 / 12 * scale, cell_width, cell_height, scale
end

---@return string
local function cache_dir()
  local dir = require('ipynb.images').get_cache_dir() .. '/latex'
  vim.fn.mkdir(dir, 'p')
  if not pruned then
    pruned = true
    -- Remove builds left behind by an nvim that exited mid-render
    for _, build in ipairs(vim.fn.glob(dir .. '/build-*', false, true)) do
      local stat = vim.uv.fs_stat(build)
      if stat and os.time() - stat.mtime.sec > 600 then
        vim.fn.delete(build, 'rf')
      end
    end
  end
  return dir
end

---Run a command in dir and report whether it succeeded
---@param cmd string[]
---@param dir string
---@param on_done fun(ok: boolean)
local function run(cmd, dir, on_done)
  local ok = pcall(vim.system, cmd, {
    cwd = dir,
    timeout = 10000,
    -- Keep \openout inside the build directory
    env = { openout_any = 'p' },
  }, vim.schedule_wrap(function(result)
    on_done(result.code == 0)
  end))
  if not ok then
    on_done(false)
  end
end

---Errors in the build directory's log, with their doc.tex line when known
---@param dir string
---@return { line: number|nil, message: string }[]
local function latex_errors(dir)
  local errors = {}
  local log = dir .. '/doc.log'
  if vim.fn.filereadable(log) == 1 then
    for _, text in ipairs(vim.fn.readfile(log)) do
      local line, message = text:match('^[./]*doc%.tex:(%d+): (.+)')
      message = message or text:match('^! (.+)')
      if message then
        table.insert(errors, { line = tonumber(line), message = (message:gsub('%s*%.$', '')) })
      end
    end
  end
  return errors
end

---Whether a source's braces balance (an open group swallows the formulas after it)
---@param source string
---@return boolean
local function balanced(source)
  local depth = 0
  for backslashes, brace in source:gmatch('(\\*)([{}])') do
    if #backslashes % 2 == 0 then
      depth = depth + (brace == '{' and 1 or -1)
      if depth < 0 then
        return false
      end
    end
  end
  return depth == 0
end

---Report the outcome of one render to everyone waiting on it
---@param item table
---@param err string|nil Why the render failed
local function finish(item, err)
  failed[item.key] = err
  local callbacks = waiting[item.key] or {}
  waiting[item.key] = nil
  for _, callback in ipairs(callbacks) do
    callback()
  end
end

---Rasterize one page into the item's cache file, on a canvas of whole cells
---@param item table
---@param svg string Path to the page's SVG
---@param on_done fun(err: string|nil)
local function rasterize(item, svg, on_done)
  local head = table.concat(vim.fn.readfile(svg, '', 5), '\n')
  local width_pt = tonumber(head:match('width=["\']([%d.]+)pt["\']'))
  local height_pt = tonumber(head:match('height=["\']([%d.]+)pt["\']'))
  if not width_pt or not height_pt then
    return on_done('dvisvgm wrote an SVG without a size')
  end

  -- rsvg-convert reads SVG pt as 1/72 inch
  local resolution = item.dpi
  local height = height_pt * resolution / 72
  if item.inline and height > item.cell_height + 0.5 then
    -- Shrink to one row here rather than let kitty rescale it
    resolution = resolution * item.cell_height / height
    height = item.cell_height
  end
  local width = width_pt * resolution / 72
  local canvas_width = math.max(1, math.ceil(width / item.cell_width - 1e-6)) * item.cell_width
  local left = item.inline and (canvas_width - width) / 2 or 0
  local canvas_height = item.inline and item.cell_height
    or math.max(1, math.ceil(height / item.cell_height - 1e-6)) * item.cell_height
  local dpi = ('%.3f'):format(resolution)
  local png = svg:gsub('%.svg$', '.png')
  -- '--opt=value', so a negative offset is not read as an option
  run({
    'rsvg-convert', '--dpi-x=' .. dpi, '--dpi-y=' .. dpi,
    ('--page-width=%dpx'):format(canvas_width), ('--page-height=%dpx'):format(canvas_height),
    ('--left=%.3fpx'):format(left), ('--top=%.3fpx'):format((canvas_height - height) / 2),
    '-o', png, svg,
  }, vim.fs.dirname(svg), function(ok)
    ok = ok and vim.uv.fs_rename(png, item.path) ~= nil
    on_done(not ok and 'rsvg-convert failed' or nil)
  end)
end

---Render items sharing a color and geometry as one document, one page each.
---Errors are blamed on the formula at their line; other failures split the batch.
---@param items table[]
---@param on_done fun()
local function render(items, on_done)
  -- Formulas with unbalanced braces are typeset alone
  if #items > 1 then
    local groups, shared = {}, {}
    for _, item in ipairs(items) do
      if balanced(item.source) then
        table.insert(shared, item)
      else
        table.insert(groups, { item })
      end
    end
    if #groups > 0 then
      if #shared > 0 then
        table.insert(groups, shared)
      end
      local pending = #groups
      for _, group in ipairs(groups) do
        render(group, function()
          pending = pending - 1
          if pending == 0 then
            on_done()
          end
        end)
      end
      return
    end
  end

  builds = builds + 1
  local dir = ('%s/build-%d-%d'):format(cache_dir(), vim.fn.getpid(), builds)
  vim.fn.mkdir(dir, 'p')

  -- Remember the doc.tex lines of each formula to blame errors on it
  local color = ('\\color[HTML]{%s}'):format(items[1].fg)
  local lines = vim.split(items[1].inline and INLINE_PREAMBLE or PREAMBLE, '\n')
  if not items[1].inline then
    table.insert(lines, color)
  end
  local ranges = {}
  for i, item in ipairs(items) do
    local body = vim.split(item.source, '\n')
    if item.inline then
      -- The strut shrinks with the scale to stay one row tall
      local strut = ('\\rule[-%.4fpt]{0pt}{%.4fpt}'):format(3.6 / item.scale, 12 / item.scale)
      body[1] = '\\begin{preview}' .. color .. strut .. ' ' .. body[1]
      body[#body] = body[#body] .. '\\end{preview}'
    else
      body[1] = '\\begingroup ' .. body[1]
      body[#body] = body[#body] .. '\\endgroup\\clearpage'
    end
    ranges[i] = { #lines + 1, #lines + #body }
    vim.list_extend(lines, body)
  end
  table.insert(lines, '\\end{document}')
  vim.fn.writefile(lines, dir .. '/doc.tex')

  ---The batch as a whole failed: report why for a single source, or retry halves
  ---@param err string
  local function fail(err)
    vim.fn.delete(dir, 'rf')
    if #items == 1 then
      finish(items[1], err)
      return on_done()
    end
    local half = math.floor(#items / 2)
    render(vim.list_slice(items, 1, half), function()
      render(vim.list_slice(items, half + 1), on_done)
    end)
  end

  local latex = { 'latex', '-no-shell-escape', '-file-line-error', '-interaction=nonstopmode', 'doc.tex' }
  run(latex, dir, function(ok)
    if not ok then
      local errors = latex_errors(dir)
      local blamed = {}
      for _, err in ipairs(errors) do
        for i, range in ipairs(ranges) do
          if err.line and err.line >= range[1] and err.line <= range[2] then
            blamed[i] = blamed[i] or err.message
          end
        end
      end
      if #items == 1 or not next(blamed) then
        return fail(errors[1] and errors[1].message or 'latex failed')
      end
      vim.fn.delete(dir, 'rf')
      local rest = {}
      for i, item in ipairs(items) do
        if blamed[i] then
          finish(item, blamed[i])
        else
          table.insert(rest, item)
        end
      end
      if #rest == 0 then
        return on_done()
      end
      return render(rest, on_done)
    end
    -- Display math is cropped to its ink; inline math keeps its strut box.
    local bbox = items[1].inline and '--bbox=preview' or '--exact-bbox'
    run({ 'dvisvgm', '--verbosity=1', '--no-fonts', bbox, '-p1-', '-o', 'page-%p.svg', 'doc.dvi' }, dir, function(svg_ok)
      if not svg_ok then
        return fail('dvisvgm failed')
      end

      -- dvisvgm pads page numbers to the width of the page count
      local pages = {}
      for _, svg in ipairs(vim.fn.glob(dir .. '/page-*.svg', false, true)) do
        pages[tonumber(svg:match('page%-(%d+)%.svg$'))] = svg
      end
      if vim.tbl_count(pages) ~= #items then
        return fail('the LaTeX does not fit on one page')
      end

      -- Finish the batch at once, so waiting cells render once
      local started, pending, errors = 0, #items, {}
      local function rasterize_next()
        started = started + 1
        local i = started
        if i > #items then
          return
        end
        rasterize(items[i], pages[i], function(err)
          errors[i] = err
          pending = pending - 1
          if pending > 0 then
            return rasterize_next()
          end
          vim.fn.delete(dir, 'rf')
          for j, item in ipairs(items) do
            finish(item, errors[j])
          end
          on_done()
        end)
      end
      for _ = 1, math.min(MAX_RASTERIZERS, #items) do
        rasterize_next()
      end
    end)
  end)
end

---Render everything queued since the last flush, one batch per color,
---geometry and kind (display or inline)
local function flush()
  flush_scheduled = false
  local batches = {}
  for _, item in ipairs(queue) do
    local id = table.concat({ item.fg, item.dpi, item.cell_width, item.cell_height, tostring(item.inline) }, ':')
    batches[id] = batches[id] or {}
    table.insert(batches[id], item)
  end
  queue = {}
  for _, items in pairs(batches) do
    render(items, function() end)
  end
end

---Get the rendered image for a LaTeX source, starting a render if needed.
---Sources requested in the same tick are rendered together.
---@param source string LaTeX source, as found in a text/latex output
---@param on_ready fun() Called when a render started for this source finishes
---@param opts { hl: string|nil, inline: boolean|nil }|nil hl: highlight group for
---  the color (default: IpynbMath); inline: render one row tall, e.g. for `$x$`
---@return string|nil path PNG file, when the source is already rendered
---@return string|nil error Why rendering this source failed
function M.lookup(source, on_ready, opts)
  opts = opts or {}
  if not opts.inline then
    source = unwrap_environment(source)
  end
  local fg = foreground(opts.hl or 'IpynbMath')
  local dpi, cell_width, cell_height, scale = geometry()
  local parts = { TEMPLATE_VERSION, fg, dpi, cell_width, cell_height, source }
  if opts.inline then
    table.insert(parts, 1, 'inline')
  end
  local key = vim.fn.sha256(table.concat(parts, '\0'))
  if failed[key] then
    return nil, failed[key]
  end
  local path = ('%s/%s.png'):format(cache_dir(), key)
  if vim.uv.fs_stat(path) then
    return path, nil
  end

  if waiting[key] then
    table.insert(waiting[key], on_ready)
    return nil, nil
  end
  waiting[key] = { on_ready }
  table.insert(queue, {
    key = key,
    source = source,
    path = path,
    fg = fg,
    dpi = dpi,
    cell_width = cell_width,
    cell_height = cell_height,
    scale = scale,
    inline = opts.inline == true,
  })
  if not flush_scheduled then
    flush_scheduled = true
    vim.schedule(flush)
  end
  return nil, nil
end

return M
