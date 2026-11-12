# drgnx: the stdio shim of a sealed debug fork's debugpy (docs/develop/debugging.md, "What-if forks").
#
# A fork's adapter runs inside Gleipnir with the program, and on Linux the sandbox has a network namespace of its own,
# so nothing in it can be reached from the hub but its stdio. debugpy's adapter speaks stdio, but each sub-process
# session (`startDebugging`) needs one more adapter, started inside the same sandbox. So the shim multiplexes: every
# message on stdio carries a `Drgnx-Conn: N` header beside its `Content-Length`; connection N starts its own
# `python -m debugpy.adapter` on its first message, and when that adapter ends the shim sends `Drgnx-Close: N` with an
# empty body. The shim ends when stdin does.
#
#   python3 debug-fork-shim.py
# Python because it runs in the sandbox, where debugpy's Python is the only runtime there is.
import subprocess
import sys
import threading

out_lock = threading.Lock()
conns = {}


def read_frame(f):
    head = {}
    while True:
        line = f.readline()
        if not line:
            return None, None
        line = line.rstrip(b"\r\n")
        if not line:
            break
        k, _, v = line.decode("latin-1").partition(":")
        head[k.strip().lower()] = v.strip()
    body = f.read(int(head.get("content-length", "0")))
    return head, body


def to_hub(cid, body, extra=""):
    with out_lock:
        sys.stdout.buffer.write(
            ("Drgnx-Conn: %s\r\n%sContent-Length: %d\r\n\r\n" % (cid, extra, len(body))).encode("latin-1") + body)
        sys.stdout.buffer.flush()


def pump(cid, proc):
    while True:
        head, body = read_frame(proc.stdout)
        if head is None:
            break
        to_hub(cid, body)
    proc.wait()
    conns.pop(cid, None)
    to_hub(cid, b"", "Drgnx-Close: %s\r\n" % cid)


def open_conn(cid):
    proc = subprocess.Popen([sys.executable, "-m", "debugpy.adapter"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    conns[cid] = proc
    threading.Thread(target=pump, args=(cid, proc), daemon=True).start()
    return proc


def main():
    stdin = sys.stdin.buffer
    while True:
        head, body = read_frame(stdin)
        if head is None:
            break
        cid = head.get("drgnx-conn", "0")
        proc = conns.get(cid) or open_conn(cid)
        try:
            proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
            proc.stdin.flush()
        except OSError:
            pass
    for proc in list(conns.values()):
        proc.kill()


main()
