# Harbor

Harbor 2.14.4 공식 online installer의 `prepare --with-trivy` 결과를 사용한다.
실제 `harbor.yml`, 생성된 compose와 `common/`에는 비밀값이 포함되므로 커밋하지 않는다.

SELinux 호스트에서는 prepare 후 생성 설정에 `container_file_t` 라벨과 컨테이너
읽기 권한이 필요하다. 현재 Harbor nginx는 API/registry Basic 인증 전달을 위해
각 proxy location에 아래 지시문을 명시한다.

```nginx
proxy_set_header Authorization $http_authorization;
```

외부 TLS는 Traefik이 종료하고 Harbor nginx에는 내부 HTTP로 전달한다.
