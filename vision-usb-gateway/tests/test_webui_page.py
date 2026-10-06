"""The admin page's own wiring: what the browser runs, checked without one.

Found live 2026-10-06: the eth1 address/prefix/gateway fields had no hint
element, the validation wrote into it unchecked, so "Save + Apply" in the
Ethernet AOI section threw before sending anything — with any values, ever
since the per-section save (the server side was only ever tested by API)."""
import re
from html.parser import HTMLParser
from pathlib import Path

from vision_webui import server

STATIC = Path(server.__file__).parent / "static"


class Labels(HTMLParser):
    """Validated controls per <label>, and whether the label carries a hint."""

    def __init__(self):
        super().__init__()
        self.open, self.validated, self.without_hint = [], [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "label":
            self.open.append({"ids": [], "hint": False})
        elif self.open and "data-validate" in a:
            self.open[-1]["ids"].append(a.get("id"))
            self.validated.append(a.get("id"))
        elif self.open and tag == "span" and "hint" in (a.get("class") or "").split():
            self.open[-1]["hint"] = True

    def handle_endtag(self, tag):
        if tag == "label" and self.open:
            label = self.open.pop()
            if label["ids"] and not label["hint"]:
                self.without_hint += label["ids"]


def test_every_validated_field_can_show_its_hint():
    page = Labels()
    page.feed((STATIC / "index.html").read_text(encoding="utf-8"))
    assert {"ETH1_ADDRESS", "ETH1_PREFIX", "ETH1_GATEWAY", "NET_GW"} <= set(page.validated)
    assert page.without_hint == []


def test_validation_survives_a_label_without_a_hint():
    # The next field added without one must not break saving again.
    js = (STATIC / "app.js").read_text(encoding="utf-8")
    body = re.search(r"function setFieldValidity\(.*?\n}", js, re.S).group(0)
    assert 'querySelector(".hint").textContent' not in body
    assert re.search(r"if \(message && hint\)", body)


def test_the_eth1_gateway_may_be_left_empty():
    # Server side of the same save: an isolated AOI network has no gateway.
    updates = {"ETH1_ENABLED": "true", "ETH1_ADDRESS": "192.168.100.1", "ETH1_PREFIX": "24", "ETH1_GATEWAY": ""}
    assert server.validate_config_updates(updates) == (True, "")
