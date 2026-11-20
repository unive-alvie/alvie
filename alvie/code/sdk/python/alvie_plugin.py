"""The Python SDK of ALVIE/Core: write the backend of an external plugin in Python.

A backend is a class with the methods of the contract of Core (pre, step, restore, clone, post); serve() runs it
on the protocol of Core (version 1: JSON-RPC 2.0, one message per line, on standard input and output). Write logs
on standard error (log() does): standard output carries only the protocol.

    from alvie_plugin import Backend, serve, get

    class MyChip(Backend):
        def __init__(self, config, variant):
            ...
        def pre(self):
            ...
        def step(self, step):
            return [{"Ok": {}}]          # the observations, values of observations.yaml

    serve("my-chip", "0.1", MyChip)

Values are in the JSON form of Core: a node (a variant or a record) is a dict with one member, its tag, whose value
is the dict of its fields ({"mov": {"r": ..., "v": ...}}); integers, booleans, strings (symbols) and lists are
themselves. node(), tag(), fields() and get() read and make them; alvie plugin types writes constructors for the
observations of a plugin, which check them.

Standard library only; Python 3.8 or later.
"""

import copy
import json
import sys
import traceback

PROTOCOL = 1

__all__ = ["Backend", "Step", "PluginError", "serve", "node", "tag", "fields", "get", "log",
           "check_int", "check_bool", "check_enum", "PROTOCOL"]


# Values

def node(tag_, **fields_):
    """The node of a tag and its fields: node("Exit", time=3) is {"Exit": {"time": 3}}."""
    return {tag_: fields_}


def tag(value):
    """The tag of a node ({"mov": {...}} -> "mov"), or None for a value that is not a node."""
    if isinstance(value, dict) and len(value) == 1:
        (t,) = value
        return None if t == "?" else t
    return None


def fields(value):
    """The fields of a node, as a dict."""
    t = tag(value)
    if t is None:
        raise ValueError(f"not a node: {value!r}")
    return value[t]


def get(value, *path):
    """The value at a path of field names: get(atom, "r", "i") is the i of the r of the atom."""
    for name in path:
        fs = fields(value)
        if name not in fs:
            raise KeyError(f"{tag(value)} has no field {name!r} (its fields: {', '.join(fs) or 'none'})")
        value = fs[name]
    return value


def check_int(name, value, lowest=None, highest=None):
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{name}: expected an integer, not {value!r}")
    if (lowest is not None and value < lowest) or (highest is not None and value > highest):
        raise ValueError(f"{name}: {value} is out of range {lowest}..{highest}")
    return value


def check_bool(name, value):
    if not isinstance(value, bool):
        raise ValueError(f"{name}: expected true or false, not {value!r}")
    return value


def check_enum(name, value, constants):
    if value not in constants:
        raise ValueError(f"{name}: {value!r} is not one of {', '.join(constants)}")
    return value


def log(*args):
    """Writes to standard error, which ALVIE keeps as the plugin's log."""
    print(*args, file=sys.stderr, flush=True)


# The contract

class Step:
    """One input: its section, its position in the section's run, its atom, and the programs of the sections."""

    __slots__ = ("section", "position", "atom", "programs")

    def __init__(self, section, position, atom, programs):
        self.section = section
        self.position = position
        self.atom = atom
        self.programs = programs

    def __repr__(self):
        return f"Step({self.section!r}, {self.position}, {self.atom!r})"


class PluginError(Exception):
    """An error that ALVIE shows to the user as it is (for example: an unknown variant)."""


class Backend:
    """The backend of a plugin. Override pre, step and post; restore and clone have defaults.

    capabilities: what the manifest declares (restore, clone); the handshake checks that the backend has them.
    """

    capabilities = ("restore", "clone")

    def __init__(self, config, variant):
        """config: the values of the parameters of the manifest, by name (strings); variant: a name or None."""
        self.config = config
        self.variant = variant

    def pre(self):
        """Starts a test from the initial state of the platform."""

    def step(self, step):
        """Runs one input; returns its observations (a list), or (observations, bookkeeping)."""
        raise NotImplementedError

    def restore(self, step, observations, bookkeeping):
        """A dry step: update the state as if the step ran. By default, the step runs again."""
        self.step(step)

    def clone(self):
        """An independent copy. By default, a deep copy."""
        return copy.deepcopy(self)

    def post(self):
        """Ends a test."""


# The protocol

def _step_of(params):
    return Step(params["section"], params["position"], params["atom"], params["programs"])


def serve(name, version, make, stdin=None, stdout=None):
    """Answers the requests of ALVIE until it shuts the plugin down (or closes its standard input).

    make(config, variant) makes the backend (e.g. the class); name and version are those of the manifest.
    """
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    instances = {}

    def instance(params):
        i = params.get("instance")
        if i not in instances:
            raise PluginError(f"there is no instance {i!r}")
        return instances[i]

    def handle(method, params):
        if method == "initialize":
            if params.get("protocol") != PROTOCOL:
                raise PluginError(f"this plugin speaks version {PROTOCOL} of the protocol, not {params.get('protocol')!r}")
            if params.get("plugin") != name:
                raise PluginError(f"this program is plugin {name}, not {params.get('plugin')!r}")
            backend = make(params.get("config") or {}, params.get("variant"))
            instances.clear()
            instances[0] = backend
            return {"protocol": PROTOCOL, "name": name, "version": version, "capabilities": list(backend.capabilities)}
        if method == "pre":
            instance(params).pre()
            return {}
        if method == "step":
            out = instance(params).step(_step_of(params))
            observations, bookkeeping = out if isinstance(out, tuple) else (out, None)
            if not isinstance(observations, list):
                raise PluginError(f"step returned {observations!r}, not a list of observations")
            return {"observations": observations, "bookkeeping": bookkeeping}
        if method == "restore":
            instance(params).restore(_step_of(params), params["observations"], params.get("bookkeeping"))
            return {}
        if method == "clone":
            i = max(instances) + 1
            instances[i] = instance(params).clone()
            return {"instance": i}
        if method == "post":
            instance(params).post()
            return {}
        if method == "shutdown":
            return {}
        raise LookupError(method)

    for line in stdin:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
            rid, method, params = request.get("id"), request["method"], request.get("params") or {}
        except (ValueError, KeyError, AttributeError) as e:
            answer = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": f"not a request: {e}"}}
            stdout.write(json.dumps(answer) + "\n")
            stdout.flush()
            continue
        try:
            answer = {"jsonrpc": "2.0", "id": rid, "result": handle(method, params)}
        except LookupError as e:
            if isinstance(e, KeyError) or str(e) != method:
                answer = {"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": f"{type(e).__name__}: {e}", "data": traceback.format_exc()}}
            else:
                answer = {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"unknown method {method}"}}
        except PluginError as e:
            answer = {"jsonrpc": "2.0", "id": rid, "error": {"code": 1, "message": str(e)}}
        except Exception as e:  # a bug of the backend: its message, and the traceback for the log
            answer = {"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": f"{type(e).__name__}: {e}", "data": traceback.format_exc()}}
        stdout.write(json.dumps(answer, separators=(",", ":")) + "\n")
        stdout.flush()
        if method == "shutdown":
            return
