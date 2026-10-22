FROM python:3.11-slim

ENV TZ=Asia/Shanghai \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app.py /app/app.py

RUN mkdir -p /app/data
VOLUME ["/app/data"]
EXPOSE 8790

CMD ["python", "/app/app.py", "--host", "0.0.0.0", "--port", "8790"]
