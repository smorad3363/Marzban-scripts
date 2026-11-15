"""Narrow, checksum-gated fixes for the deployed legacy Marzban master.

No database, accounting, user, subscription or inbound configuration is changed.
"""
import ast
import hashlib

NODE_SOURCE_SHA256 = "3450283fd75d2222d5b22c26bfbe696283608a37b59e6f21cd02a1072949ed01"
LEGACY_NODE_SOURCE_SHA256 = 'c65ff71f8208a841e011fa29b678ad02ccc31c7ad3dec5dd83a139f485d1b374'
HEALTH_SOURCE_SHA256 = "48ca5cece9061c7c37c44c59080b2d591b1fdb9e74afcdfe7deff2750783db64"

SERIALIZER = '''
def _serialized_node_control(method):
    @wraps(method)
    def serialized(self, *args, **kwargs):
        with self._node_control_lock:
            return method(self, *args, **kwargs)
    return serialized

'''

HEALTH = '''_node_probe_failures = {}
_node_recovery_attempts = {}


def core_health_check():
    config = None
    if not xray.core.started:
        config = xray.config.include_db_users()
        xray.core.restart(config)

    live_ids = set(xray.nodes)
    for states in (_node_probe_failures, _node_recovery_attempts):
        for node_id in list(states):
            if node_id not in live_ids:
                states.pop(node_id, None)

    for node_id, node in list(xray.nodes.items()):
        now = time.monotonic()
        reason = "api"
        try:
            if not node.connected:
                reason = "control"
            elif not node.started:
                reason = "stopped"
            else:
                node.api.get_sys_stats(timeout=5)
                _node_probe_failures.pop(node_id, None)
                continue
        except (ConnectionError, xray_exc.XrayError, AssertionError):
            pass

        state = _node_probe_failures.setdefault(node_id, {"count": 0, "since": now})
        state["count"] += 1
        checks, grace = (2, 5) if reason == "stopped" else (3, 30)
        if state["count"] < checks or now - state["since"] < grace:
            continue
        if now - _node_recovery_attempts.get(node_id, -1e12) < 120:
            continue

        # Recheck immediately before disrupting a data core. Expire only local
        # control caches and renew a stale gRPC channel before any core restart.
        invalidate = getattr(node, "_invalidate_status_cache", None)
        if callable(invalidate):
            invalidate()
        connected = False
        try:
            connected = bool(node.connected)
            if connected and node.started:
                if hasattr(node, "_session_id") and hasattr(node, "_api"):
                    node._api = None
                node.api.get_sys_stats(timeout=5)
                _node_probe_failures.pop(node_id, None)
                continue
        except (ConnectionError, xray_exc.XrayError, AssertionError):
            pass

        _node_recovery_attempts[node_id] = time.monotonic()
        _node_probe_failures.pop(node_id, None)
        logger.warning("Node %s recovery after repeated %s failures", node_id, reason)
        if config is None:
            config = xray.config.include_db_users()
        if connected:
            xray.operations.restart_node(node_id, config)
        else:
            xray.operations.connect_node(node_id, config)
'''


def digest(source):
    return hashlib.sha256(source.encode()).hexdigest()


def patch_control(source):
    if "def _serialized_node_control(" in source:
        raise ValueError("Master control is already patched; retain its reviewed files")
    if digest(source) not in {NODE_SOURCE_SHA256, LEGACY_NODE_SOURCE_SHA256}:
        raise ValueError("Unsupported master control source; no live service was changed")
    tree = ast.parse(source)
    node = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "ReSTXRayNode")
    lines = source.splitlines(True)
    names = {"make_request", "connected", "started", "connect", "disconnect", "start", "stop", "restart"}
    for method in sorted((n for n in node.body if isinstance(n, ast.FunctionDef) and n.name in names), key=lambda n: n.lineno, reverse=True):
        lines.insert(method.lineno - 1, "    @_serialized_node_control\n")
    result = "".join(lines)
    anchor = "        self.usage_coefficient = usage_coefficient\n"
    result = result.replace(anchor, anchor + "        self._node_control_lock = threading.RLock()\n", 1)
    result = "from functools import wraps\n" + result
    position = result.index("class ReSTXRayNode:")
    result = result[:position] + SERIALIZER + result[position:]
    result = result.replace("ssl.get_server_certificate((self.address, self.port))", "ssl.get_server_certificate((self.address, self.port), timeout=10)")
    result = result.replace("current_time = time.time()", "current_time = time.monotonic()")
    ast.parse(result)
    return result


def patch_health(source):
    if digest(source) != HEALTH_SOURCE_SHA256:
        raise ValueError("Unsupported master health source; no live service was changed")
    function = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == "core_health_check")
    lines = source.splitlines(True)
    result = "".join(lines[:function.lineno - 1]) + HEALTH + "\n" + "".join(lines[function.end_lineno:])
    ast.parse(result)
    return result
