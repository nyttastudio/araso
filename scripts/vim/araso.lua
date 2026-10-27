-- Tells Araso which mode neovim is in, so that every normal-mode key goes straight to neovim,
-- Esc always reaches it, and words are decided only in insert mode.
-- Put this file in ~/.config/nvim/plugin/ (or require it from init.lua). Vim: araso.vim.
local araso
local windows = vim.fn.has('win32') == 1
local linux = vim.fn.has('unix') == 1 and vim.fn.has('mac') == 0
local candidates = windows and { (vim.env.ProgramFiles or 'C:\\Program Files') .. '\\Araso\\ArasoHost.exe' }
  or linux and { '/usr/bin/araso-settings' }
  or { vim.fn.expand('~/Library/Input Methods') .. '/Araso.app/Contents/MacOS/Araso',
       '/Library/Input Methods/Araso.app/Contents/MacOS/Araso' }
for _, path in ipairs(candidates) do
  if vim.fn.executable(path) == 1 then
    araso = path
    break
  end
end
if not araso then return end

-- The app neovim runs in, so the mode reaches that app's text field and no other: macOS gives every
-- app's processes its bundle identifier; on Windows and Linux it is the terminal's program name,
-- from ARASO_APP or what the terminal tells its shells (none: taken where Esc isn't a switch key).
local function windowsApp()
  if vim.env.ARASO_APP then return vim.env.ARASO_APP end
  if vim.env.WT_SESSION then return 'windowsterminal.exe' end
  local program = (vim.env.TERM_PROGRAM or ''):lower()
  if program == 'vscode' then return 'code.exe' end
  if program == 'wezterm' then return 'wezterm-gui.exe' end
  return ''
end
-- On Linux, the name fcitx5 knows the terminal by (its program's).
local function linuxApp()
  if vim.env.ARASO_APP then return vim.env.ARASO_APP end
  if vim.env.KITTY_WINDOW_ID then return 'kitty' end
  if vim.env.ALACRITTY_WINDOW_ID then return 'alacritty' end
  if vim.env.KONSOLE_VERSION then return 'konsole' end
  if vim.env.GHOSTTY_RESOURCES_DIR then return 'ghostty' end
  local program = (vim.env.TERM_PROGRAM or ''):lower()
  if program == 'vscode' then return 'code' end
  if program == 'wezterm' then return 'wezterm-gui' end
  if vim.env.VTE_VERSION then return 'gnome-terminal-server' end
  return ''
end
local app = windows and windowsApp() or linux and linuxApp() or (vim.env.__CFBundleIdentifier or '')

local function tell(mode)
  -- Detached, so the last word still goes out when neovim is quitting.
  vim.fn.jobstart({ araso, '--vim', mode, '--app', app }, { detach = true })
end

local function current()
  local mode = vim.api.nvim_get_mode().mode
  return (mode:find('^[iR]') and 'insert') or 'normal'
end

local group = vim.api.nvim_create_augroup('Araso', { clear = true })
local function on(events, mode)
  vim.api.nvim_create_autocmd(events, {
    group = group,
    callback = function() tell(type(mode) == 'function' and mode() or mode) end,
  })
end

on('InsertEnter', 'insert')
on({ 'InsertLeave', 'VimEnter', 'VimResume' }, 'normal')
on('FocusGained', current)
-- Whatever is in front next (a shell in another pane) isn't neovim.
on({ 'VimLeavePre', 'VimSuspend', 'FocusLost' }, 'off')
