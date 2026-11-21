"""drgnx's hot reload (spec §19.7 D8, `debug/hot-reload`): the saved file PATH's changed function bodies go into the
stopped program, jurigged-style.  It runs inside the debugged program, so it is Python (>= 3.11: `co_qualname`); the
hub sends it in one `evaluate` and runs it with `exec` in a namespace of its own, so the frame's locals stay as they
are.  Nothing at module level runs again; frames already running keep their old code.  OUT is the answer.
"""
import os, sys, types


def _drgnx_hot_reload(path):
    real = os.path.realpath(path)
    out = {"patched": [], "skipped": []}
    mods = [m for m in list(sys.modules.values())
            if isinstance(getattr(m, "__file__", None), str) and os.path.realpath(m.__file__) == real]
    if not mods:
        out["skipped"].append({"name": path, "why": "not imported"})
        return out
    with open(real, encoding="utf-8") as f:
        new = compile(f.read(), mods[0].__file__, "exec")
    live, classes = {}, set()

    def gather(ns, seen):
        for v in list(vars(ns).values()):
            if isinstance(v, (staticmethod, classmethod)):
                v = v.__func__
            if isinstance(v, types.FunctionType):
                live.setdefault(v.__qualname__, []).append(v)
            elif isinstance(v, type) and id(v) not in seen and v.__module__ == mods[0].__name__:
                seen.add(id(v))
                classes.add(v.__qualname__)
                gather(v, seen)

    for m in mods:
        gather(m, set())

    def walk(code):
        for k in code.co_consts:
            if not isinstance(k, types.CodeType):
                continue
            q = getattr(k, "co_qualname", k.co_name)
            if q in classes or "<" in q:
                pass
            elif q not in live:
                out["skipped"].append({"name": q, "why": "new: it exists from the next run"})
            else:
                for fn in live[q]:
                    if fn.__code__ == k:
                        continue
                    if fn.__code__.co_freevars != k.co_freevars:
                        out["skipped"].append({"name": q, "why": "its closure changed"})
                    else:
                        fn.__code__ = k
                        out["patched"].append(q)
            walk(k)

    walk(new)
    return out


OUT = _drgnx_hot_reload(PATH)
