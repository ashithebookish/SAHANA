"""Offline API reference with the SAHANA brand assets."""

from html import escape
from pathlib import Path


ASSETS = Path(__file__).resolve().parent.parent / "caregiver/Sources/Caregiver/Resources"
LOGO = ASSETS / "SAHANA-emblem.png"
WORDMARK = ASSETS / "SAHANA-wordmark.png"
DOC_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
}


CAMERA_TEST_HEADERS = {
    "Cache-Control": "no-store, private",
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; connect-src 'self'; img-src 'self' blob:; "
        "media-src 'self' blob:; style-src 'unsafe-inline'; form-action 'none'; "
        "base-uri 'none'; frame-ancestors 'none'"
    ),
    "Permissions-Policy": "camera=(self), microphone=(), geolocation=()",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
}


def reference(schema, mode, base_url, *, camera_test=False):
    methods = {"get", "post", "put", "patch", "delete"}
    groups = {}
    for path, operations in schema["paths"].items():
        for method, operation in operations.items():
            if method in methods:
                group = operation.get("tags", ["API"])[0]
                description = operation.get("description") or operation["summary"]
                groups.setdefault(group, []).append(
                    f'<tr><th scope="row"><span class="verb {method}">{method.upper()}</span>'
                    f'<code>{escape(path)}</code></th><td>{escape(description)}</td></tr>'
                )
    sections = "".join(
        f"<section><h2>{escape(name)}</h2><table><thead><tr><th scope=\"col\">Endpoint</th>"
        f'<th scope="col">Purpose</th></tr></thead><tbody>{"".join(rows)}</tbody></table></section>'
        for name, rows in groups.items()
    )
    command = (
        f"""curl -H 'Authorization: Bearer YOUR_LOCAL_TOKEN' {base_url}/people"""
        if mode == "live" else f"curl {base_url}/people"
    )
    access = (
        "Send the bearer token from your launcher to care and camera endpoints."
        if mode == "live" else "This instance contains synthetic profiles and uses a controllable clock."
    )
    camera_link = '<a href="/camera-test">Camera test</a>' if camera_test else ""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" type="image/png" href="/logo.png"><title>SAHANA API</title>
<style>
:root {{ color-scheme:dark; font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;
  color:#f6eddc; background:#091a2c; }}
* {{ box-sizing:border-box; }}
body {{ margin:0; line-height:1.55; }}
header {{ border-bottom:1px solid #2a4964; }}
.header-body {{ max-width:70rem; margin:auto; padding:1.35rem clamp(1rem,4vw,2.5rem);
  text-align:center; }}
.header-marks {{ display:grid; grid-template-columns:var(--emblem) minmax(0,1fr) var(--emblem);
  --emblem:clamp(3rem,14vw,8.75rem); align-items:center; gap:clamp(.45rem,2vw,1.25rem); }}
.emblem {{ display:block; width:100%; height:auto; }}
.wordmark-filter {{ position:absolute; width:0; height:0; }}
.wordmark {{ justify-self:center; width:min(100%,28.5rem); }}
.wordmark img {{ display:block; width:100%; height:auto; filter:url(#wordmark-gold); }}
h1 {{ margin:.55rem 0 .2rem; font:600 clamp(2rem,6vw,3.1rem) Georgia,serif; }}
header p {{ margin:.3rem; }}
nav {{ margin-top:1rem; }}
a {{ color:#ffd375; text-underline-offset:.2em; }}
a + a {{ margin-left:1rem; }}
main {{ max-width:70rem; margin:auto; padding:1.5rem clamp(1rem,4vw,2.5rem) 4rem; }}
section {{ margin-top:1.7rem; background:#11273c; border:1px solid #2a4964; border-radius:1rem; padding:1.2rem; }}
h2 {{ margin:0 0 .75rem; font-size:1.3rem; }}
p {{ margin:.6rem 0; }}
pre {{ overflow:auto; padding:.7rem; border-radius:.5rem; background:#081928; }}
table {{ width:100%; border-collapse:collapse; text-align:left; }}
th, td {{ padding:.65rem .55rem; border-bottom:1px solid #2a4964; text-align:left; }}
th {{ font-weight:600; }}
td {{ color:#d2e2eb; }}
code {{ overflow-wrap:anywhere; }}
.verb {{ display:inline-block; min-width:4rem; margin-right:.45rem; border-radius:.25rem; padding:.06rem .25rem;
  font-size:.75rem; color:#b2d1e2; }}
.post,.patch,.put,.delete {{ color:#ffd375; }}
@media (max-width:35rem) {{ th,td {{ padding:.45rem .2rem; }} .verb {{display:block;}} }}
</style></head>
<body>
<svg class="wordmark-filter" aria-hidden="true" focusable="false" xmlns="http://www.w3.org/2000/svg">
<defs><filter id="wordmark-gold" color-interpolation-filters="sRGB">
<feColorMatrix type="matrix" values="
  0 0 0 0 .94902
  0 0 0 0 .70980
  0 0 0 0 .23137
  -.27638 -.92976 -.09386 1.15 0"/>
</filter></defs></svg>
<header><div class="header-body">
<div class="header-marks"><img class="emblem" src="/logo.png" width="1254" height="1254" alt="">
<div class="wordmark"><img src="/wordmark.png" width="1920" height="540" alt="SAHANA"></div></div>
<h1>SAHANA API</h1>
<p>Care coordination, patient profiles, and the local camera.</p>
<nav><a href="/openapi.json">OpenAPI schema</a><a href="/status">Service status</a>{camera_link}</nav>
</div></header>
<main><section><h2>Connect to SAHANA</h2>
<p>{access} Times use Asia/Shanghai (UTC+8).</p><pre><code>{escape(command)}</code></pre></section>
{sections}</main></body></html>"""
