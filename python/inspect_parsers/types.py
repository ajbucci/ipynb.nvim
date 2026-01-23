from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import List, Optional, Dict, Any


@dataclass
class InspectSections:
    string_form: Optional[str] = None
    docstring: Optional[str] = None
    definition: Optional[str] = None
    init_definition: Optional[str] = None
    call_def: Optional[str] = None
    type_name: Optional[str] = None
    namespace: Optional[str] = None
    length: Optional[str] = None
    file: Optional[str] = None
    subclasses: Optional[str] = None
    class_docstring: Optional[str] = None
    init_docstring: Optional[str] = None
    call_docstring: Optional[str] = None
    _order: Optional[List[str]] = None
    _raw: Optional[bool] = None
    _mime: Optional[str] = None
    _clean: Optional[str] = None


def as_dict(sections: InspectSections) -> Dict[str, Any]:
    return asdict(sections)
