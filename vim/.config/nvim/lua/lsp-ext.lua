local api = vim.api
local myutil = require 'util'
local lsp_diagnostics = require 'lsp-diagnostics'

local timer = nil
local on_insert_with_pause = {}
local expand_snippet = false

local M = {}

M.ticks = {}
M.commands = {
    ['java.apply.workspaceEdit'] = function(command)
        for _, argument in ipairs(command.arguments) do
            vim.lsp.util.apply_workspace_edit(argument)
        end
    end;
    ['java.action.generateToStringPrompt'] = function(_, params)
        vim.lsp.buf_request(0, 'java/checkToStringStatus', params, function(err, _, result)
            if err then
                print("Could not execute java/checkToStringStatus: " .. err.message)
            end
            if not result then return end
            if result.exists then
                local choice = vim.fn.inputlist({
                    string.format("Method 'toString()' already exists in '%s'. Do you want to replace it?", result.type),
                    "1. Replace",
                    "2. Cancel"
                })
                if choice < 1 or choice == 2 then
                    return
                end
            end
            local fields = {}
            if result.fields and #result.fields > 0 then
                for _, field in ipairs(result.fields) do
                    local choice = vim.fn.inputlist({
                        string.format("Include `%s: %s` in toString?", field.name, field.type),
                        "1. Yes",
                        "2. No"
                    })
                    if choice == 1 then
                        table.insert(fields, field)
                    end
                end
            end
            vim.lsp.buf_request(0, 'java/generateToString', { context = params; fields = fields; }, function(e, _, edit)
                if e then
                    print("Could not execute java/generateToString: " .. e.message)
                end
                if edit then
                    vim.lsp.util.apply_workspace_edit(edit)
                end
            end)
        end)
    end;
    ['java.action.hashCodeEqualsPrompt'] = function(_, params)
        vim.lsp.buf_request(0, 'java/checkHashCodeEqualsStatus', params, function(_, _, result)
            if not result or not result.fields or #result.fields == 0 then
                print(string.format("The operation is not applicable to the type %", result.type))
            end

            local fields = {}
            for _, field in ipairs(result.fields) do
                local choice = vim.fn.inputlist({
                    string.format("Include `%s: %s` in equals/hashCode?", field.name, field.type),
                    "1. Yes",
                    "2. No"
                })
                if choice == 1 then
                    table.insert(fields, field)
                end
            end
            vim.lsp.buf_request(0, 'java/generateHashCodeEquals', { context = params; fields = fields; }, function(e, _, edit)
                if e then
                    print("Could not execute java/generateHashCodeEquals: " .. e.message)
                end
                if edit then
                    vim.lsp.util.apply_workspace_edit(edit)
                end
            end)
        end)
    end;
}


function M._InsertCharPre()
    if timer then
        timer:stop()
        timer:close()
    end
    timer = vim.loop.new_timer()
    local char = api.nvim_get_vvar('char')
    for _, entry in pairs(on_insert_with_pause) do
        local chars, fn = unpack(entry)
        if vim.tbl_contains(chars, char) then
            timer:start(150, 0, vim.schedule_wrap(function()
                if api.nvim_get_mode()['mode'] == 'i' then
                    fn()
                end
            end))
            return
        end
    end
end


function M._InsertLeave()
    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
end


local function trigger_completion()
    local bufnr = api.nvim_get_current_buf()
    local pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local line_to_cursor = line:sub(1, pos[2])
    local textMatch = vim.fn.match(line_to_cursor, '\\k*$')
    local prefix = line_to_cursor:sub(textMatch+1)
    local params = vim.lsp.util.make_position_params()
    vim.lsp.buf_request(bufnr, 'textDocument/completion', params, function(err, _, result)
        if err or not result then return end
        local matches = vim.lsp.util.text_document_completion_list_to_complete_items(result, prefix)
        vim.fn.complete(textMatch + 1, matches)
  end)
end


local function openJdtLink(uri, range)
    local bufnr = api.nvim_get_current_buf()
    local params = {
        uri = uri
    }
    vim.lsp.buf_request(bufnr, 'java/classFileContents', params, function(err, _, content)
        if err then return end
        local buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(content, '\n', true))
        api.nvim_buf_set_option(buf, 'filetype', 'java')
        myutil.jump_to_buf(buf, range)
    end)
end


local function isJdtLinkLocation(location)
    return location and (location.uri and location.uri:sub(1, 6) == "jdt://")
end


function M.location_callback(autojump)
    return function(_, _, result)
        if result == nil or #result == 0 then
            return nil
        end
        if not autojump or #result > 1 then
            vim.fn.setqflist({}, ' ', {
                title = 'Language Server';
                items = vim.lsp.util.locations_to_items(
                    vim.tbl_filter(
                        function(loc) return not isJdtLinkLocation(loc) end,
                        result
                    )
                )
            })
            api.nvim_command("copen")
            api.nvim_command("wincmd p")
        elseif result[1].uri ~= nil then
            vim.cmd "normal! m'" -- save position in jumplist
            local location = result[1]
            if location.uri:sub(1, 6) == "jdt://" then
                openJdtLink(location.uri, location.range)
            else
                myutil.jump_to_buf(vim.uri_to_bufnr(location.uri), location.range)
            end
        end
    end
end


function M._CompleteDone()
    local completed_item = api.nvim_get_vvar('completed_item')
    if not completed_item or not completed_item.user_data or completed_item.user_data == '' then
        return
    end
    local item = vim.fn.json_decode(completed_item.user_data)

    -- 2 is snippet
    if item.insertTextFormat ~= 2 or not expand_snippet then
        return
    end
    expand_snippet = false
    local row, pos = unpack(api.nvim_win_get_cursor(0))
    -- Create textEdit to remove the already inserted word
    local text_edit = {
        range = {
            ["start"] = {
                line = row - 1;
                character = (pos - #completed_item.word);
            };
            ["end"] = {
                line = row - 1;
                character = pos;
            }
        };
        newText = "";
    }
    vim.lsp.util.apply_text_edits({text_edit}, api.nvim_get_current_buf())

    if item.textEdit then
        api.nvim_call_function("UltiSnips#Anon", {item.textEdit.newText})
    else
        api.nvim_call_function("UltiSnips#Anon", {item.insertText})
    end
end


local function text_document_completion_list_to_complete_items(result, prefix)
    local items = vim.tbl_filter(function(item)
        return (item.insertText and vim.startswith(item.insertText, prefix))
            or (item.label and vim.startswith(item.label, prefix))
            or (item.textEdit and item.textEdit.newText and vim.startswith(item.textEdit.newText, prefix))
    end, vim.lsp.util.extract_completion_items(result))
    if #items == 0 then
        return {}
    end
    if items[1] and items[1].sortText then
        table.sort(items, function(a, b) return (a.sortText or 0) < (b.sortText or 0) end)
    end

    local matches = {}
    for _, item in ipairs(items) do
        local info = ' '
        local documentation = item.documentation
        if documentation then
            if type(documentation) == 'string' and documentation ~= '' then
                info = documentation
            elseif type(documentation) == 'table' and type(documentation.value) == 'string' then
                info = documentation.value
            end
        end
        local kind = vim.lsp.protocol.CompletionItemKind[item.kind] or ''
        local word
        if kind == 'Snippet' then
            word = item.label
        elseif item.insertTextFormat == 2 then -- 2 == snippet
            --[[
            -- eclipse.jdt.ls has
            --      insertText = "wait",
            --      label = "wait() : void"
            --      textEdit = { ... }
            --
            -- haskell-ide-engine has
            --      insertText = "testSuites ${1:Env}"
            --      label = "testSuites"
            --]]
            if item.textEdit then
                word = item.insertText
            else
                word = item.label
            end
        else
            word = (item.textEdit and item.textEdit.newText) or item.insertText or item.label
        end
        table.insert(matches, {
            word = word,
            abbr = item.label,
            kind = kind,
            menu = item.detail or '',
            info = info,
            icase = 1,
            dup = 1,
            empty = 1,
            user_data = vim.fn.json_encode(item)
        })
    end
    return matches
end


function M.accept_pum()
    if tonumber(vim.fn.pumvisible()) == 0 then
        return false
    else
        expand_snippet = true
        return true
    end
end


-- Until https://github.com/neovim/neovim/pull/11607 is merged
function M.execute_command(command)
    vim.lsp.buf_request(0, 'workspace/executeCommand', command, function(err, _, _)
        if err then
            print("Could not execute code action: " .. err.message)
        end
    end)
end


function M.organize_imports()
    M.execute_command({
        command = "java.edit.organizeImports";
        arguments = { vim.uri_from_bufnr(0) }
    })
end


-- Not needed anymore after https://github.com/neovim/neovim/pull/11607
function M.workspace_apply_edit(err, _, result)
    -- result:
    --   label?: string;
    --   edit: WorkspaceEdit;
    --
    if err then
        print("Received error for workspace/applyEdit: " .. err.message)
    end
    local status, failure = pcall(vim.lsp.util.apply_workspace_edit, result.edit)
    return {
        applied = status;
        failureReason = failure;
    }
end


local function make_code_action_params()
    local params = vim.lsp.util.make_position_params()
    local row, pos = unpack(api.nvim_win_get_cursor(0))
    params.range = {
        ["start"] = { line = row - 1; character = pos };
        ["end"] = { line = row - 1; character = pos };
    }
    local bufnr = api.nvim_get_current_buf()
    local buf_diagnostics = lsp_diagnostics.diagnostics_by_buffer[bufnr] or {}
    params.context = {
        diagnostics = buf_diagnostics[row - 1] or {}
    }
    return params
end


-- Until https://github.com/neovim/neovim/pull/11607 is merged
function M.code_action()
    local code_action_params = make_code_action_params()
    vim.lsp.buf_request(0, 'textDocument/codeAction', code_action_params, function(err, _, actions)
        if err then return end
        -- actions is (Command | CodeAction)[] | null
        -- CodeAction
        --      title: String
        --      kind?: CodeActionKind
        --      diagnostics?: Diagnostic[]
        --      isPreferred?: boolean
        --      edit?: WorkspaceEdit
        --      command?: Command
        --
        -- Command
        --      title: String
        --      command: String
        --      arguments?: any[]
        if not actions or #actions == 0 then
            print("No code actions available")
            return
        end
        local option_strings = {"Code Actions:"}
        for i, action in ipairs(actions) do
            local title = action.title:gsub('\r\n', '\\r\\n')
            title = title:gsub('\n', '\\n')
            table.insert(option_strings, string.format("%d. %s", i, title))
        end
        local choice = vim.fn.inputlist(option_strings)
        if choice < 1 or choice > #actions then
            return
        end
        local action = actions[choice]
        if action.edit then
            vim.lsp.util.apply_workspace_edit(action.edit)
            return
        end
        local command
        if type(action.command) == "table" then
            command = action.command
        else
            command = action
        end
        local fn = M.commands[command.command]
        if fn then
            fn(command, code_action_params)
        else
            M.execute_command(command)
        end
    end)
end


-- Until https://github.com/neovim/neovim/pull/11927 is merged
local function apply_text_document_edit(edit)
    local text_document = edit.textDocument
    local bufnr = vim.uri_to_bufnr(text_document.uri)
    if M.ticks[bufnr] > text_document.version then
        print("Buffer ", text_document.uri, " newer than edits.")
        return
    end
    vim.lsp.util.apply_text_edits(edit.edits, bufnr)
end


function M.workspace_symbol()
    local query = vim.fn.input("Symbol: ")
    local params = {
        query = query
    }
    local bufnr = api.nvim_get_current_buf()
    vim.lsp.buf_request(bufnr, 'workspace/symbol', params, function(err, _, result)
        if err then return end
        if not result then
            print("No symbols matching " .. query .. " found")
        end
        local items = {}
        for _, s in ipairs(result) do
            if not isJdtLinkLocation(s.location) then
                table.insert(items, {
                    filename = vim.uri_to_fname(s.location.uri),
                    lnum = s.location.range.start.line + 1,
                    vcol = 1,
                    col = s.location.range.start.character + 1,
                    text = s.name
                })
            end
        end
        vim.fn.setqflist({}, ' ', {
            title = 'Workspace Symbols';
            items = items;
        })
        api.nvim_command("copen")
        api.nvim_command("wincmd p")
    end)
end


function M.setup(client)
    local signature_triggers = client.resolved_capabilities.signature_help_trigger_characters
    if signature_triggers and #signature_triggers > 0 then
        table.insert(
            on_insert_with_pause, { signature_triggers, vim.lsp.buf.signature_help }
        )
    end
    local completionProvider = client.server_capabilities.completionProvider or {}
    local completion_triggers = completionProvider.triggerCharacters
    if completion_triggers and #completion_triggers > 0 then
        table.insert(
            on_insert_with_pause, { completion_triggers, trigger_completion }
        )
    end
    vim.lsp.util.text_document_completion_list_to_complete_items = text_document_completion_list_to_complete_items

    -- Until https://github.com/neovim/neovim/pull/11927 is merged
    vim.lsp.util.apply_text_document_edit = apply_text_document_edit
end

return M
