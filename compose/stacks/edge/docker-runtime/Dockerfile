FROM python:3.13-alpine

WORKDIR /app

RUN addgroup -g 10001 app \
    && adduser -D -H -u 10001 -G app app

COPY app/ app/

ENV PYTHONPATH=/app/app

USER 10001:10001

EXPOSE 8080

CMD ["python", "-m", "app.server"]
