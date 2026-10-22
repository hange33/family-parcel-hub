FROM mcr.microsoft.com/playwright/python:v1.48.0-jammy

ENV TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1 \
    PDD_STATE_DIR=/app/state

WORKDIR /app
COPY worker.py /app/worker.py

RUN mkdir -p /app/state
VOLUME ["/app/state"]
EXPOSE 8791

CMD ["python", "/app/worker.py"]
