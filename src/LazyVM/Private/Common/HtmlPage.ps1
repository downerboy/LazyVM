# The shell of every LazyVM web page (#375, first used by LazyVM Findings.html,
# #367): its look, its copy buttons, and the page around the content, in
# one place. Sections can alternate dark and light blue; every colour pair
# has a contrast of at least 7:1. The script copies the text of the <code>
# a button names (button[data-copy]) and says what it copied in the page's
# #copied status line, which a screen reader reads out.
$script:HtmlPageStyle = @'
body { font-family: "Segoe UI", sans-serif; font-size: 1.05rem; line-height: 1.5; margin: 0; padding: 1rem 2rem; color: #10233f; background: #ffffff; }
h1 { font-size: 1.6rem; }
h2 { font-size: 1.25rem; margin-top: 0; }
.finding { border-radius: 6px; padding: 1rem 1.25rem; margin: 1rem 0; }
.finding.dark { background: #0b2e59; color: #ffffff; }
.finding.light { background: #dcebfa; color: #10233f; }
dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.35rem 1rem; margin: 0 0 1rem 0; }
dt { font-weight: 600; }
dd { margin: 0; }
code { font-family: Consolas, monospace; background: #ffffff; color: #10233f; padding: 0.15rem 0.35rem; border-radius: 3px; word-break: break-all; }
button { font: inherit; padding: 0.3rem 0.9rem; margin-left: 0.5rem; border-radius: 4px; border: 2px solid #10233f; background: #ffd75e; color: #10233f; cursor: pointer; }
button:focus-visible { outline: 3px solid #ffd75e; outline-offset: 2px; }
#copied { font-weight: 600; min-height: 1.5em; }
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
    function say(text, copied) {
        status.textContent = copied ? 'Copied: ' + text : 'Could not copy. Select the command and press Ctrl+C: ' + text;
    }
    var buttons = document.querySelectorAll('button[data-copy]');
    for (var i = 0; i < buttons.length; i++) {
        buttons[i].addEventListener('click', function (e) {
            var code = document.getElementById(e.currentTarget.getAttribute('data-copy'));
            var text = code.textContent;
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(function () { say(text, true); }, function () { say(text, selectAndCopy(code)); });
            }
            else {
                say(text, selectAndCopy(code));
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
      A web page: English, UTF-8, a title and one h1 (both $Title, as text),
      $Body inside main, and a policy that lets it load nothing from
      anywhere. With -WithCopyScript the page also carries the copy-button
      script, for a page that has button[data-copy] buttons and a #copied
      status line. Lines end in CRLF, as on every file LazyVM writes.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Title,
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
    $html.Add('<main>')
    $html.Add("<h1>$heading</h1>")
    $html.AddRange($Body)
    $html.Add('</main>')
    if ($WithCopyScript) { $html.Add("<script>`n$script:HtmlPageCopyScript`n</script>") }
    $html.Add('</body>')
    $html.Add('</html>')
    return (($html -join "`n") + "`n").Replace("`r`n", "`n").Replace("`n", "`r`n")
}
