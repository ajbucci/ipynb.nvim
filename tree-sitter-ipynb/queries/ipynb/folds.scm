; Fold cell content only (markers stay visible)
; This allows folding cells while keeping execution count and outputs visible

(code_cell (cell_content) @fold)
(markdown_cell (cell_content) @fold)
(raw_cell (cell_content) @fold)
