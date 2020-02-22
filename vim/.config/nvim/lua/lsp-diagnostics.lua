local myutil = require 'util'
local api = vim.api

-- {<bufnr>: {<lineNr>: {diagnostics}}}
local diagnostics_by_buffer = {}
local M = {}


local function diagnostics_to_items(bufnr, buf_diagnostics)
    local items = {}
    if not buf_diagnostics then return items end
    for linenr, diagnostics in pairs(buf_diagnostics) do
        if #diagnostics > 0 then
            local d = diagnostics[1]
            table.insert(items, {
                bufnr = bufnr,
                lnum = linenr + 1,
                vcol = 1,
                col = d.range.start.character,
                text = d.message
            })
        end
    end
    return items
end


local function save_diagnostics(bufnr, diagnostics)
    vim.validate {
      bufnr = {bufnr, 'n', true};
      diagnostics = {diagnostics, 't', true};
    }
    if not diagnostics then return end
    bufnr = bufnr == 0 and api.nvim_get_current_buf() or bufnr

    if not diagnostics_by_buffer[bufnr] then
      -- Clean up our data when the buffer unloads.
      api.nvim_buf_attach(bufnr, false, {
        on_detach = function(b)
          diagnostics_by_buffer[b] = nil
        end
      })
    end
    diagnostics_by_buffer[bufnr] = {}
    local buffer_diagnostics = diagnostics_by_buffer[bufnr]

    for _, diagnostic in ipairs(diagnostics) do
      local start = diagnostic.range.start
      -- local mark_id = api.nvim_buf_set_extmark(bufnr, diagnostic_ns, 0, start.line, 0, {})
      -- buffer_diagnostics[mark_id] = diagnostic
      local line_diagnostics = buffer_diagnostics[start.line]
      if not line_diagnostics then
        line_diagnostics = {}
        buffer_diagnostics[start.line] = line_diagnostics
      end
      table.insert(line_diagnostics, diagnostic)
    end
end


function M.publishDiagnostics(_, _, result)
    if not result then return end
    local uri = result.uri
    local bufnr = vim.uri_to_bufnr(uri)
    if not bufnr then
        myutil.err_message("LSP.publishDiagnostics: Couldn't find buffer for ", uri)
        return
    end
    save_diagnostics(bufnr, result.diagnostics)
end


local function update_buf_loclist(bufnr, buf_diagnostics)
    local items = diagnostics_to_items(bufnr, buf_diagnostics)
    vim.fn.setloclist(0, {}, ' ', {
        title = 'Language Server';
        items = items
    })
end


function M.show_diagnostics()
    local bufnr = api.nvim_get_current_buf()
    local buf_diagnostics = diagnostics_by_buffer[bufnr]
    update_buf_loclist(bufnr, buf_diagnostics)
end


return M
