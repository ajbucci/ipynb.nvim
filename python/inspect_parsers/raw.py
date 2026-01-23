from __future__ import annotations

import html
import re
from typing import Dict, Any

from .types import InspectSections


ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-9;]*m")


def _strip_ansi(text: str) -> str:
    if not text:
        return text
    return ANSI_ESCAPE_PATTERN.sub("", text)


def _strip_html(text: str) -> str:
    if not text:
        return text
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text).strip()


def parse(data: Dict[str, Any]) -> InspectSections:
    text_plain = data.get("text/plain")
    text_md = data.get("text/markdown")
    text_html = data.get("text/html")

    if isinstance(text_plain, str) and text_plain.strip():
        return InspectSections(
            string_form=text_plain,
            _raw=True,
            _mime="text/plain",
            _clean=_strip_ansi(text_plain),
        )

    if isinstance(text_md, str) and text_md.strip():
        return InspectSections(
            string_form=text_md,
            _raw=True,
            _mime="text/markdown",
            _clean=_strip_ansi(text_md),
        )

    if isinstance(text_html, str) and text_html.strip():
        stripped = _strip_html(text_html)
        return InspectSections(
            string_form=stripped,
            _raw=True,
            _mime="text/html",
            _clean=_strip_ansi(stripped),
        )

    return InspectSections()
