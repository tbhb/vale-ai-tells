# Hard-wrap the ordinary paragraph lines of a Markdown file to a line width
# of WIDTH characters and leave every structural line alone. The copy
# differs from the source in its line breaks and in nothing else.
#
# `mise run test-wrapped` feeds the tell corpus through this and compares
# the result with the flat original. Vale joins the lines of a block before
# a rule runs. The newline the author typed stays in the text it hands over.
# A token that spells the gap between two words as a literal space stops
# matching once a wrap falls between them. Every token now spells it `\s+`,
# and this recipe proves that.
#
# Headings, list items, block quotes, tables, fenced and indented code, link
# definitions, and thematic breaks pass through untouched: rewrapping any of
# them would change the structure Vale parses rather than the line breaks
# inside a paragraph, which would make the comparison measure the wrong
# thing.
#
# Usage: awk -v WIDTH=40 -f tools/wrap-paragraphs.awk input.md > output.md

BEGIN {
  if (WIDTH == 0) WIDTH = 40
  fenced = 0
}

{
  line = $0

  if (line ~ /^[ \t]*(```|~~~)/) { fenced = !fenced; print line; next }
  if (fenced) { print line; next }

  if (line ~ /^[ \t]*$/ ||
      line ~ /^[ \t]*#/ ||
      line ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ ||
      line ~ /^[ \t]*>/ ||
      line ~ /^[ \t]*\|/ ||
      line ~ /^[ \t]*</ ||
      line ~ /^[ \t]*\[[^]]+\]:/ ||
      line ~ /^(    |\t)/ ||
      line ~ /^[ \t]*(-{3,}|={3,}|\*{3,}|_{3,})[ \t]*$/ ||
      length(line) <= WIDTH) { print line; next }

  words = split(line, word, / /)
  out = ""
  for (i = 1; i <= words; i++) {
    if (out == "")
      out = word[i]
    else if (length(out) + 1 + length(word[i]) <= WIDTH)
      out = out " " word[i]
    else {
      print out
      out = word[i]
    }
  }
  if (out != "") print out
}
