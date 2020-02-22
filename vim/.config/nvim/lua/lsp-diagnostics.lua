local myutil = require 'util'
local api = vim.api
local util = vim.lsp.util
local protocol = vim.lsp.protocol

-- {<bufnr>: {<lineNr>: {diagnostics}}}
local diagnostics_by_buffer = {}
local M = {}

local ns = api.nvim_create_namespace('lsp-diagnostics')
local hl_underline = 'LspDiagnosticsUnderline'
local hlmap = {
    [protocol.DiagnosticSeverity.Error]='Error',
    [protocol.DiagnosticSeverity.Warning]='Warning',
    [protocol.DiagnosticSeverity.Information]='Information',
    [protocol.DiagnosticSeverity.Hint]='Hint',
}

local function diagnostics_to_items(bufnr, buf_diagnostics)
    local items = {}
    for linenr, diagnostics in pairs(buf_diagnostics) do
        if #diagnostics > 0 then
            local d = diagnostics[1]
            table.insert(items, {
                bufnr = bufnr,
                lnum = linenr + 1,
                vcol = 1,
                col = d.range.start.character + 1,
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


local function update_highlights(bufnr, buf_diagnostics)
    for linenr, diagnostics in pairs(buf_diagnostics) do
        for _, d in ipairs(diagnostics) do
            api.nvim_buf_add_highlight(
                bufnr,
                ns,
                hl_underline .. hlmap[d.severity],
                linenr,
                d.range.start.character,
                d.range["end"].character
            )
        end
    end
end


local function popup_for_current_line(buf_diagnostics)
    local row, col = unpack(api.nvim_win_get_cursor(0))
    local line_diagnostics = buf_diagnostics[row - 1]
    if not line_diagnostics then return end
    local lines = {}
    for _, d in ipairs(line_diagnostics) do
        if d.range.start.character < col and d.range['end'].character > col then
            table.insert(lines, d.message)
        end
    end
    if lines then
        util.focusable_preview('lsp-diagnostics', function()
            return lines, 'plaintext'
        end)
    end
end


function M.show_diagnostics()
    local bufnr = api.nvim_get_current_buf()
    local buf_diagnostics = diagnostics_by_buffer[bufnr]
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    if not buf_diagnostics then return end
    update_buf_loclist(bufnr, buf_diagnostics)
    update_highlights(bufnr, buf_diagnostics)
    -- popup_for_current_line(buf_diagnostics)
end


function M.show_all_diagnostics_in_quickfix()
    local all_items = {}
    for bufnr, buf_diag in ipairs(diagnostics_by_buffer) do
        for _, item in ipairs(diagnostics_to_items(bufnr, buf_diag)) do
            table.insert(all_items, item)
        end
    end
    vim.fn.setqflist({}, ' ', {
        title = 'Language Server';
        items = all_items
    })
    api.nvim_command("copen")
    api.nvim_command("wincmd p")
end

return M
