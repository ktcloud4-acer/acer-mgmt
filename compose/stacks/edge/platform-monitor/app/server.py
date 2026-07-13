import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlencode
from urllib.request import Request, urlopen

PROM = os.getenv("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
ALERT = os.getenv("ALERTMANAGER_URL", "http://alertmanager:9093").rstrip("/")
CLUSTERS = ["ggg", "khb", "ljw", "nmg", "oje"]
CHAOS_UPSTREAMS = {
    "mgmt": ("http://k3d-mgmt-serverlb:80/", {"Host": "chaos.imcherry5778.xyz"}),
    "ggg": ("https://ggg-ingress.tailc0244b.ts.net", {"Host": "ggg-chaos.imcherry5778.xyz"}),
    "khb": ("https://khb-ingress.tailc0244b.ts.net", {"Host": "khb-chaos.imcherry5778.xyz"}),
    "ljw": ("https://ljw-ingress.tailc0244b.ts.net", {"Host": "ljw-chaos.imcherry5778.xyz"}),
    "nmg": ("https://nmg-ingress.tailc0244b.ts.net", {"Host": "nmg-chaos.imcherry5778.xyz"}),
    "oje": ("https://oje-ingress.tailc0244b.ts.net", {"Host": "oje-chaos.imcherry5778.xyz"}),
}

def get_json(url):
    with urlopen(url, timeout=5) as response:
        return json.load(response)

def query(expr):
    data = get_json(f"{PROM}/api/v1/query?{urlencode({'query': expr})}")
    if data.get("status") != "success": raise RuntimeError("Prometheus query failed")
    return data["data"]["result"]

def scalar(expr, fallback=None):
    rows = query(expr)
    return float(rows[0]["value"][1]) if rows else fallback

def probe_chaos_upstream(cluster):
    url, headers = CHAOS_UPSTREAMS[cluster]
    with urlopen(Request(url, headers=headers), timeout=8) as response:
        return response.status

def chaos_endpoint_healthy(cluster):
    try:
        return probe_chaos_upstream(cluster) == 200
    except Exception:
        return False

def summarize_probes(probes):
    platform_services = {}
    cluster_checks = {name: [] for name in CLUSTERS}

    for row in probes:
        metric = row["metric"]
        value = float(row["value"][1])
        scope = metric.get("scope")
        service = metric.get("service", metric.get("target", "unknown"))

        if scope == "infra":
            platform_services[service] = value
        elif scope == "team" and metric.get("cluster") in cluster_checks:
            cluster_checks[metric["cluster"]].append(value)

    clusters = {}
    for name, checks in cluster_checks.items():
        healthy_count = sum(value == 1 for value in checks)
        clusters[name] = {
            "healthy": bool(checks) and healthy_count == len(checks),
            "healthy_count": healthy_count,
            "total": len(checks),
        }

    return {
        "platform_services": platform_services,
        "clusters": clusters,
        "cluster_endpoint_totals": {
            "healthy": sum(cluster["healthy_count"] for cluster in clusters.values()),
            "total": sum(cluster["total"] for cluster in clusters.values()),
        },
    }

def dashboard():
    probes = summarize_probes(query("probe_success"))
    alerts = get_json(f"{ALERT}/api/v2/alerts?active=true")
    return {
      **probes,
      "mgmt": {
        "cpu": scalar('100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'),
        "memory": scalar('100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)'),
        "disk": scalar('100 * (1 - node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})'),
      },
      "alerts": [{"name": a.get("labels",{}).get("alertname","alert"), "severity": a.get("labels",{}).get("severity","unknown"), "cluster": a.get("labels",{}).get("cluster","mgmt")} for a in alerts],
    }

HTML = '''<!doctype html><html><head><meta charset="utf-8"><title>Platform Health</title><style>
*{box-sizing:border-box}body{margin:0;background:#08141d;color:#e7f1f5;font:16px system-ui,sans-serif;padding:28px}h1{margin:0 0 4px}.sub{color:#8ca3ae}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin:24px 0}.card,.panel{background:#10222d;border:1px solid #31505f;border-radius:9px;padding:18px}.ok{color:#55d986}.warn{color:#f6b94d}.bad{color:#ff6b6b}.nodes{display:grid;grid-template-columns:repeat(6,1fr);gap:12px}.node{border:1px solid #31505f;border-radius:8px;padding:14px}.panels{display:grid;grid-template-columns:1fr 1fr 1fr;gap:16px;margin-top:16px}.metric{display:flex;justify-content:space-between;border-top:1px solid #27424f;padding:12px 0}.alert{border-top:1px solid #27424f;padding:11px 0}.drilldowns{margin-top:16px}.drilldown-links{display:flex;flex-wrap:wrap;gap:10px}.drilldown-links a{border:1px solid #4a8194;border-radius:6px;color:#81e7ff;padding:9px 12px;text-decoration:none}.drilldown-links a:hover{background:#173444}@media(max-width:900px){.grid,.nodes,.panels{grid-template-columns:1fr 1fr}} </style></head><body><h1>Platform Health</h1><div class="sub">Live Prometheus and Alertmanager data</div><div id="app">Loading…</div><script>
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function dot(ok){return `<span class="${ok?'ok':'bad'}">●</span>`} function pct(v){return v==null?'n/a':`${v.toFixed(1)}%`}
async function load(){try{const d=await (await fetch('/api/summary',{cache:'no-store'})).json();const platform=Object.values(d.platform_services);const platformHealthy=platform.filter(x=>x===1).length;const clusters=Object.values(d.clusters);const healthyClusters=clusters.filter(x=>x.healthy).length;const endpoints=d.cluster_endpoint_totals;document.querySelector('#app').innerHTML=`<div class="grid"><div class="card">Clusters<br><b>${healthyClusters}/${clusters.length}</b> ${dot(healthyClusters===clusters.length)}</div><div class="card">Platform Services<br><b>${platformHealthy}/${platform.length}</b> ${dot(platformHealthy===platform.length)}</div><div class="card">Cluster Endpoints<br><b>${endpoints.healthy}/${endpoints.total}</b> ${dot(endpoints.healthy===endpoints.total)}</div><div class="card">Firing Alerts<br><b>${d.alerts.length}</b> ${dot(d.alerts.length===0)}</div></div><div class="nodes">${Object.entries(d.clusters).map(([n,cluster])=>`<div class="node">${dot(cluster.healthy)} <b>${esc(n)}</b><div class="sub">${cluster.healthy_count}/${cluster.total} endpoint probes</div></div>`).join('')}</div><div class="panels"><div class="panel"><h3>Mgmt Control Plane</h3><div class="metric">CPU <b>${pct(d.mgmt.cpu)}</b></div><div class="metric">Memory <b>${pct(d.mgmt.memory)}</b></div><div class="metric">Disk <b>${pct(d.mgmt.disk)}</b></div></div><div class="panel"><h3>Platform Service Availability</h3>${Object.entries(d.platform_services).map(([n,ok])=>`<div class="metric">${esc(n)} ${dot(ok===1)}</div>`).join('')}</div><div class="panel"><h3>Active Alerts</h3>${d.alerts.length?d.alerts.map(a=>`<div class="alert ${a.severity==='critical'?'bad':'warn'}">${esc(a.cluster)} · ${esc(a.name)}<br><small>${esc(a.severity)}</small></div>`).join(''):'<div class="ok">No firing alerts</div>'}</div></div><div class="panel drilldowns"><h3>Drill-down</h3><div class="drilldown-links"><a href="https://grafana.imcherry5778.xyz" target="_blank" rel="noopener noreferrer">Grafana</a><a href="https://kibana.imcherry5778.xyz" target="_blank" rel="noopener noreferrer">Kibana</a><a href="https://argocd.imcherry5778.xyz" target="_blank" rel="noopener noreferrer">Argo CD</a><a href="https://chaos.imcherry5778.xyz" target="_blank" rel="noopener noreferrer">Chaos Dashboard</a></div></div>`}catch(e){document.querySelector('#app').textContent='Monitor data unavailable'}}load();setInterval(load,30000)</script></body></html>'''

class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  if self.path=="/healthz": self.send_response(200);self.end_headers();return
  if self.path.startswith("/api/status/chaos/"):
   cluster=self.path.rsplit("/",1)[-1]
   if cluster not in CHAOS_UPSTREAMS: self.send_response(404);self.end_headers();return
   healthy=chaos_endpoint_healthy(cluster)
   body=json.dumps({"cluster":cluster,"healthy":healthy}).encode()
   self.send_response(200 if healthy else 503);self.send_header("Content-Type","application/json");self.send_header("Cache-Control","no-store");self.end_headers();self.wfile.write(body);return
  if self.path=="/api/summary":
   try: body=json.dumps(dashboard()).encode(); code=200
   except Exception: body=b'{"error":"monitor data unavailable"}';code=503
   self.send_response(code);self.send_header("Content-Type","application/json");self.send_header("Cache-Control","no-store");self.end_headers();self.wfile.write(body);return
  self.send_response(200);self.send_header("Content-Type","text/html; charset=utf-8");self.end_headers();self.wfile.write(HTML.encode())
 def log_message(self,*_): pass
ThreadingHTTPServer(("",8080),Handler).serve_forever()
