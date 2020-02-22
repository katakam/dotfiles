local diagnostics = require 'lsp-diagnostics'
local myutil = require 'util'
local lsp = require 'vim.lsp'
local api = vim.api
local lsps_dirs = {}

local function add_client_by_cfg(config, root_markers)
    local bufnr = api.nvim_get_current_buf()
    local root_dir = myutil.root_pattern(bufnr, root_markers)
    if not root_dir then return end

    local cmd = config.cmd[1]
    if tonumber(vim.fn.executable(cmd)) == 0 then
        api.nvim_command(string.format(
            ':echohl WarningMsg | redraw | echo "No LSP executable: %s" | echohl None', cmd))
        return
    end
    config['root_dir'] = root_dir
    local client_id = lsps_dirs[root_dir]
    if not client_id then
        client_id = lsp.start_client(config)
        lsps_dirs[root_dir] = client_id
    end
    lsp.buf_attach_client(bufnr, client_id)
end

local function enable_mappings_on_buffer(client, bufnr)
    api.nvim_buf_set_var(bufnr, "lsp_client_id", client.id)
    api.nvim_buf_set_option(bufnr, "omnifunc", "v:lua.vim.lsp.omnifunc")
    api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
    -- Can't set this via nvim_buf_set_option ?
    api.nvim_command("setlocal signcolumn=yes")
    api.nvim_command('ALEDisableBuffer')

    local function set_keymap(lhs, rhs)
        api.nvim_buf_set_keymap(bufnr, "n", lhs, rhs, { silent = true; })
    end
    set_keymap("gd", "<Cmd>lua vim.lsp.buf.declaration()<CR>")
    set_keymap("<c-]>", "<Cmd>lua vim.lsp.buf.definition()<CR>")
    set_keymap("1gD", "<Cmd>lua vim.lsp.buf.definition()<CR>")
    set_keymap("gD", "<Cmd>lua vim.lsp.buf.implementation()<CR>")
    set_keymap("K", "<Cmd>lua vim.lsp.buf.hover()<CR>")
    set_keymap("gr", "<Cmd>lua vim.lsp.buf.references()<CR>")
    set_keymap("<a-CR>", "<Cmd>lua vim.lsp.buf.code_action()<CR>")
    set_keymap("crr", "<Cmd>lua vim.lsp.buf.rename()<CR>")
    set_keymap("gq", "<Cmd>lua vim.lsp.buf.formatting()<CR>")
    api.nvim_buf_set_keymap(bufnr, "v", "gq", "<Cmd>lua vim.lsp.buf.range_formatting()<CR>", { silent = true; })
    api.nvim_buf_set_keymap(bufnr, "i", "<c-space>", "<Cmd>lua vim.lsp.buf.signature_help()<CR>", { silent = true; })
end

local function mk_config()
    return {
        callbacks = {
            ["textDocument/publishDiagnostics"] = diagnostics.publishDiagnostics;
        };
        on_attach = enable_mappings_on_buffer;
    }
end

local M = {}
function M.add_client(cmd, opts)
    local config = mk_config()
    config['name'] = opts and opts.name or cmd[1]
    config['cmd'] = cmd
    add_client_by_cfg(config, opts and opts.root or {'.git'})
end
function M.start_jdt()
    local lsp4j_status_callback = vim.schedule_wrap(function(_, _, result)
        api.nvim_command(string.format(':echohl Function | echo "%s" | echohl None', result.message))
    end)
    local config = mk_config()
    config['name'] = 'eclipse.jdt.ls'
    config['cmd'] = {'java-lsp.sh'}
    config['callbacks']["language/status"] = lsp4j_status_callback
    add_client_by_cfg(config, {'gradlew', '.git'})
end
function M.start_hie()
    local config = mk_config()
    config['name'] = 'hie'
    config['cmd'] = {'hie-wrapper', '--lsp'}
    config['init_options'] = {
        languageServerHaskell = {
            formattingProvider = "ormolu";
        }
    }
    add_client_by_cfg(config, {'stack.yml', '.git'})
end
function M.start_go_ls()
    local path = os.getenv("GOPATH") .. "/bin/go-langserver"
    M.add_client({path, '-gocodecompletion'}, {name = 'gols'})
end

--- @export
return M
