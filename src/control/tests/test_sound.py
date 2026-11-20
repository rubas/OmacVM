"""`omacvm sound` in the VM (the audio panel runs it): the Mac's outputs as
macOS lists them and the balance, over this VM's control port, answered by
OmacVM.app itself. A pty stands in for the port and a thread for the app
(test_port.py)."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from test_port import FakeApp  # noqa: E402

ENTRY = os.path.join(os.path.dirname(__file__), "..", "omacvm")
PATH = "/omacvm/app/sound"


@pytest.fixture
def vm(tmp_path):
    share = tmp_path / "share"
    share.mkdir()
    (share / "VERSION").write_text("3.4.7\n")
    env_file = tmp_path / "env"
    apps = []

    def run(answer, *args, vm_type="app", port=True):
        env_file.write_text(f"OMACVM_VM_TYPE={vm_type}\nOMACVM_HOST=10.0.2.2\n")
        env = {k: v for k, v in os.environ.items() if k != "OMACVM_BRIDGE_URL"}
        env.update(OMACVM_SHARE=str(share), OMACVM_ENV=str(env_file), HOME=str(tmp_path))
        app = None
        if port:
            app = FakeApp(answer)
            apps.append(app)
            env["OMACVM_CONTROL_PORT"] = app.path
        else:
            env["OMACVM_CONTROL_PORT"] = str(tmp_path / "no-port")
        p = subprocess.run([sys.executable, ENTRY, "sound", *args], env=env, capture_output=True, text=True, timeout=20)
        return p, (app.requests if app else [])
    yield run
    for a in apps:
        a.close()


STATE = {"accessibility": True, "output": "AppleUSBAudioEngine:Apple Inc.:Studio Display XDR:10,11", "balance": None}
# What the Mac mini with a Studio Display XDR and a HomePod answered (2026-11-20).
DEVICES = [{"name": "Mac mini Speakers", "selected": False}, {"name": "Studio Display XDR Speakers", "selected": True},
           {"name": "Living Room", "selected": False}]
LIST = dict(STATE, devices=DEVICES, ms=973)


def test_reads_the_state(vm):
    p, reqs = vm(lambda r: (200, STATE), "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout) == STATE
    assert reqs[-1]["method"] == "GET" and reqs[-1]["path"] == PATH and reqs[-1]["body"] is None


def test_reads_the_list(vm):
    p, reqs = vm(lambda r: (200, LIST), "read", "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout) == dict(STATE, devices=DEVICES)
    assert reqs[-1]["method"] == "POST" and reqs[-1]["body"] == {"read": True}
    p, _ = vm(lambda r: (200, LIST), "read")
    assert p.stdout.splitlines() == ["  Mac mini Speakers", "* Studio Display XDR Speakers", "  Living Room",
                                     "Balance: this output has none"]


def test_presses_a_device(vm):
    def app(r):
        name = r["body"]["press"]
        return 200, dict(STATE, devices=[dict(d, selected=d["name"] == name) for d in DEVICES])
    p, reqs = vm(app, "press", "Living Room", "--json")
    assert p.returncode == 0, p.stderr
    assert reqs[-1]["body"] == {"press": "Living Room"}
    assert [d["name"] for d in json.loads(p.stdout)["devices"] if d["selected"]] == ["Living Room"]


def test_sets_the_balance(vm):
    p, reqs = vm(lambda r: (200, dict(STATE, balance={"value": r["body"]["balance"], "settable": True})), "balance", "25", "--json")
    assert p.returncode == 0, p.stderr
    assert reqs[-1]["body"] == {"balance": 0.25}
    assert json.loads(p.stdout)["balance"] == {"value": 0.25, "settable": True}
    p, _ = vm(lambda r: (200, dict(STATE, balance={"value": 0.5, "settable": True})))
    assert p.stdout.strip() == "Balance: 50"


def test_the_app_says_no(vm):
    for status, code in [(403, "accessibility"), (409, "busy"), (409, "not-front"), (409, "no-device"),
                         (409, "interrupted"), (409, "no-balance"), (501, "unsupported")]:
        p, _ = vm(lambda r, s=status, c=code: (s, {"code": c, "error": "no"}), "read", "--json")
        assert p.returncode == 4, (status, code, p.stderr)
        assert json.loads(p.stdout)["code"] == code


def test_older_app(vm):
    # An app without the request passes it to the Bridge, which knows no such one.
    p, _ = vm(lambda r: (404, {"code": "not-found", "error": "not found"}), "--json")
    assert p.returncode == 1 and p.stdout == ""
    p, _ = vm(lambda r: (0, {"error": "OmacVM Bridge does not answer on this Mac"}), "read", "--json")
    assert p.returncode == 1 and p.stdout == ""


def test_not_an_app_vm(vm):
    p, reqs = vm(lambda r: (200, STATE), "--json", vm_type="other")
    assert p.returncode == 3 and reqs == []
    p, _ = vm(None, "--json", port=False)
    assert p.returncode == 3


def test_usage(vm):
    for args in (["press"], ["press", ""], ["balance", "left"], ["balance", "101"], ["volume", "5"], ["read", "now"]):
        p, reqs = vm(lambda r: (200, STATE), *args)
        assert p.returncode == 2 and reqs == [], args


def test_the_panel_gets_its_types(vm):
    p, _ = vm(lambda r: (200, {"accessibility": 1, "output": 7, "balance": {"value": "0.5"},
                               "devices": [{"name": "Living Room", "selected": 1}, {"name": 5}, "Kitchen", {"name": ""}]}),
              "read", "--json")
    assert json.loads(p.stdout) == {"accessibility": False, "output": None, "balance": None,
                                    "devices": [{"name": "Living Room", "selected": False}]}
    p, _ = vm(lambda r: (200, {"accessibility": True, "balance": {"value": 7, "settable": True}}), "--json")
    assert json.loads(p.stdout)["balance"] == {"value": 1.0, "settable": True}
