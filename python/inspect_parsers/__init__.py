from __future__ import annotations

from typing import Callable, Dict, Any, Optional

from . import python as python_parser
from . import raw as raw_parser
from .types import InspectSections, as_dict

Parser = Callable[[Dict[str, Any]], InspectSections]

# Parser contract:
# Parsers return InspectSections (dataclass) so the Lua UI can stay generic.
# Frontend display rules (ipynb/inspector.lua):
# - string_form: primary "Value" section; if present, metadata is shown before docstring.
# - definition/init_definition/call_def: first non-empty becomes "Signature".
# - docstring/init_docstring/class_docstring/call_docstring: first non-empty becomes "Docstring".
# - type_name/namespace/length/file: shown as "Metadata" key/value lines.
# - _order: optional list of keys for non-Python kernels (preserves kernel-provided order).
# - _raw: if true, UI will run Snacks.terminal.colorize() on the buffer.
# - _mime: best mime selected from the kernel reply (text/plain, text/markdown, text/html, ...).
# - _clean: ANSI-stripped fallback text for raw output when colorize isn't available.


def _normalize(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    return value.strip().lower()


def get_parser(language: Optional[str], kernel_name: Optional[str]) -> Callable[[Dict[str, Any]], Dict[str, Any]]:
    name = _normalize(kernel_name)
    lang = _normalize(language)

    if name in python_parser.KERNEL_NAME_ALIASES:
        parser = python_parser.parse
    elif lang == "python":
        parser = python_parser.parse
    else:
        parser = raw_parser.parse

    def parse(data: Dict[str, Any]) -> Dict[str, Any]:
        return as_dict(parser(data))

    return parse
