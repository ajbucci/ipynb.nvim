#include "tree_sitter/parser.h"
#include <string.h>

enum TokenType {
  CONTENT_LINE,
  CELL_END,
};

void *tree_sitter_ipynb_external_scanner_create(void) {
  return NULL;
}

void tree_sitter_ipynb_external_scanner_destroy(void *payload) {
}

unsigned tree_sitter_ipynb_external_scanner_serialize(void *payload, char *buffer) {
  return 0;
}

void tree_sitter_ipynb_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
}

static void advance(TSLexer *lexer) {
  lexer->advance(lexer, false);
}

// Check if current position matches the end marker: # <</ipynb_nvim>>
static bool check_end_marker(TSLexer *lexer) {
  // Expected: # <</ipynb_nvim>>
  const char *marker = "# <</ipynb_nvim>>";
  for (int i = 0; marker[i] != '\0'; i++) {
    if (lexer->lookahead != (unsigned char)marker[i]) {
      return false;
    }
    advance(lexer);
  }
  return true;
}

bool tree_sitter_ipynb_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  // Check for cell end marker: # <</ipynb_nvim>>
  if (valid_symbols[CELL_END]) {
    if (lexer->lookahead == '#') {
      if (check_end_marker(lexer)) {
        // Optionally consume newline
        if (lexer->lookahead == '\n') {
          advance(lexer);
        }
        lexer->result_symbol = CELL_END;
        return true;
      }
    }
  }

  // Content line: any line that is not an end marker
  if (valid_symbols[CONTENT_LINE]) {
    // Check if this line is an end marker
    if (lexer->lookahead == '#') {
      lexer->mark_end(lexer);
      if (check_end_marker(lexer)) {
        // This is an end marker, not a content line
        return false;
      }
      // Not an end marker, reset and consume as content line
    }

    // Consume until newline (including empty lines within cells)
    while (lexer->lookahead != '\n' && lexer->lookahead != 0) {
      advance(lexer);
    }

    // Consume the newline
    if (lexer->lookahead == '\n') {
      advance(lexer);
      lexer->result_symbol = CONTENT_LINE;
      return true;
    }

    // Handle EOF without trailing newline - only if we consumed something
    if (lexer->lookahead == 0) {
      lexer->result_symbol = CONTENT_LINE;
      return true;
    }
  }

  return false;
}