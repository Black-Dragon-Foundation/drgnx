"""drgnx's origin tracer (spec §19.4): during a replay, the stores to the names and attributes asked about, with the
values of the operands on those lines, written as JSON lines.  It runs inside the debugged program, so it is Python
(Python >= 3.12: `sys.monitoring`, PEP 669); it only reads, and it never changes what the program does.

Turned on by `sitecustomize` when DRGNX_ORIGIN holds its JSON settings:
  {"out": FILE, "root": DIR, "watch": ["shortfall", "item.reserve", ...]}
A watch is a name (a store to that name), or a dotted path whose last part is an attribute (a store to that attribute
on any object, `x.reserve = ...`; the record names the object as the line wrote it).  A call of a method on a watched
name (`items.append(x)`) is recorded as a change inside that method.
"""

import dis
import json
import os
import sys

_STORE_NAMES = {"STORE_NAME", "STORE_FAST", "STORE_GLOBAL", "STORE_DEREF", "STORE_FAST_STORE_FAST",
                "STORE_FAST_LOAD_FAST", "STORE_FAST_MAYBE_NULL"}
_LOAD_NAMES = {"LOAD_NAME", "LOAD_FAST", "LOAD_GLOBAL", "LOAD_DEREF", "LOAD_FAST_CHECK", "LOAD_FAST_AND_CLEAR",
               "LOAD_FAST_LOAD_FAST", "LOAD_FAST_BORROW", "LOAD_FAST_BORROW_LOAD_FAST_BORROW"}
_REPR_MAX = 200
_RECORDS_MAX = 100_000


def _short(v):
    try:
        r = repr(v)
    except Exception as e:  # a repr that fails is said, not raised into the program
        r = "<repr failed: %s>" % type(e).__name__
    return r if len(r) <= _REPR_MAX else r[: _REPR_MAX - 1] + "…"


def _names(ins):
    """The names an instruction loads or stores (two for the paired forms)."""
    a = ins.argval
    if isinstance(a, tuple):
        return [x for x in a if isinstance(x, str)]
    return [a] if isinstance(a, str) else []


class _Line:
    """What one line of a code object stores and reads."""

    __slots__ = ("stores", "loads", "calls", "text")

    def __init__(self):
        self.stores = []  # (target text, watch key)
        self.loads = []  # operand expressions, in order
        self.calls = []  # (object expression, method)
        self.text = ""


def _analyse(code):
    """Each line's stores, operand loads and method calls on names, from the bytecode."""
    lines = {}
    chain = []  # the expression being built from loads: ["item", "min"]
    line = None
    for ins in dis.get_instructions(code):
        if ins.positions and ins.positions.lineno:
            line = ins.positions.lineno
        if line is None:
            continue
        info = lines.setdefault(line, _Line())
        op = ins.opname
        if op in _LOAD_NAMES:
            names = _names(ins)
            for n in names[:-1]:
                info.loads.append(n)
            chain = names[-1:]
            if chain:
                info.loads.append(chain[0])
        elif op in ("LOAD_ATTR", "LOAD_METHOD") and chain:
            attr = ins.argval if isinstance(ins.argval, str) else None
            if attr is None:
                chain = []
                continue
            is_method = op == "LOAD_METHOD" or (op == "LOAD_ATTR" and (ins.arg or 0) & 1)
            if is_method:
                info.calls.append((".".join(chain), attr))
                chain = []
            else:
                chain = chain + [attr]
                info.loads.append(".".join(chain))
        elif op in _STORE_NAMES:
            for n in _names(ins):
                info.stores.append((n, n))
            chain = []
        elif op == "STORE_ATTR":
            obj = ".".join(chain) if chain else "?"
            info.stores.append(("%s.%s" % (obj, ins.argval), "." + ins.argval))
            chain = []
        elif op == "STORE_SUBSCR":
            info.stores.append(("%s[…]" % (".".join(chain) if chain else "?"), "[]"))
            chain = []
        else:
            chain = []
    # an operand loaded as part of a longer chain is shown by the chain only
    for info in lines.values():
        seen = []
        for e in info.loads:
            if e not in seen:
                seen.append(e)
        info.loads = [e for e in seen if not any(o != e and o.startswith(e + ".") for o in seen)]
    return lines


class Tracer:
    def __init__(self, out, root, watch):
        self.out = open(out, "a", encoding="utf-8", buffering=1)
        self.root = os.path.realpath(root) if root else None
        self.names = {w for w in watch if "." not in w}
        self.attrs = {"." + w.rsplit(".", 1)[1] for w in watch if "." in w}
        self.watch = set(watch)
        self.codes = {}  # code -> {line: _Line} (only the watched lines), or None: not ours
        self.pending = {}  # frame id -> (record, frame)
        self.seq = 0
        self.tool = None

    def _ours(self, code):
        got = self.codes.get(code, False)
        if got is not False:
            return got
        mine = None
        f = code.co_filename
        real = os.path.realpath(f)
        mine_file = self.root is None or real.startswith(self.root + os.sep)
        if mine_file and os.sep + ".drgnx-origin" + os.sep not in real:
            try:
                lines = _analyse(code)
            except Exception:
                lines = {}
            mine = {}
            for n, info in lines.items():
                stores = [s for s in info.stores if s[1] in self.names or s[1] in self.attrs or s[0] in self.watch]
                calls = [c for c in info.calls if c[0] in self.watch or c[0] in self.names]
                if stores or calls:
                    info.stores, info.calls = stores, calls
                    mine[n] = info
            if not mine:
                mine = None
        self.codes[code] = mine
        return mine

    def _write(self, rec):
        if self.seq >= _RECORDS_MAX:
            return
        self.seq += 1
        rec["seq"] = self.seq
        self.out.write(json.dumps(rec) + "\n")

    def _eval(self, expr, frame):
        try:
            return _short(eval(expr, frame.f_globals, frame.f_locals))
        except Exception:
            return None

    def _finish(self, key, frame):
        p = self.pending.pop(key, None)
        if p is None:
            return
        rec = p
        for s in rec["stores"]:
            v = self._eval(s["target"], frame) if "?" not in s["target"] and "[" not in s["target"] else None
            s["value"] = v
        for c in rec["calls"]:
            c["value"] = self._eval(c["object"], frame)
        for s in rec.pop("stores"):
            self._write(dict(rec, kind="store", target=s["target"], key=s["key"], value=s["value"], calls=None))
        for c in rec.pop("calls") or []:
            self._write(dict(rec, kind="call", target=c["object"], method=c["method"], inside=c["inside"],
                             value=c["value"]))

    def line(self, code, line):
        lines = self._ours(code)
        if lines is None:
            return sys.monitoring.DISABLE
        frame = sys._getframe(1)
        key = id(frame)
        self._finish(key, frame)
        info = lines.get(line)
        if info is None:
            return None
        operands = {}
        for e in info.loads:
            v = self._eval(e, frame)
            if v is not None:
                operands[e] = v
        calls = []
        for obj, method in info.calls:
            try:
                kind = type(eval(obj, frame.f_globals, frame.f_locals)).__name__
            except Exception:
                kind = "?"
            calls.append({"object": obj, "method": method, "inside": "%s.%s" % (kind, method)})
        self.pending[key] = {
            "file": code.co_filename, "line": line, "func": code.co_qualname,
            "stores": [{"target": t, "key": k} for t, k in info.stores],
            "calls": calls, "operands": operands,
        }
        return None

    def leave(self, code, offset, *rest):
        if self._ours(code) is None:
            return None  # PY_UNWIND cannot be disabled; the others are rare once a code object is known
        frame = sys._getframe(1)
        self._finish(id(frame), frame)
        return None

    def install(self):
        m = sys.monitoring
        for tool in (4, 3, 1):
            if m.get_tool(tool) is None:
                m.use_tool_id(tool, "drgnx-origin")
                self.tool = tool
                break
        if self.tool is None:
            return False
        E = m.events
        m.register_callback(self.tool, E.LINE, self.line)
        m.register_callback(self.tool, E.PY_RETURN, self.leave)
        m.register_callback(self.tool, E.PY_YIELD, self.leave)
        m.register_callback(self.tool, E.PY_UNWIND, self.leave)
        m.set_events(self.tool, E.LINE | E.PY_RETURN | E.PY_YIELD | E.PY_UNWIND)
        return True


def from_env():
    """The tracer DRGNX_ORIGIN asks for, installed; none when it is not asked for or Python is older than 3.12."""
    spec = os.environ.get("DRGNX_ORIGIN")
    if not spec:
        return None
    cfg = json.loads(spec)
    # the first line says which Python ran: older than 3.12 has no sys.monitoring, and the hub offers candidates
    with open(cfg["out"], "a", encoding="utf-8") as f:
        f.write(json.dumps({"python": "%d.%d.%d" % sys.version_info[:3]}) + "\n")
    if sys.version_info < (3, 12):
        return None
    t = Tracer(cfg["out"], cfg.get("root"), cfg.get("watch", []))
    return t if t.install() else None
