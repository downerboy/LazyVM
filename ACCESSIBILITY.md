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
    1280 wide screen leaves at that zoom. It found two problems, now fixed
    (`ZoomLayoutTests` keep them fixed):
    * Main window: the list of VMs was squeezed to a sliver at 200%, and at
      400% the title broke one letter per line and the list was gone. The
      title now stays on one line, the buttons wrap under it, and the page
      scrolls.
    * VM window: the VM's name and state broke one letter per line beside the
      buttons, and the lower panels were cut off. The name stays on one line,
      the buttons wrap under it, and the window scrolls.
    * The other windows showed nothing cut off. The log and checks windows were
      captured before their lists loaded, so their lists are not yet checked.
    * This is a check with a test harness, not by hand at a real 200% or 400%
      setting; confirm in the app.
  * 2026-11-26 (#558): every window opens inside its screen's work area, and
    every window now scrolls when it is smaller than its content, so lists are
    not squeezed out of sight (`ScreenFitTests` and `ZoomLayoutTests`). Checked
    in the app at 300% on a 3840 by 2160 screen; the question, reason, delete
    and build progress windows were not opened.

### High Contrast

Everything uses system colors, and no state is shown by color alone.

  * Checked 2026-11-21 on screenshots of every window with sample data, taken
    with Windows High Contrast switched on. Everything takes its colors from
    the system, every button and list shows its border, and a disabled
    button is shown in the system's disabled color with its text unchanged.
    A VM that needs attention shows a diamond and the words "Needs
    attention", not a color alone. No problems found.
