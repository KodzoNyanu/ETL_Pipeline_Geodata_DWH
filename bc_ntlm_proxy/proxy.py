from flask import Flask, request, Response
import requests
from requests_ntlm import HttpNtlmAuth
import logging
import threading

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("bc-proxy")

app = Flask(__name__)

BC_BASE  = "http://bc2025:7048"
SKIP_HDR = {"host", "content-length", "transfer-encoding", "connection", "content-encoding", "accept-encoding"}

# Thread-local sessions — each thread gets its own NTLM session (thread-safe)
_local = threading.local()

def get_session():
    if not hasattr(_local, 'session'):
        s = requests.Session()
        s.auth = HttpNtlmAuth("BC2025\\BC", "BC_25")
        s.headers.update({"Connection": "keep-alive"})
        _local.session = s
    return _local.session


@app.route("/<path:path>", methods=["GET", "POST", "PATCH", "PUT", "DELETE"])
def proxy(path):
    url = f"{BC_BASE}/{path}"
    qs  = request.query_string.decode()
    if qs:
        url = f"{url}?{qs}"

    fwd = {k: v for k, v in request.headers if k.lower() not in SKIP_HDR}

    try:
        resp = get_session().request(
            method=request.method,
            url=url,
            headers=fwd,
            data=request.get_data(),
            allow_redirects=False,
            timeout=120,
        )
        log.info("%s %s → %s", request.method, url, resp.status_code)
    except requests.exceptions.ConnectionError as e:
        log.error("BC unreachable: %s", e)
        return Response(f"BC unreachable: {e}", 502)

    out_hdrs = {k: v for k, v in resp.headers.items() if k.lower() not in SKIP_HDR}
    return Response(resp.content, resp.status_code, out_hdrs)


if __name__ == "__main__":
    log.info("BC NTLM proxy → %s", BC_BASE)
    app.run(host="0.0.0.0", port=3128, threaded=True)
