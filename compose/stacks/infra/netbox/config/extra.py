# NetBox 추가 설정. configuration.py 이후에 로드되어 어떤 값이든 override 한다.
# 컨테이너의 /etc/netbox/config/extra.py 로 read-only 마운트된다.
# env 로 노출되지 않는 설정(CSRF, social-auth OIDC)을 여기서 os.environ 값으로 채운다.
import os

# ── 리버스 프록시(Traefik 가 TLS 종단) ────────────────────────────────
# 프록시 뒤에서는 CSRF 신뢰 origin 을 명시해야 로그인/폼 POST 가 동작한다.
_public_url = os.environ.get("NETBOX_PUBLIC_URL", "").rstrip("/")
if _public_url:
    CSRF_TRUSTED_ORIGINS = [_public_url]

# ── SSO: Keycloak OIDC (realm: mgmt) ─────────────────────────────────
# NetBox 는 python-social-auth 로 SSO 를 처리한다. REMOTE_AUTH_BACKEND 에
# social-auth 백엔드를 지정하면 로컬 로그인과 병행해 SSO 버튼이 노출된다.
# (REMOTE_AUTH_ENABLED 는 헤더 기반 원격 인증용이므로 여기서는 켜지 않는다.)
# Keycloak 클라이언트 콜백 URL: https://netbox.<domain>/oauth/complete/oidc/
_oidc_endpoint = os.environ.get("NETBOX_OIDC_ENDPOINT", "")
if _oidc_endpoint:
    REMOTE_AUTH_BACKEND = "social_core.backends.open_id_connect.OpenIdConnectAuth"
    SOCIAL_AUTH_OIDC_OIDC_ENDPOINT = _oidc_endpoint
    SOCIAL_AUTH_OIDC_KEY = os.environ.get("NETBOX_OIDC_CLIENT_ID", "netbox")
    SOCIAL_AUTH_OIDC_SECRET = os.environ.get("NETBOX_OIDC_CLIENT_SECRET", "")
    SOCIAL_AUTH_OIDC_SCOPE = ["profile", "email"]

    _logout_url = os.environ.get("NETBOX_OIDC_LOGOUT_URL", "")
    if _logout_url:
        LOGOUT_REDIRECT_URL = _logout_url

# ── (선택) Keycloak 그룹 → NetBox 권한 매핑 ───────────────────────────
# keycloak-netbox-bootstrap.sh 가 'groups' 클레임 매퍼를 만들어 두므로,
# platform-admin 그룹 구성원을 자동으로 superuser/staff 로 승격하려면 아래
# 파이프라인 스텝을 활성화한다. 활성화 전에는 SSO 로 처음 로그인한 사용자는
# 권한 없는 계정으로 생성되며, 브레이크글래스 로컬 admin 이 권한을 부여한다.
#
# from netbox.settings import SOCIAL_AUTH_PIPELINE as _BASE_PIPELINE
#
# def map_keycloak_groups(response=None, user=None, *args, **kwargs):
#     if not user or not isinstance(response, dict):
#         return
#     groups = response.get("groups") or []
#     is_admin = "platform-admin" in groups
#     is_staff = is_admin or "platform-editor" in groups
#     changed = False
#     if user.is_superuser != is_admin:
#         user.is_superuser = is_admin
#         changed = True
#     if user.is_staff != is_staff:
#         user.is_staff = is_staff
#         changed = True
#     if changed:
#         user.save()
#
# SOCIAL_AUTH_PIPELINE = tuple(_BASE_PIPELINE) + (
#     "extra.map_keycloak_groups",
# )

# ── 운영 편의 ────────────────────────────────────────────────────────
BANNER_TOP = "ACER 인프라 Source of Truth (IPAM/CMDB)"
BANNER_LOGIN = "사내 전용. 변경은 GitOps/IaC 경유를 권장합니다."
CENSUS_REPORTING_ENABLED = False
