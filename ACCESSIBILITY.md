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

  * Main window: not yet checked.
  * VM window: not yet checked.
  * Build, build progress, checks, log, security findings: not yet checked.
  * Password, recovery keys, restore, removal, question, reason: not yet checked.

### 200% text size and 400% zoom

Nothing cut off or overlapping, and no horizontal scrolling in a list.

  * Not yet checked.

### High Contrast

Everything uses system colors, and no state is shown by color alone.

  * Not yet checked.
