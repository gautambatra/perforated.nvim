I want to create a highly performant, feature-rich, user-friendly and intuitive perforce integration plugin for neovim.
It will be called perforated.nvim 

# Features
* Check-out file on edit 
    * By default, it will ask if user wants to check out with these options:
        * If user just presses enter - check-out to default changelist (CL)
        * Other options: add to existing CL or create new CL
    * Option to automatically checkout on write
* Check for stale and unresolved files in the workspace - option to check only checked out files
* View file history - in a floating window, telescope (or other fuzzy finder), or quickfix list (configurable)
* View p4 annotate
* Diffs
    * View diffs of currently file wrt depot - this is the default diff
    * View diffs of all checked-out files (or choose which files)
    * View diffs of shelved files
    * View diffs wrt a specific revision
* View Pending CLs and the files in them with revision numbers (including shelved files)
* View Submitted CLs
* View submitted CLs of a specific user
* Lookup any CL by number and optionally be able see the diffs
* Shelve/unshelve files - at file level and CL level
* Resolve any unresolved files - with the ability to open the interactive perforce merge to resolve conflicts if needed
* Gutter signs with ability to jump to next chunk
* Should detect the perforce environment variables and config files, eg: .p4Config, $P4USER, etc.
* In my opinion, there should be "ui mode" or a "client view" which opens either as a pop-up or a separate tab where user can interactively see their CLs, files, diffs, histories, etc - kind of like a p4v inside neovim
* Most operations should be available via commands as well
    * All commands start with :P4
    * Command names should be similar to the actual perforce commands, eg. :P4edit for `p4 edit`
* Nice to have: time-lapse view

# Non-negotiables
* Every option should be lightning-fast - minimal lag
* Must be extremely lightweight in terms of memory usage
* All transitions and operations must feel really smooth
* Must be highly-performant on code bases with millions of lines


# Your task
* Come up with a detailed milestone-based plan for implementing this, with details about the design, implementation, testing
* Get design ideas from existing git and perforce integration plugins for vim, neovim, and emacs - do a deep search and come up with suggestions
* Interview me relentlessly until we are on the same page
    * Let's converge on the design and usage aspect first
