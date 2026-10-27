" Tells Araso which mode Vim is in, so that every normal-mode key goes straight to Vim, Esc
" always reaches it, and words are decided only in insert mode.
" Put this file in ~/.vim/plugin/ (Vim 8.2 or later, with +job). Neovim: araso.lua.
if exists('g:loaded_araso') || !has('job') || has('nvim')
  finish
endif
let g:loaded_araso = 1

let s:araso = ''
let s:linux = has('unix') && !has('mac') && !has('macunix')
if has('win32')
  let s:candidates = [(exists('$ProgramFiles') ? $ProgramFiles : 'C:\Program Files') . '\Araso\ArasoHost.exe']
elseif s:linux
  let s:candidates = ['/usr/bin/araso-settings']
else
  let s:candidates = [expand('~/Library/Input Methods') . '/Araso.app/Contents/MacOS/Araso',
        \ '/Library/Input Methods/Araso.app/Contents/MacOS/Araso']
endif
for s:path in s:candidates
  if executable(s:path)
    let s:araso = s:path
    break
  endif
endfor
if empty(s:araso)
  finish
endif

" The app Vim runs in, so the mode reaches that app's text field and no other: macOS gives every
" app's processes its bundle identifier; on Windows and Linux it is the terminal's program name,
" from ARASO_APP or what the terminal tells its shells (none: taken where Esc isn't a switch key).
function! s:WindowsApp() abort
  if exists('$ARASO_APP') | return $ARASO_APP | endif
  if exists('$WT_SESSION') | return 'windowsterminal.exe' | endif
  let l:program = tolower(exists('$TERM_PROGRAM') ? $TERM_PROGRAM : '')
  if l:program ==# 'vscode' | return 'code.exe' | endif
  if l:program ==# 'wezterm' | return 'wezterm-gui.exe' | endif
  return ''
endfunction
" On Linux, the name fcitx5 knows the terminal by (its program's).
function! s:LinuxApp() abort
  if exists('$ARASO_APP') | return $ARASO_APP | endif
  if exists('$KITTY_WINDOW_ID') | return 'kitty' | endif
  if exists('$ALACRITTY_WINDOW_ID') | return 'alacritty' | endif
  if exists('$KONSOLE_VERSION') | return 'konsole' | endif
  if exists('$GHOSTTY_RESOURCES_DIR') | return 'ghostty' | endif
  let l:program = tolower(exists('$TERM_PROGRAM') ? $TERM_PROGRAM : '')
  if l:program ==# 'vscode' | return 'code' | endif
  if l:program ==# 'wezterm' | return 'wezterm-gui' | endif
  if exists('$VTE_VERSION') | return 'gnome-terminal-server' | endif
  return ''
endfunction
let s:app = has('win32') ? s:WindowsApp() : s:linux ? s:LinuxApp()
      \ : (exists('$__CFBundleIdentifier') ? $__CFBundleIdentifier : '')

function! s:Tell(mode) abort
  " Not stopped when Vim exits, so the last word still goes out when quitting.
  call job_start([s:araso, '--vim', a:mode, '--app', s:app], {'stoponexit': ''})
endfunction

function! s:Current() abort
  return mode() =~# '^[iR]' ? 'insert' : 'normal'
endfunction

augroup Araso
  autocmd!
  autocmd InsertEnter * call s:Tell('insert')
  autocmd InsertLeave,VimEnter * call s:Tell('normal')
  autocmd FocusGained * call s:Tell(s:Current())
  " Whatever is in front next (a shell in another pane) isn't Vim.
  autocmd VimLeavePre,FocusLost * call s:Tell('off')
  if exists('##VimResume')
    autocmd VimResume * call s:Tell('normal')
    autocmd VimSuspend * call s:Tell('off')
  endif
augroup END
