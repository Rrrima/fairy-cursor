#!/bin/bash
# turn a release's notes (the few bits of markdown they use: paragraphs, "- " lists, `code`)
# into the html the update window shows. reads stdin, writes stdout.
# the "already have fairy cursor? download it again" line is dropped: the reader is updating.
set -euo pipefail
tr -d '\r' | awk '
  function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
  function code(s,   out) {
    out = ""
    while (match(s, /`[^`]+`/)) {
      out = out substr(s, 1, RSTART - 1) "<code>" substr(s, RSTART + 1, RLENGTH - 2) "</code>"
      s = substr(s, RSTART + RLENGTH)
    }
    return out s
  }
  function close_list() { if (inlist) { print "</ul>"; inlist = 0 } }
  BEGIN { print "<style>body{font:13px -apple-system,sans-serif;line-height:1.5;color:#1d1d1f}code{font:12px ui-monospace,Menlo,monospace;background:#f2f2f5;border-radius:4px;padding:1px 4px}ul{padding-left:18px}li{margin:4px 0}</style>" }
  tolower($0) ~ /^already have fairy cursor/ { next }
  /^[ \t]*$/ { close_list(); next }
  /^- / { if (!inlist) { print "<ul>"; inlist = 1 } print "<li>" code(esc(substr($0, 3))) "</li>"; next }
  { close_list(); print "<p>" code(esc($0)) "</p>" }
  END { close_list() }
'
