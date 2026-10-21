# The README's hero GIF: start editing a read-only file (check out), save, the client view, a
# diff. Needs vhs, ttyd and ffmpeg (https://github.com/charmbracelet/vhs) and `make deps`.
# Run from the repository root; it resets the demo workspace first, so each take is the same:
#
#   vhs scripts/demo/hero.tape        → .deps/demo/hero.gif and hero.mp4

Output .deps/demo/hero.gif
Output .deps/demo/hero.mp4

Require ttyd
Require nvim

Set Shell bash
Set FontFamily "DejaVuSansM Nerd Font Mono"
Set FontSize 16
Set Width 1400
Set Height 760
Set Padding 16
Set Theme "tokyonight"
Set WindowBar Colorful
Set BorderRadius 8
Set TypingSpeed 45ms
Set Framerate 20 # the default 50 is more than vhs can capture at this size, so the result played too fast

# Off camera: a fresh workspace, then Neovim on a file that isn't checked out yet.
Hide
Type "export PS1='$ ' R=$PWD; scripts/demo-workspace.sh --reset >/dev/null && cd /tmp/perforated-demo/gautam_ws && clear"
Enter
Sleep 8s
Type "$R/scripts/demo/nvim.sh src/main.cpp"
Enter
Sleep 2.5s
Show

# The startup pop-up: a stale file and an unresolved one.
Sleep 2.5s

# Start typing in a read-only file: the check-out menu. <CR> takes the default changelist;
# ryan has the file open too.
Type "9G"
Sleep 500ms
Type "o"
Sleep 2.5s
Enter
Sleep 1.5s
Type `std::cout << "calc 1.1: type an expression\n";`
Escape
Sleep 1s
Type ":w"
Sleep 400ms
Enter
# The sign column marks the new line; the statusline shows the edit.
Sleep 2.5s

# The client view: changelists, the shelf, stale and unresolved files.
Type ":P4"
Sleep 400ms
Enter
Sleep 3.5s

# Down to src/parser.cpp and diff it against the depot.
Type@120ms "jjjjjjjjjjjjj"
Sleep 800ms
Type "d"
Sleep 4s
Type "]c"
Sleep 2.5s

# Back to the client view.
Type "q"
Sleep 3s
