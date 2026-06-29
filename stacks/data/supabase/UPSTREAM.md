# Upstream

Self-host Docker 구성은 Supabase 공식 저장소의 아래 커밋에서 가져왔다.

- Repository: `https://github.com/supabase/supabase`
- Commit: `20290c71bdc48bef1720bfe7d292f3b9e6154f7d`

acer-mgmt 변경점은 Traefik `mgmt-proxy` 연결, 호스트 포트 비노출,
`DATA_ROOT` 영속 경로, 외부 HTTPS URL 설정이다.
