FROM python:3.10-slim

WORKDIR /app

COPY . /app

RUN pip install --no-cache-dir flask gunicorn prometheus_flask_exporter

EXPOSE 5000

CMD ["gunicorn", "-b", "0.0.0.0:5000", "app:app"]