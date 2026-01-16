; Inject code cell content using language from buffer variable (set by plugin)
; Uses custom #inject-notebook-language! directive registered in init.lua
((code_cell
  (cell_content) @injection.content)
  (#inject-notebook-language!)
  (#set! injection.include-children))

; Inject Markdown into markdown cells
((markdown_cell
  (cell_content) @injection.content)
  (#set! injection.language "markdown")
  (#set! injection.include-children))

; Raw cells get no injection (plain text)
