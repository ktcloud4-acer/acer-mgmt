# mgmt 중앙 Ansible로 AIO 접속 확인

각 AIO는 사용자 소유의 `<team>-aio` Tailnet 장비로 가입한다. AIO 자체는
`--accept-dns=false`를 유지하고, MagicDNS 해석은 중앙 mgmt에서 수행한다.

초회 연결은 담당자가 다음 명령으로 SSH host key를 검증·등록한다. 자동
`ssh-keyscan`은 사용하지 않는다.

```bash
ssh -i ~/.ssh/acer.pem -o StrictHostKeyChecking=accept-new \
  ubuntu@nmg-aio.tailc0244b.ts.net true
```

이후 중앙 연결 점검은 다음처럼 실행한다.

```bash
compose/scripts/check-aio-tailnet-ansible.sh nmg
```

기본 키 경로가 다르면 Git에 경로를 기록하지 않고 실행 시에만 지정한다.

```bash
AIO_SSH_PRIVATE_KEY=/secure/path/acer.pem \
  compose/scripts/check-aio-tailnet-ansible.sh nmg
```

이 점검은 SSH와 Tailnet IPv4를 읽기만 한다. Operator 설치처럼 상태를 바꾸는
작업은 다음 중앙 플레이북으로 실행한다.

```bash
compose/scripts/bootstrap-aio-tailscale-operator.sh nmg
```

이 작업은 mgmt Vault에서 해당 팀의 Operator OAuth 필드만 읽는다. 값은 AIO의
`/run/acer-bootstrap` 아래 0600 임시 Helm 값 파일로만 전달되고, 성공·실패와
관계없이 삭제된다. `ProxyGroupReady=True`가 될 때까지 기다린다.
