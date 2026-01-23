from __future__ import annotations

import html
import re
from typing import Dict, Any

from .types import InspectSections

ANSI_ESCAPE_PATTERN = re.compile(r'\x1b\[[0-9;]*m')
KEY_PATTERN = re.compile(r'\x1b\[31m([\w\s]+):\x1b\[39m')

KERNEL_NAME_ALIASES = set()


def strip_ansi(text: str) -> str:
    if text is None:
        return text
    return ANSI_ESCAPE_PATTERN.sub('', text)


def parse_inspect_output(text: str) -> dict:
    """
    Parse IPython inspect output into structured sections.
    Keys are wrapped in red ANSI codes (\x1b[31m...\x1b[39m).
    Returns dict with keys aligned to IPython oinspect InfoDict fields.
    """
    if not text:
        return {}

    key_map = {
        "Type": "type_name",
        "String form": "string_form",
        "Length": "length",
        "File": "file",
        "Docstring": "docstring",
        "Init docstring": "init_docstring",
        "Class docstring": "class_docstring",
        "Call docstring": "call_docstring",
        "Source": "source",
        "Signature": "definition",
        "Init signature": "init_definition",
        "Call signature": "call_def",
        "Namespace": "namespace",
        "Subclasses": "subclasses",
        "Repr": "string_form",
    }

    matches = list(KEY_PATTERN.finditer(text))
    if not matches:
        return {"string_form": strip_ansi(text).strip()} if text.strip() else {}

    result = {}
    order = []
    for i, match in enumerate(matches):
        key = match.group(1)
        normalized_key = key_map.get(key)
        if not normalized_key:
            continue

        value_start = match.end()
        value_end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        value = text[value_start:value_end]

        value = strip_ansi(value).strip()
        if value:
            result[normalized_key] = str(value)
            order.append(normalized_key)

    if order:
        result["_order"] = order

    return result


def _looks_like_ipython_sections(text: str) -> bool:
    if not text:
        return False
    return bool(KEY_PATTERN.search(text))


def _strip_html(text: str) -> str:
    if not text:
        return text
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text).strip()


def parse(data: Dict[str, Any]) -> InspectSections:
    text_plain = data.get("text/plain")
    text_md = data.get("text/markdown")
    text_html = data.get("text/html")

    if isinstance(text_plain, str) and _looks_like_ipython_sections(text_plain):
        sections = parse_inspect_output(text_plain)
        if sections:
            sections["_mime"] = "text/plain"
            return InspectSections(**sections)

    if isinstance(text_md, str) and text_md.strip():
        return InspectSections(string_form=text_md, _mime="text/markdown")

    if isinstance(text_plain, str) and text_plain.strip():
        return InspectSections(string_form=text_plain, _raw=True, _mime="text/plain")

    if isinstance(text_html, str) and text_html.strip():
        return InspectSections(string_form=_strip_html(text_html), _raw=True, _mime="text/html")

    return InspectSections()
