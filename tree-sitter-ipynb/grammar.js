/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

module.exports = grammar({
  name: 'ipynb',

  extras: $ => [],

  externals: $ => [
    $.content_line,
    $.cell_end,
  ],

  rules: {
    notebook: $ => repeat(choice($.cell, $.blank_line)),

    blank_line: $ => /\n/,

    cell: $ => choice(
      $.code_cell,
      $.markdown_cell,
      $.raw_cell
    ),

    code_cell: $ => seq(
      '# <<ipynb_nvim:code>>',
      '\n',
      optional(alias(repeat1($.content_line), $.cell_content)),
      $.cell_end
    ),

    markdown_cell: $ => seq(
      '# <<ipynb_nvim:markdown>>',
      '\n',
      optional(alias(repeat1($.content_line), $.cell_content)),
      $.cell_end
    ),

    raw_cell: $ => seq(
      '# <<ipynb_nvim:raw>>',
      '\n',
      optional(alias(repeat1($.content_line), $.cell_content)),
      $.cell_end
    ),
  },
});
