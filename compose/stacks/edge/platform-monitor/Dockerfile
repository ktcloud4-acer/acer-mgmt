FROM python:3.13-alpine
WORKDIR /app
COPY app/ /app/app/
RUN addgroup -S -g 10001 monitor && adduser -S -D -H -u 10001 -G monitor monitor
USER 10001:10001
EXPOSE 8080
CMD ["python", "-m", "app.server"]
