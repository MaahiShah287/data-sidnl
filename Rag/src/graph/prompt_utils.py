"""
src/graph/prompt_utils.py — safe prompt rendering.

Prompt files contain literal JSON examples such as
``{"sql": "<query>"}``. ``str.format()`` treats every brace as a placeholder
and raises ``KeyError`` (or ``IndexError``) before the LLM is ever called.

``render()`` substitutes only placeholders that look like identifiers
(``{question}``, ``{metric_templates}``) and leaves everything else — JSON
examples included — exactly as written.
"""
from __future__ import annotations

import re

_PLACEHOLDER = re.compile(r"\{([a-z_][a-z0-9_]*)\}")


def render(template: str, **kwargs) -> str:
    """Substitute ``{name}`` placeholders from kwargs; leave other braces alone."""

    def _sub(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in kwargs:
            return match.group(0)  # unknown placeholder: leave as-is
        value = kwargs[key]
        return "" if value is None else str(value)

    return _PLACEHOLDER.sub(_sub, template)
