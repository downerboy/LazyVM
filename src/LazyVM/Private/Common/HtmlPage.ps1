# The shell of every LazyVM web page (#375, first used by LazyVM Findings.html,
# #367), in the look of the brand spec (LazyVM-Brand.md, #377): a navy header
# bar, white cards with a stripe and badge in the severity's colour, one
# yellow button style, light and dark themes, rem sizes that hold at 400%
# zoom. Colour never works alone: severities also differ in shape and word.
# The script copies the text of the <code> a button names (button[data-copy]),
# says "Copied" in the page's #copied status line, which a screen reader
# reads out, and puts the button's label back after two seconds.
$script:HtmlPageStyle = @'
:root {
  --lv-navy:#0B2E59; --lv-ink:#13223F; --lv-ink-muted:#475467;
  --lv-page:#F5F8FC; --lv-card:#FFFFFF; --lv-card-border:#C9D6E5; --lv-tint:#DCEAF8; --lv-code:#FFFFFF;
  --lv-accent:#FFD75E; --lv-accent-hover:#FFC929; --lv-on-accent:#0B2E59;
  --lv-sev-high:#B42318; --lv-sev-medium:#B54708; --lv-sev-low:#175CD3; --lv-sev-info:#475467; --lv-on-sev:#FFFFFF;
  --lv-chip-new:#0B2E59; --lv-on-chip-new:#FFFFFF; --lv-chip-open:#DCEAF8; --lv-on-chip-open:#0B2E59;
  --lv-chip-resolved:#E7F4EC; --lv-on-chip-resolved:#05603A;
  --lv-font:"Segoe UI",system-ui,sans-serif; --lv-mono:"Cascadia Mono",Consolas,monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --lv-page:#0A1628; --lv-card:#10223D; --lv-card-border:#2A4468; --lv-tint:#16304F; --lv-code:#0A1628;
    --lv-ink:#E6EDF5; --lv-ink-muted:#A9B8CC;
    --lv-sev-high:#F97066; --lv-sev-medium:#FDB022; --lv-sev-low:#84ADFF; --lv-sev-info:#A9B8CC; --lv-on-sev:#0A1628;
    --lv-chip-new:#84ADFF; --lv-on-chip-new:#0A1628; --lv-chip-open:#16304F; --lv-on-chip-open:#E6EDF5;
    --lv-chip-resolved:#0F3D2A; --lv-on-chip-resolved:#A6E8C4;
  }
}
* { box-sizing: border-box; }
body { margin: 0; font-family: var(--lv-font); font-size: 1rem; line-height: 1.5; color: var(--lv-ink); background: var(--lv-page); }
header { background: var(--lv-navy); color: #FFFFFF; padding: 1.5rem; }
header > * { max-width: 60rem; margin-left: auto; margin-right: auto; }
h1 { font-size: 1.75rem; font-weight: 700; line-height: 1.25; margin: 0; }
.subtitle { color: #C9D6E5; margin-top: 0.25rem; margin-bottom: 0; }
main { max-width: 60rem; margin: 0 auto; padding: 1.5rem; }
h2 { font-size: 1.25rem; font-weight: 700; line-height: 1.25; margin: 0 0 1rem 0; }
.summary { background: var(--lv-tint); border-radius: 0.5rem; padding: 1.5rem; margin-bottom: 1rem; }
.summary > :first-child { margin-top: 0; }
.summary > :last-child { margin-bottom: 0; }
.finding { background: var(--lv-card); border: 1px solid var(--lv-card-border); border-left: 6px solid var(--lv-sev-info); border-radius: 0.5rem; padding: 1.5rem; margin-bottom: 1rem; }
.finding.high { border-left-color: var(--lv-sev-high); }
.finding.medium { border-left-color: var(--lv-sev-medium); }
.finding.low { border-left-color: var(--lv-sev-low); }
.finding.info { border-left-color: var(--lv-sev-info); }
.badge { display: inline-block; border-radius: 0.25rem; padding: 0.125rem 0.5rem; color: var(--lv-on-sev); background: var(--lv-sev-info); font-size: 1rem; }
.badge.high { background: var(--lv-sev-high); }
.badge.medium { background: var(--lv-sev-medium); }
.badge.low { background: var(--lv-sev-low); }
.badge.info { background: var(--lv-sev-info); }
.chip { display: inline-block; border-radius: 0.25rem; padding: 0.125rem 0.5rem; }
.chip.new { background: var(--lv-chip-new); color: var(--lv-on-chip-new); }
.chip.still-open { background: var(--lv-chip-open); color: var(--lv-on-chip-open); }
.chip.resolved { background: var(--lv-chip-resolved); color: var(--lv-on-chip-resolved); }
dl { display: grid; grid-template-columns: 10rem 1fr; gap: 0.5rem 1rem; margin: 0 0 1rem 0; }
dt { font-weight: 600; }
dd { margin: 0; overflow-wrap: anywhere; }
.command { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; margin: 0.5rem 0; }
code { font-family: var(--lv-mono); font-size: 0.9375rem; background: var(--lv-code); color: var(--lv-ink); border: 1px solid var(--lv-card-border); border-radius: 0.25rem; padding: 0.5rem 0.75rem; overflow-wrap: anywhere; }
.command code { flex: 1 1 20rem; min-width: 0; }
button { font: inherit; background: var(--lv-accent); color: var(--lv-on-accent); border: 2px solid var(--lv-navy); border-radius: 0.375rem; padding: 0.375rem 1rem; min-width: 2.75rem; min-height: 2.75rem; cursor: pointer; }
button:hover, button:active { background: var(--lv-accent-hover); }
button:focus-visible { outline: 3px solid var(--lv-navy); outline-offset: 2px; }
#copied { font-weight: 600; min-height: 1.5em; margin: 0.5rem 0 0 0; }
@media (max-width: 40rem) { dl { grid-template-columns: 1fr; gap: 0.125rem; } dd { margin-bottom: 0.5rem; } }
@media (prefers-color-scheme: dark) { button:focus-visible { outline-color: #FFFFFF; } button { border-color: #FFFFFF; } }
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; scroll-behavior: auto !important; } }
@media (forced-colors: active) { .finding { border-left-color: CanvasText; } .badge, .chip, button, code { border: 1px solid ButtonText; } }
'@

$script:HtmlPageCopyScript = @'
(function () {
    var status = document.getElementById('copied');
    function selectAndCopy(code) {
        var range = document.createRange();
        range.selectNodeContents(code);
        var selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        var copied = document.execCommand('copy');
        selection.removeAllRanges();
        return copied;
    }
    function say(button, text, copied) {
        if (!copied) {
            status.textContent = 'Could not copy. Select the command and press Ctrl+C: ' + text;
            return;
        }
        status.textContent = 'Copied';
        var label = button.getAttribute('data-label') || button.textContent;
        button.setAttribute('data-label', label);
        button.textContent = 'Copied';
        window.setTimeout(function () { button.textContent = label; }, 2000);
    }
    var buttons = document.querySelectorAll('button[data-copy]');
    for (var i = 0; i < buttons.length; i++) {
        buttons[i].addEventListener('click', function (e) {
            var button = e.currentTarget;
            var code = document.getElementById(button.getAttribute('data-copy'));
            var text = code.textContent;
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(function () { say(button, text, true); }, function () { say(button, text, selectAndCopy(code)); });
            }
            else {
                say(button, text, selectAndCopy(code));
            }
        });
    }
}());
'@

function ConvertTo-HtmlText {
    <# $Text as HTML text: the characters markup is made of are written as entities, so text from the VM is shown, never run. #>
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$Text)

    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function New-HtmlPage {
    <#
      A web page: English, UTF-8, a title and one h1 in the header bar (both
      $Title, as text, with $Subtitle, if any, under the h1), $Body inside
      main, and a policy that lets it load nothing from
      anywhere. With -WithCopyScript the page also carries the copy-button
      script, for a page that has button[data-copy] buttons and a #copied
      status line. Lines end in CRLF, as on every file LazyVM writes.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Subtitle,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Body,
        [switch]$WithCopyScript
    )

    $heading = ConvertTo-HtmlText $Title
    $html = [System.Collections.Generic.List[string]]::new()
    $html.Add('<!DOCTYPE html>')
    $html.Add('<html lang="en">')
    $html.Add('<head>')
    $html.Add('<meta charset="utf-8">')
    $html.Add("<meta http-equiv=`"Content-Security-Policy`" content=`"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'`">")
    $html.Add("<title>$heading</title>")
    $html.Add("<style>`n$script:HtmlPageStyle`n</style>")
    $html.Add('</head>')
    $html.Add('<body>')
    $html.Add('<header>')
    $html.Add("<h1>$heading</h1>")
    if ($Subtitle) { $html.Add("<p class=`"subtitle`">$(ConvertTo-HtmlText $Subtitle)</p>") }
    $html.Add('</header>')
    $html.Add('<main>')
    $html.AddRange($Body)
    $html.Add('</main>')
    if ($WithCopyScript) { $html.Add("<script>`n$script:HtmlPageCopyScript`n</script>") }
    $html.Add('</body>')
    $html.Add('</html>')
    return (($html -join "`n") + "`n").Replace("`r`n", "`n").Replace("`n", "`r`n")
}
