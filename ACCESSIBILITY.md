# Accessibility

I am legally blind and I need tools to let me do what I need to do with the 
same ease as before.  Accessibly and ease of use is the motivation of of 
LazyVM.

## Priorities

A tool to make using tools that aren't very accessible, accessible. 

## Contributor expectations

  * There are mounds of excellent resources.
  * Watch real users review products and give tutorials
    on using the various tools and demonstrate the many different use-cases.

## Reporting accessibility issues

For now post an issue.

### Severity

Every issue reported has gets the highest serverity level.
The user has to be able this product without having to exert an more
effort than any other user.  
Being a user, I find it to be backhanded behavior, never
receiving a response nor see the issue addressed.  

### How we respond

The reported issue is addressed first thing.

## Ownership and maintenance

I am having to use a screen reader just to develop the project...

## Supported environments

Supports Windows.

## Known limitations

I cannot know its limitations unless a limitation is brought 
to my attention.  Everyone has different limitations.

## Feedback and improvements

Submit an issue.

## Findings of the accessibility pass (#502)

The automated checks run with the tests (`AccessibilityXamlTests`): every input
control has a name, every button has text or a name, tab order follows the
layout (no `TabIndex`), every window but the main one closes with Escape, and
the windows and styles take their colors from the theme tokens, which the
light, dark and High Contrast themes all define (High Contrast from system
colors only).

The checks below are done by hand. Record the date, the build and what was
found; each problem becomes its own issue.

### Narrator

Each window: every control has a name and, where it helps, help text; the
reading order follows the layout; changes are announced once.

  * Main window (the Dashboard): checked 2026-11-21 with Narrator on Windows,
    build 6.40.0. Narrator worked well; no problems found.
  * Log: checked 2026-11-21 with Narrator on Windows, build 6.40.0. Narrator
    worked well; no problems found.
  * VM window, build, build progress, checks, security findings, password,
    recovery keys, restore, removal, question, reason: checked 2026-11-21 with
    Narrator on Windows. Narrator worked well; no problems found.

### 200% text size and 400% zoom

Nothing cut off or overlapping, and no horizontal scrolling in a list.

  * Checked 2026-11-21 on screenshots of every window with sample data, laid
    out in 640 by 450 units (200%) and 320 by 225 units (400%), the size a
    1280 wide screen leaves at that zoom. It found problems, not yet fixed:
    * Main window: at 200% the list of VMs is squeezed to a sliver, and at 400%
      the title breaks one letter per line and the list is gone. The window
      does not scroll.
    * VM window: at 200% the VM's name and state break one letter per line
      beside the buttons.
    * Question window: at 200% the No button runs off the right edge.
    * The log and checks windows were captured before their lists loaded, so
      their lists are not yet checked. The other windows showed nothing cut off.
    * This is a first look with a test harness, not a hand check at a real
      200% or 400% setting; confirm each in the app.

### High Contrast

Everything uses system colors, and no state is shown by color alone.

  * Not yet checked.
