from flask import Flask
from prometheus_flask_exporter import PrometheusMetrics
import socket

app = Flask(__name__)
metrics = PrometheusMetrics(app)

@app.route('/')
def index():
    return f"Hostname: {socket.gethostname()}"

@app.route('/metrics')
def metrics_endpoint():
    return metrics.metrics()
